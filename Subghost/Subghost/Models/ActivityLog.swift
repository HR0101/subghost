//
//  ActivityLog.swift
//  Subghost
//
//  完了・エラー・回答待ちをローカルに記録する軽量なアクティビティ履歴。
//

import Foundation
import Observation

nonisolated enum ActivityKind: String, Codable, Sendable {
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
    @ObservationIgnored private let maximumCount: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "activityHistory",
        maximumCount: Int = 100
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumCount = max(maximumCount, 1)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            self.entries = Array(decoded.prefix(self.maximumCount))
        } else {
            self.entries = []
        }
    }

    var unreadCount: Int { entries.lazy.filter { !$0.isRead }.count }

    func record(kind: ActivityKind, session: SessionInfo, preview: [String]) {
        let summary = preview
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
        if entries.count > maximumCount {
            entries.removeLast(entries.count - maximumCount)
        }
        persist()
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
