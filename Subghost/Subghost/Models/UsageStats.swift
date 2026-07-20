//
//  UsageStats.swift
//  Subghost
//
//  設計書 追補: 使用量（レート制限）の表示
//
//  5時間枠・7日枠の消費率と、コンテキストウィンドウの使用率。
//  これらはフックのペイロードには含まれず、statusline へ渡されるJSONにのみ入っている。
//

import Foundation

// MARK: - 1つの制限枠

nonisolated struct UsageWindow: Sendable, Equatable {
    /// 使用率（0〜100）
    let usedPercent: Double
    /// リセット時刻。取得できない場合は nil。
    let resetsAt: Date?

    /// リセットまでの残り時間を "48m" / "6h48m" の形にする
    func remainingText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return nil }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    /// 残量に応じた警戒度（表示色の判断に使う）
    var isCritical: Bool { usedPercent >= 90 }
    var isWarning: Bool { usedPercent >= 70 }
}

// MARK: - 使用量全体

nonisolated struct UsageStats: Sendable, Equatable {
    /// どのCLIの使用量か（CLIProfile.id）
    let agentID: String
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    /// コンテキストウィンドウの使用率（0〜100）
    let contextUsedPercent: Double?
    let updatedAt: Date

    var hasAny: Bool { fiveHour != nil || sevenDay != nil }
}

// MARK: - 解析

nonisolated enum UsageParser {

    /// statuslineへ渡されるJSONから使用量を取り出す。
    /// 形式が違えば nil を返し、表示しない（誤った数値を出すよりは出さない）。
    static func parse(_ data: Data, now: Date = Date()) -> UsageStats? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        let limits = root["rate_limits"] as? [String: Any]
        let stats = UsageStats(
            agentID: "claude",
            fiveHour: window(from: limits?["five_hour"] as? [String: Any]),
            sevenDay: window(from: limits?["seven_day"] as? [String: Any]),
            contextUsedPercent: percent(
                (root["context_window"] as? [String: Any])?["used_percentage"]),
            updatedAt: now
        )
        return stats.hasAny || stats.contextUsedPercent != nil ? stats : nil
    }

    static func window(from dict: [String: Any]?) -> UsageWindow? {
        guard let dict, let used = percent(dict["used_percentage"]) else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: date(from: dict["resets_at"]))
    }

    /// 数値でも文字列でも受け取れるようにする
    static func percent(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String, let number = Double(text) { return number }
        return nil
    }

    /// 秒・ミリ秒・ISO8601のいずれでも受け取れるようにする
    static func date(from value: Any?) -> Date? {
        if let seconds = value as? Double { return dateFromEpoch(seconds) }
        if let seconds = value as? Int { return dateFromEpoch(Double(seconds)) }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let seconds = Double(text) { return dateFromEpoch(seconds) }
        return ISO8601DateFormatter().date(from: text)
    }

    /// 桁数からミリ秒か秒かを判断する
    private static func dateFromEpoch(_ value: Double) -> Date {
        // 10桁を大きく超えるならミリ秒とみなす
        value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000)
                                : Date(timeIntervalSince1970: value)
    }
}


// MARK: - Codex の記録からの解析

extension UsageParser {

    /// 短い枠（5時間）とみなす window_minutes の上限
    static let shortWindowMaxMinutes = 60 * 24

    /// Codexのセッション記録(JSONL)から直近のレート制限を取り出す。
    ///
    /// Claude Code とは形式が異なる:
    ///   - `event_msg` の `token_count` に入っている
    ///   - キーは `used_percent`（Claudeは `used_percentage`）
    ///   - 枠は primary / secondary という名前で、実際の期間は `window_minutes` で判別する
    static func parseCodexRateLimits(inJSONLines text: String, now: Date = Date()) -> UsageStats? {
        let lines = text.split(separator: "\n").suffix(200)

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let windows = ["primary", "secondary"].compactMap {
                codexWindow(from: limits[$0] as? [String: Any])
            }
            guard !windows.isEmpty else { continue }

            // 期間の長さで5時間枠と7日枠に振り分ける
            let short = windows.first { $0.minutes <= shortWindowMaxMinutes }?.window
            let long = windows.first { $0.minutes > shortWindowMaxMinutes }?.window
            guard short != nil || long != nil else { continue }

            return UsageStats(
                agentID: "codex",
                fiveHour: short,
                sevenDay: long,
                contextUsedPercent: nil,
                updatedAt: now)
        }
        return nil
    }

    static func codexWindow(from dict: [String: Any]?) -> (window: UsageWindow, minutes: Int)? {
        guard let dict,
              let used = percent(dict["used_percent"] ?? dict["used_percentage"]),
              let minutes = (dict["window_minutes"] as? Int)
                ?? (dict["window_minutes"] as? Double).map(Int.init)
        else { return nil }
        return (UsageWindow(usedPercent: used, resetsAt: date(from: dict["resets_at"])), minutes)
    }
}
