//
//  AppearancePreferences.swift
//  Subghost
//
//  ノッチの見た目に関する設定値。
//  従来 NotchLayout の定数として固定されていたもののうち、好みが分かれる値だけを
//  設定へ出す。形状の連続性に関わる定数（ベジェ制御係数や肩幅）は、崩れると
//  ノッチとして成立しなくなるため、意図的に固定のまま残している。
//

import Foundation
import CoreGraphics

nonisolated enum AppearancePreferences {

    // MARK: - キー

    static let panelOpacityKey = "panelOpacity"
    static let ghostAnimationEnabledKey = "ghostAnimationEnabled"
    static let sessionListMaxRowsKey = "sessionListMaxRows"
    static let expandedCornerRadiusKey = "expandedCornerRadius"
    static let hidePreviewTextKey = "hidePreviewText"

    // MARK: - 不透明度

    static let defaultPanelOpacity: Double = 1.0
    static let minimumPanelOpacity: Double = 0.5
    static var panelOpacityRange: ClosedRange<Double> { minimumPanelOpacity...1.0 }

    /// 展開部分の背景の濃さ。下のウインドウを少し透かしたい人向け。
    static var panelOpacity: Double {
        clamp(
            NotchPreferences.number(forKey: panelOpacityKey, default: defaultPanelOpacity),
            to: panelOpacityRange
        )
    }

    // MARK: - キャラクターの動き

    /// ゴーストのアニメーション（生成中の裾揺れ・まばたき・完了時の弾み）を再生するか。
    /// 視覚的な動きを減らしたい場合にオフにする。
    static var ghostAnimationEnabled: Bool {
        NotchPreferences.bool(forKey: ghostAnimationEnabledKey, default: true)
    }

    // MARK: - 一覧の高さ

    static let defaultSessionListMaxRows = 5
    static let sessionListMaxRowsRange: ClosedRange<Int> = 2...12

    /// 一覧に一度に見せるセッション数。これを超えるぶんはスクロールになる。
    static var sessionListMaxRows: Int {
        let stored = Int(NotchPreferences.number(
            forKey: sessionListMaxRowsKey,
            default: Double(defaultSessionListMaxRows)
        ))
        return min(max(stored, sessionListMaxRowsRange.lowerBound), sessionListMaxRowsRange.upperBound)
    }

    // MARK: - 角丸

    static let defaultExpandedCornerRadius: Double = 28
    static var expandedCornerRadiusRange: ClosedRange<Double> { 8...44 }

    /// 展開したときの下側の角丸。
    static var expandedCornerRadius: CGFloat {
        CGFloat(clamp(
            NotchPreferences.number(
                forKey: expandedCornerRadiusKey,
                default: defaultExpandedCornerRadius
            ),
            to: expandedCornerRadiusRange
        ))
    }

    // MARK: - プライバシー

    /// 応答本文のプレビューをノッチと履歴で伏せる。
    /// 画面共有や録画のときに、会話の中身が映り込まないようにするため。
    static var hidePreviewText: Bool {
        NotchPreferences.bool(forKey: hidePreviewTextKey, default: false)
    }

    /// 伏せ字にすべきときはプレースホルダを返す
    static func maskedPreview(_ lines: [String]) -> [String] {
        hidePreviewText ? ["（本文は非表示に設定されています）"] : lines
    }

    static func maskedPreview(_ text: String) -> String {
        hidePreviewText ? "（本文は非表示）" : text
    }

    // MARK: - 共通

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
