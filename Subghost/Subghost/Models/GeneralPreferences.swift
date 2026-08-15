//
//  GeneralPreferences.swift
//  Subghost
//
//  アプリ全体で共有する一般設定の範囲と正規化。
//

import Foundation

nonisolated enum GeneralPreferences {
    static let pollIntervalKey = "pollInterval"
    static let defaultPollInterval: TimeInterval = 3.0
    static let pollIntervalRange: ClosedRange<TimeInterval> = 2.0...10.0

    /// 外部からUserDefaultsへ書かれた値でも、監視ループが過剰実行されない範囲へ収める。
    static func normalizedPollInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultPollInterval }
        return min(max(value, pollIntervalRange.lowerBound), pollIntervalRange.upperBound)
    }

    static var pollInterval: TimeInterval {
        normalizedPollInterval(
            NotchPreferences.number(
                forKey: pollIntervalKey,
                default: defaultPollInterval
            )
        )
    }
}
