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

    static var collapseOnMouseExit: Bool {
        bool(forKey: collapseOnMouseExitKey, default: true)
    }

    static var closeOnOutsideClick: Bool {
        bool(forKey: closeOnOutsideClickKey, default: true)
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
