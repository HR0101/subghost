//
//  NotchPreferences.swift
//  Subghost
//
//  ノッチの展開・表示・収納に関する設定値を一か所に集約する。
//

import Foundation

nonisolated enum NotchPreferences {
    static let hoverExpansionEnabledKey = "hoverExpansionEnabled"
    static let hoverDelayKey = "hoverDelay"
    static let expansionAnimationDurationKey = "expansionAnimationDuration"
    static let smartNotificationSuppressionKey = "smartNotificationSuppression"
    static let hideInFullScreenKey = "hideInFullScreen"
    static let hideWhenNoSessionsKey = "hideWhenNoSessions"
    static let notificationDisplayDurationKey = "notificationDisplayDuration"
    static let collapseOnMouseExitKey = "collapseOnMouseExit"
    static let closeOnOutsideClickKey = "closeOnOutsideClick"
    static let choiceAutoCloseIntervalKey = "choiceAutoCloseInterval"
    static let focusChoiceOnAppearKey = "focusChoiceOnAppear"
    static let hideUnmonitorableSessionsKey = "hideUnmonitorableSessions"
    static let hideInactiveSessionsKey = "hideInactiveSessions"
    static let inactiveSessionThresholdKey = "inactiveSessionThreshold"
    static let suggestsTmuxSetupKey = "suggestsTmuxSetup"

    static var hoverExpansionEnabled: Bool {
        bool(forKey: hoverExpansionEnabledKey, default: true)
    }

    static var hoverDelay: TimeInterval {
        number(forKey: hoverDelayKey, default: 0.15)
    }

    static let defaultExpansionAnimationDuration: TimeInterval = 0.50
    static let minimumExpansionAnimationDuration: TimeInterval = 0.15
    static let maximumExpansionAnimationDuration: TimeInterval = 1.20
    static var expansionAnimationDurationRange: ClosedRange<TimeInterval> {
        minimumExpansionAnimationDuration...maximumExpansionAnimationDuration
    }

    static var expansionAnimationDuration: TimeInterval {
        normalizedExpansionAnimationDuration(
            number(
                forKey: expansionAnimationDurationKey,
                default: defaultExpansionAnimationDuration
            )
        )
    }

    static func normalizedExpansionAnimationDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumExpansionAnimationDuration), maximumExpansionAnimationDuration)
    }

    static var smartNotificationSuppression: Bool {
        bool(forKey: smartNotificationSuppressionKey, default: true)
    }

    static var hideInFullScreen: Bool {
        bool(forKey: hideInFullScreenKey, default: true)
    }

    static var hideWhenNoSessions: Bool {
        bool(forKey: hideWhenNoSessionsKey, default: false)
    }

    static var notificationDisplayDuration: TimeInterval {
        number(forKey: notificationDisplayDurationKey, default: 5.0)
    }

    // MARK: - 一覧に出さないセッション

    /// tmuxにもフックにも繋がっていない＝監視も操作もできないセッションを一覧から外す。
    /// 既定で有効。表示しても状態が出ず、送信もできないため実用上の情報がない。
    static var hideUnmonitorableSessions: Bool {
        bool(forKey: hideUnmonitorableSessionsKey, default: true)
    }

    /// 一定時間まったく動きの無いセッションを一覧から外す
    static var hideInactiveSessions: Bool {
        bool(forKey: hideInactiveSessionsKey, default: true)
    }

    /// tmuxの導入案内を出すか。
    /// tmuxを使わず監視だけで使うのも正規の構成なので、断れるようにしておく。
    static var suggestsTmuxSetup: Bool {
        bool(forKey: suggestsTmuxSetupKey, default: true)
    }

    static func setSuggestsTmuxSetup(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: suggestsTmuxSetupKey)
    }

    static let inactiveSessionThresholdRange: ClosedRange<TimeInterval> = 300...86_400

    /// 「動きが無い」とみなすまでの秒数（既定 30分）
    static var inactiveSessionThreshold: TimeInterval {
        let stored = number(forKey: inactiveSessionThresholdKey, default: 1_800)
        return min(
            max(stored, inactiveSessionThresholdRange.lowerBound),
            inactiveSessionThresholdRange.upperBound
        )
    }

    static var collapseOnMouseExit: Bool {
        bool(forKey: collapseOnMouseExitKey, default: true)
    }

    static var closeOnOutsideClick: Bool {
        bool(forKey: closeOnOutsideClickKey, default: true)
    }

    /// 選択肢（承認/質問）を自動で閉じるまでの秒数。
    /// 0以下なら自動で閉じない（回答するまで表示し続ける、既定の挙動）。
    static var choiceAutoCloseInterval: TimeInterval {
        number(forKey: choiceAutoCloseIntervalKey, default: 0)
    }

    /// 選択肢が届いたとき、Subghostがキーボードフォーカスを奪ってよいか。
    ///
    /// 有効だと数字キーだけで即座に回答できるが、他アプリで文章を書いている
    /// 最中に割り込むと打鍵を横取りしてしまう。無効にした場合はパネルを出すだけに留め、
    /// ノッチをクリックしてから数字キーで回答する。
    static var focusChoiceOnAppear: Bool {
        bool(forKey: focusChoiceOnAppearKey, default: true)
    }

    static func bool(
        forKey key: String,
        default defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    static func number(
        forKey key: String,
        default defaultValue: Double,
        defaults: UserDefaults = .standard
    ) -> Double {
        defaults.object(forKey: key) as? Double ?? defaultValue
    }
}
