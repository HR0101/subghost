//
//  DisplayPreference.swift
//  Subghost
//
//  設計書 追補: ノッチを表示するディスプレイの選択
//
//  複数モニタ環境で、どの画面にノッチUIを出すかを設定できるようにする。
//  NSScreenに依存しない純粋なロジックとして切り出し、単体テストできる形にしている。
//

import Foundation

// MARK: - 画面の識別情報

/// 選択ロジックが必要とする画面の情報だけを抜き出したもの
nonisolated struct ScreenDescriptor: Sendable, Equatable, Identifiable, Hashable {
    /// 再接続や再起動をまたいで安定する識別子（ディスプレイUUID。取得できなければ表示名）
    let id: String
    /// 「Studio Display」などの表示名
    let name: String
    /// 物理的なノッチ（切り欠き）を持つか
    let hasNotch: Bool
    /// システムの主ディスプレイ（ディスプレイ設定で「主」に指定された画面）か
    let isPrimary: Bool
    /// 今フォーカスされている画面か（ユーザーが作業している画面）
    let isActive: Bool
}

// MARK: - 設定値

/// どの画面にノッチUIを出すか
nonisolated enum DisplayPreference: Sendable, Equatable {
    /// ノッチ搭載画面を優先し、無ければ主ディスプレイ
    case automatic
    /// 常にシステムの主ディスプレイ
    case primary
    /// 今使っている（フォーカスされている）画面に追従する
    case followActive
    /// 特定のディスプレイを指定
    case specific(id: String)

    /// UserDefaultsに保存する文字列
    var storedValue: String {
        switch self {
        case .automatic: return ""
        case .primary: return "main"      // 既存の設定値との互換のため "main" のまま
        case .followActive: return "active"
        case .specific(let id): return id
        }
    }

    init(storedValue: String) {
        switch storedValue {
        case "": self = .automatic
        case "main": self = .primary
        case "active": self = .followActive
        default: self = .specific(id: storedValue)
        }
    }

    static let userDefaultsKey = "notchDisplay"

    /// 現在の設定を読み出す
    static var current: DisplayPreference {
        DisplayPreference(
            storedValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "")
    }
}

// MARK: - 選択ロジック

nonisolated enum DisplaySelector {

    /// 設定に従って表示先の画面を選ぶ。
    ///
    /// 指定された画面が接続されていない場合（外部モニタを外した等）は、
    /// 自動と同じ規則にフォールバックする。画面が1枚も無ければ nil。
    static func select(
        from screens: [ScreenDescriptor],
        preference: DisplayPreference
    ) -> ScreenDescriptor? {
        guard !screens.isEmpty else { return nil }

        switch preference {
        case .specific(let id):
            if let match = screens.first(where: { $0.id == id }) { return match }
            // 指定の画面が見つからないので自動にフォールバック
            return automaticChoice(from: screens)

        case .primary:
            return screens.first { $0.isPrimary } ?? automaticChoice(from: screens)

        case .followActive:
            // 作業中の画面へ追従する。特定できなければ自動と同じ規則。
            return screens.first { $0.isActive } ?? automaticChoice(from: screens)

        case .automatic:
            return automaticChoice(from: screens)
        }
    }

    /// ノッチ搭載画面 → 主ディスプレイ → 先頭 の順に選ぶ
    private static func automaticChoice(from screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens.first { $0.hasNotch }
            ?? screens.first { $0.isPrimary }
            ?? screens.first
    }
}
