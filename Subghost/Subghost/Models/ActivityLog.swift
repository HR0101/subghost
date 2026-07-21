//
//  ActivityLog.swift
//  Subghost
//
//  完了・エラー・回答待ちをローカルに記録する軽量なアクティビティ履歴。
//

import Foundation
import Observation

nonisolated enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case completed
    case error
    case approval
    case question

    var displayName: String {
        switch self {
        case .completed: return "応答完了"
        case .error: return "エラー"
        case .approval: return "承認待ち"
        case .question: return "質問"
        }
    }
}

// MARK: - 履歴の設定

nonisolated enum ActivityPreferences {
    static let limitKey = "activityHistoryLimit"
    static let recordingEnabledKey = "activityRecordingEnabled"

    static let defaultLimit = 100
    static let limitRange: ClosedRange<Int> = 20...500

    /// 保持する件数。古いものから捨てる。
    static var limit: Int {
        let stored = Int(NotchPreferences.number(forKey: limitKey, default: Double(defaultLimit)))
        return min(max(stored, limitRange.lowerBound), limitRange.upperBound)
    }

    /// 履歴を残すかどうか（オフにすると以後の記録を止める）
    static var isRecordingEnabled: Bool {
        NotchPreferences.bool(forKey: recordingEnabledKey, default: true)
    }

    /// 種類ごとに記録するかどうかの設定キー
    static func kindKey(_ kind: ActivityKind) -> String {
        "activityHistory.\(kind.rawValue).enabled"
    }

    static func records(_ kind: ActivityKind) -> Bool {
        NotchPreferences.bool(forKey: kindKey(kind), default: true)
    }
}

nonisolated struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: ActivityKind
    let sessionTTY: String
    let sessionPID: Int32
    let agentID: String
    let agentName: String
    let sessionName: String
    let summary: String
    var isRead: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: ActivityKind,
        sessionTTY: String,
        sessionPID: Int32,
        agentID: String,
        agentName: String,
        sessionName: String,
        summary: String,
        isRead: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sessionTTY = sessionTTY
        self.sessionPID = sessionPID
        self.agentID = agentID
        self.agentName = agentName
        self.sessionName = sessionName
        self.summary = summary
        self.isRead = isRead
    }
}

@Observable
final class ActivityStore {
    private(set) var entries: [ActivityEntry]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    /// テストから固定値を渡すための上書き。通常は設定値（ActivityPreferences.limit）を使う。
    @ObservationIgnored private let fixedMaximumCount: Int?

    /// 実際に適用する保持件数。設定画面で変えた値が次の記録から効くよう、都度読む。
    private var maximumCount: Int {
        max(fixedMaximumCount ?? ActivityPreferences.limit, 1)
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "activityHistory",
        maximumCount: Int? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.fixedMaximumCount = maximumCount.map { max($0, 1) }
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
        trimIfNeeded()
    }

    var unreadCount: Int { entries.lazy.filter { !$0.isRead }.count }

    func record(kind: ActivityKind, session: SessionInfo, preview: [String]) {
        // 記録そのものを止めている場合と、この種類だけ除外している場合
        guard ActivityPreferences.isRecordingEnabled, ActivityPreferences.records(kind) else { return }
        let summary = AppearancePreferences.maskedPreview(preview)
            .prefix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        append(ActivityEntry(
            kind: kind,
            sessionTTY: session.tty,
            sessionPID: session.pid,
            agentID: session.profile.id,
            agentName: session.profile.displayName,
            sessionName: session.displayName,
            summary: String(summary.prefix(400))
        ))
    }

    func append(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        trimIfNeeded()
        persist()
    }

    /// 保持件数を超えたぶんを古い側から捨てる。
    /// 設定で件数を減らしたときにも、次の記録を待たずに縮むよう独立させている。
    func trimIfNeeded() {
        let limit = maximumCount
        guard entries.count > limit else { return }
        entries.removeLast(entries.count - limit)
    }

    /// 設定画面で保持件数を変えたときに呼ぶ
    func applyRetentionLimit() {
        let before = entries.count
        trimIfNeeded()
        if entries.count != before { persist() }
    }

    func markRead(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              !entries[index].isRead
        else { return }
        entries[index].isRead = true
        persist()
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        for index in entries.indices { entries[index].isRead = true }
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
