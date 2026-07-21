//
//  SettingsStore.swift
//  Subghost
//
//  設定そのものを扱う操作（初期化・書き出し・読み込み）と、開発用の記録フラグ。
//
//  フック導入や ~/.zshrc の書き換えまで行うアプリなので、設定を一度まっさらに
//  戻せる導線を用意しておく。書き出し／読み込みは、環境を移すときと、
//  不具合の報告に設定内容を添えたいときのため。
//

import Foundation

// MARK: - 開発用の記録

/// UserDefaults から読むだけで有効になる記録フラグ。
/// 以前は `defaults write` でしか切り替えられず、事実上使えなかったため設定へ出す。
nonisolated enum DiagnosticsPreferences {
    static let writeStateDumpKey = "writeStateDump"
    static let logDisplaySelectionKey = "logDisplaySelection"

    /// 画面解析の入力と判定結果をファイルへ書き出す（状態判定の誤りを調べるため）
    static var writeStateDump: Bool {
        NotchPreferences.bool(forKey: writeStateDumpKey, default: false)
    }

    /// ノッチをどの画面に置くと判断したかをコンソールへ記録する
    static var logDisplaySelection: Bool {
        NotchPreferences.bool(forKey: logDisplaySelectionKey, default: false)
    }

    /// 状態ダンプの書き出し先（診断画面から開けるようにする）
    static var stateDumpDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subghost", isDirectory: true)
    }
}

// MARK: - 設定の初期化・入出力

enum SettingsStore {

    enum SettingsError: LocalizedError {
        case noDomain
        case unreadable
        case malformed

        var errorDescription: String? {
            switch self {
            case .noDomain: return "設定の保存領域を特定できませんでした。"
            case .unreadable: return "ファイルを読み込めませんでした。"
            case .malformed: return "設定ファイルの形式が正しくありません。"
            }
        }
    }

    private static var domainName: String? {
        Bundle.main.bundleIdentifier
    }

    /// 書き出し・読み込みの対象外にするキー。
    ///
    /// 案内の完了状態を持ち回ると、別のMacへ移したときに初回案内が出ずに
    /// フック連携へ気づけなくなる。フック導入の有無はこのMacの実ファイルが持っており、
    /// 設定ファイルで移しても実体が伴わない。
    private static let nonPortableKeys: Set<String> = [
        "hasCompletedOnboarding",
        "activityHistory",
        "activeSessionName",
    ]

    /// すべての設定を消して初期状態へ戻す。
    /// フックの導入や ~/.zshrc の変更といったアプリ外への変更には触れない。
    static func resetAll() throws {
        guard let domainName else { throw SettingsError.noDomain }
        UserDefaults.standard.removePersistentDomain(forName: domainName)
        UserDefaults.standard.synchronize()
    }

    /// 現在の設定を書き出す。
    /// Data を含む値も欠落なく往復させたいので、JSONではなくplistで持つ。
    static func export(to url: URL) throws {
        guard let domainName,
              let domain = UserDefaults.standard.persistentDomain(forName: domainName)
        else { throw SettingsError.noDomain }

        let portable = domain.filter { !nonPortableKeys.contains($0.key) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: portable,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// 書き出した設定を読み込んで適用する。
    /// 既存の設定へ上書きで重ねる（ファイルに無いキーは今の値のまま残す）。
    @discardableResult
    static func importSettings(from url: URL) throws -> Int {
        guard let data = try? Data(contentsOf: url) else { throw SettingsError.unreadable }
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let values = plist as? [String: Any]
        else { throw SettingsError.malformed }

        let defaults = UserDefaults.standard
        var applied = 0
        for (key, value) in values where !nonPortableKeys.contains(key) {
            defaults.set(value, forKey: key)
            applied += 1
        }
        return applied
    }

    /// 書き出しの既定ファイル名
    static var suggestedFileName: String { "Subghost設定.plist" }
}
