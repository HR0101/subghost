//
//  SessionWatcher.swift
//  Subghost
//
//  設計書 3.3: GhosttySessionWatcher（pane出力の監視、状態遷移の判定）
//            SessionManager（監視対象セッションの選択・切替）
//

import Foundation
import Observation

/// 監視中のtmuxセッション1つ分の可観測状態
@Observable
final class MonitoredSession: Identifiable {
    let info: SessionInfo
    var state: AIState = .idle
    var preview: [String] = []
    var lastCompletedAt: Date?

    @ObservationIgnored var detector: StateDetector

    init(info: SessionInfo) {
        self.info = info
        self.detector = StateDetector(profile: info.profile)
    }

    var id: String { info.tmuxName }
}

/// ai-* セッションの検出・ポーリング・状態遷移イベントの発火を担う。
@Observable
final class GhosttySessionWatcher {

    private(set) var sessions: [MonitoredSession] = []
    var activeSessionName: String?
    private(set) var tmuxAvailable = true

    /// 状態遷移イベントの通知先（AppCoordinatorが設定）
    @ObservationIgnored var onEvent: ((MonitoredSession, DetectorEvent) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var activeSession: MonitoredSession? {
        sessions.first { $0.info.tmuxName == activeSessionName } ?? sessions.first
    }

    /// いずれかのセッションが生成中か（アイコンのパルス用）
    var anyThinking: Bool { sessions.contains { $0.state == .thinking } }

    // MARK: - ポーリング (設計書 5.1)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                // idle時は間隔を延ばして負荷軽減 (設計書 12)
                let base = UserDefaults.standard.object(forKey: "pollInterval") as? Double ?? 0.8
                let interval = self.sessions.isEmpty ? max(base, 3.0)
                    : (self.anyThinking || self.sessions.contains { $0.state == .completed } ? base : base * 2)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        tmuxAvailable = TmuxClient.resolveTmuxPath() != nil
        guard tmuxAvailable else { return }

        // 1. セッション検出・突き合わせ (設計書 10.2)
        let names = await TmuxClient.listAISessions()
        reconcile(names: names)

        // 2. 各セッションをcapture-paneして状態判定
        let now = Date()
        let stable = UserDefaults.standard.object(forKey: "stableInterval") as? Double ?? 1.5
        for session in sessions {
            guard let text = await TmuxClient.capturePane(session: session.info.tmuxName) else { continue }
            session.detector.stableInterval = stable
            let event = session.detector.ingest(rawText: text, at: now)
            apply(event: event, to: session)
        }
    }

    private func reconcile(names: [String]) {
        let existing = Set(sessions.map { $0.info.tmuxName })
        let incoming = Set(names)

        sessions.removeAll { !incoming.contains($0.info.tmuxName) }
        for name in names where !existing.contains(name) {
            let info = SessionInfo(tmuxName: name, profile: .match(sessionName: name))
            sessions.append(MonitoredSession(info: info))
        }
        sessions.sort { $0.info.tmuxName < $1.info.tmuxName }

        if activeSessionName == nil || !incoming.contains(activeSessionName ?? "") {
            activeSessionName = sessions.first?.info.tmuxName
        }
    }

    private func apply(event: DetectorEvent, to session: MonitoredSession) {
        switch event {
        case .none:
            return
        case .becameThinking:
            session.state = .thinking
        case .becameCompleted(let preview):
            session.state = .completed
            session.preview = preview
            session.lastCompletedAt = Date()
        case .becameError(let preview):
            session.state = .error
            session.preview = preview
        case .becameIdle:
            session.state = .idle
        }
        onEvent?(session, event)
    }

    // MARK: - プロンプト送信 (設計書 4.3 / PromptSender)

    func sendPrompt(_ text: String, to session: MonitoredSession) async throws {
        try await TmuxClient.sendPrompt(text, to: session.info.tmuxName)
        // 送信後は thinking へ即時遷移 (設計書 5.2)
        let event = session.detector.noteUserSentPrompt(at: Date())
        apply(event: event, to: session)
        if event == .none {
            session.state = .thinking
        }
    }

    /// 通知確認などで completed → idle にする
    func acknowledge(_ session: MonitoredSession) {
        session.detector.acknowledgeCompletion()
        if session.state == .completed { session.state = .idle }
    }
}
