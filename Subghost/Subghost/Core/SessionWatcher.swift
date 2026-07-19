//
//  SessionWatcher.swift
//  Subghost
//
//  設計書 3.3: SessionWatcher（pane出力の監視、状態遷移の判定）
//            SessionManager（監視対象セッションの選択・切替）
//

import Foundation
import Observation

/// セッション操作のエラー
nonisolated enum SessionError: Error, LocalizedError {
    case notMonitorable

    var errorDescription: String? {
        switch self {
        case .notMonitorable:
            return "このセッションはtmuxの外で動いているため、送信できません。tmux内で起動し直すと操作できます。"
        }
    }
}

/// 監視中のセッション1つ分の可観測状態
@Observable
final class MonitoredSession: Identifiable {
    private(set) var info: SessionInfo
    var state: AIState = .idle
    var preview: [String] = []
    var lastCompletedAt: Date?
    /// ノッチから回答すべき選択肢（承認/質問）。なければ nil。
    var pendingChoice: PendingChoice?

    @ObservationIgnored var detector: StateDetector
    /// 応答待ちで保持しているフック接続。返答するまでCLIは停止している。
    @ObservationIgnored var pendingHookConnection: HookServer.Connection?

    init(info: SessionInfo) {
        self.info = info
        self.detector = StateDetector(profile: info.profile)
    }

    var id: String { info.tty }

    /// 同じtty上でCLIが起動し直された場合などに、状態ごと作り直す
    func replaceInfo(_ newInfo: SessionInfo) {
        // フック由来の情報は ps では得られないため引き継ぐ
        var merged = newInfo
        merged.hookSessionID = info.hookSessionID
        merged.projectName = info.projectName

        info = merged
        detector = StateDetector(profile: merged.profile)
        state = .idle
        preview = []
        releasePendingHook(with: .passthrough)
        pendingChoice = nil
        lastCompletedAt = nil
    }

    /// 識別情報だけを差し替える（状態や承認待ちは維持する）
    func replaceInfoPreservingState(_ newInfo: SessionInfo) {
        info = newInfo
    }

    /// 保持しているフック接続に応答を返して解放する
    func releasePendingHook(with decision: HookDecision) {
        guard let connection = pendingHookConnection else { return }
        pendingHookConnection = nil
        connection.respond(json: decision.json)
    }
}

/// ai-* セッションの検出・ポーリング・状態遷移イベントの発火を担う。
@Observable
final class SessionWatcher {

    private(set) var sessions: [MonitoredSession] = []
    var activeSessionName: String? {
        didSet {
            guard oldValue != activeSessionName else { return }
            UserDefaults.standard.set(activeSessionName, forKey: "activeSessionName")
        }
    }
    private(set) var tmuxAvailable = true

    /// 検出はできたが監視も操作もできないセッションがあるか
    var hasUnmonitorableSession: Bool {
        sessions.contains { !$0.info.isMonitorable }
    }

    /// フック受信サーバが動いているか
    private(set) var hookServerRunning = false
    @ObservationIgnored private var hookServer: HookServer?

    /// 状態遷移イベントの通知先（AppCoordinatorが設定）
    @ObservationIgnored var onEvent: ((MonitoredSession, DetectorEvent) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var activeSession: MonitoredSession? {
        sessions.first { $0.info.tty == activeSessionName } ?? sessions.first
    }

    /// いずれかのセッションが生成中か（アイコンのパルス用）
    var anyThinking: Bool { sessions.contains { $0.state == .thinking } }

    /// ユーザーの回答待ちになっているセッション（承認を優先し、次に質問）
    var sessionAwaitingResponse: MonitoredSession? {
        sessions.first { $0.state == .awaitingApproval }
            ?? sessions.first { $0.state == .awaitingAnswer }
    }

    // MARK: - ポーリング (設計書 5.1)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                // idle時は間隔を延ばして負荷軽減 (設計書 12)
                let base = UserDefaults.standard.object(forKey: "pollInterval") as? Double ?? 0.8
                // 回答待ちの間は、ターミナル側で答えられた場合に素早く追従したいので短い間隔を保つ
                let busy = self.anyThinking
                    || self.sessions.contains { $0.state == .completed || $0.state.needsUserResponse }
                let interval = self.sessions.isEmpty ? max(base, 3.0) : (busy ? base : base * 2)
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

        // 1. 実行中プロセスからAI CLIを検出する（エイリアス・命名規則に依存しない）
        let agents = await AgentDiscovery.discover()
        reconcile(agents: agents)

        // 2. tmux配下のものだけcapture-paneして状態判定する
        let now = Date()
        let stable = UserDefaults.standard.object(forKey: "stableInterval") as? Double ?? 1.5
        for session in sessions {
            // フックが届いているセッションはイベントが正確なので、画面解析は行わない
            guard !session.info.isHookConnected else { continue }
            guard let target = session.info.tmuxTarget,
                  let text = await TmuxClient.capturePane(target: target) else { continue }
            session.detector.stableInterval = stable

            // 初めて見るセッションは、差分ではなく現在の画面から状態を推定する。
            // Subghost起動前から承認待ちで止まっているものを取りこぼさないため。
            let event = session.detector.needsInitialAdoption
                ? session.detector.adoptCurrentState(rawText: text, at: now)
                : session.detector.ingest(rawText: text, at: now)
            apply(event: event, to: session)
        }

        writeStateDumpIfEnabled()
    }

    /// 内部状態をJSONで書き出す（診断用）。
    /// `defaults write com.HR.Subghost writeStateDump -bool true` で有効になる。
    /// 常駐アプリはUIしか手掛かりが無く原因調査が難しいため、外から観測できる口を用意する。
    private func writeStateDumpIfEnabled(trigger: String = "poll") {
        guard UserDefaults.standard.bool(forKey: "writeStateDump") else { return }

        let payload: [String: Any] = [
            "trigger": trigger,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "activeSessionName": activeSessionName ?? "(なし)",
            "hookServerRunning": hookServerRunning,
            "tmuxAvailable": tmuxAvailable,
            "sessions": sessions.map { session in
                [
                    "tty": session.info.tty,
                    "pid": Int(session.info.pid),
                    "profile": session.info.profile.id,
                    "state": session.state.rawValue,
                    "isMonitorable": session.info.isMonitorable,
                    "monitoringSource": session.info.monitoringSource,
                    "hookSessionID": session.info.hookSessionID ?? "(なし)",
                    "tmuxTarget": session.info.tmuxTarget ?? "(なし)",
                ]
            },
        ]
        let url = HookInstaller.supportDirectory.appendingPathComponent("run/state.json")
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            // 握り潰すと「出力されない理由」が分からなくなるため必ず記録する
            NSLog("Subghost: 状態ダンプの書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    private func reconcile(agents: [DiscoveredAgent]) {
        let incoming = Dictionary(agents.map { ($0.tty, $0) }, uniquingKeysWith: { first, _ in first })

        // 消えたセッションを外す
        sessions.removeAll { incoming[$0.info.tty] == nil }

        for session in sessions {
            guard let agent = incoming[session.info.tty] else { continue }
            // 同じttyでもCLIが再起動していれば作り直す必要がある
            if session.info.pid != agent.pid || session.info.tmuxTarget != agent.tmuxTarget {
                session.replaceInfo(SessionInfo(agent: agent))
            }
        }

        let existing = Set(sessions.map { $0.info.tty })
        for agent in agents where !existing.contains(agent.tty) {
            sessions.append(MonitoredSession(info: SessionInfo(agent: agent)))
        }

        // 表示順を安定させる（CLI種別 → tty）
        sessions.sort {
            ($0.info.profile.id, $0.info.tty) < ($1.info.profile.id, $1.info.tty)
        }

        if activeSessionName == nil || incoming[activeSessionName ?? ""] == nil {
            // 前回選択していたセッションが生きていればそれを優先する
            let saved = UserDefaults.standard.string(forKey: "activeSessionName")
            activeSessionName = (saved.flatMap { incoming[$0] != nil ? $0 : nil })
                // 操作できるセッションを優先して選ぶ
                ?? sessions.first { $0.info.isMonitorable }?.info.tty
                ?? sessions.first?.info.tty
        }
        preferMonitorableSession()
    }

    /// 送信先が監視できないセッションのままなら、監視できるものへ移す。
    ///
    /// フックは「CLIが動いたとき」にしか発火しないため、放置されたセッションは
    /// いつまでも監視不可のままになる。そちらが選ばれていると、実際には動作している
    /// セッションがあるのに「監視できません」と表示され続けてしまう。
    private func preferMonitorableSession() {
        guard let active = activeSession, !active.info.isMonitorable else { return }
        guard let better = sessions.first(where: { $0.info.isMonitorable }) else { return }
        activeSessionName = better.info.tty
    }

    // MARK: - 送信先の切替 (設計書 4.3: 複数セッションの選択)

    /// 送信先セッションを次へ循環切替する（入力モードのTabキー用）
    /// 送信できないセッションは飛ばす。
    func cycleActiveSession() {
        let names = sessions.filter { $0.info.isMonitorable }.map { $0.info.tty }
        activeSessionName = Self.nextSessionName(in: names, after: activeSession?.info.tty)
    }

    /// 現在の次にあたるセッション名を返す（末尾なら先頭へ循環）
    nonisolated static func nextSessionName(in names: [String], after current: String?) -> String? {
        guard let first = names.first else { return nil }
        guard let current, let index = names.firstIndex(of: current) else { return first }
        return names[(index + 1) % names.count]
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
        case .becameAwaitingChoice(let choice):
            session.state = choice.kind == .approval ? .awaitingApproval : .awaitingAnswer
            session.pendingChoice = choice
            session.preview = [choice.title]
        case .choiceResolved:
            session.pendingChoice = nil
            session.state = .thinking
        }
        onEvent?(session, event)
    }

    // MARK: - プロンプト送信 (設計書 4.3 / PromptSender)

    func sendPrompt(_ text: String, to session: MonitoredSession) async throws {
        guard let target = session.info.tmuxTarget else { throw SessionError.notMonitorable }
        try await TmuxClient.sendPrompt(text, to: target)
        // 送信後は thinking へ即時遷移 (設計書 5.2)
        let event = session.detector.noteUserSentPrompt(at: Date())
        apply(event: event, to: session)
        if event == .none {
            session.state = .thinking
        }
    }

    // MARK: - 選択肢への回答 (Approve / Ask)

    /// ノッチで選ばれた選択肢をセッションへ送信する
    func respond(with option: ChoiceOption, in session: MonitoredSession) async throws {
        // フック経由の承認は、待たせている接続に判定を返すだけでよい（キー送信は不要）
        if session.pendingHookConnection != nil {
            let decision: HookDecision = option.isNegative
                ? .deny(reason: "Subghostで拒否しました")
                : .allow
            session.releasePendingHook(with: decision)
            session.pendingChoice = nil
            session.state = .thinking
            return
        }

        guard let target = session.info.tmuxTarget else { throw SessionError.notMonitorable }
        try await TmuxClient.sendChoice(option, to: target)
        session.pendingChoice = nil
        let event = session.detector.noteUserAnsweredChoice(at: Date())
        apply(event: event, to: session)
        if event == .none { session.state = .thinking }
    }

    // MARK: - フック方式 (追補: ゼロコンフィグ監視)

    /// フック受信サーバを起動する。失敗しても監視自体は続ける（tmux方式が残る）。
    func startHookServer() {
        guard hookServer == nil else { return }

        // 既に登録済みなら、ブリッジスクリプトを最新の内容に更新しておく。
        // スクリプト側の不具合修正を、ユーザーが再登録しなくても反映させるため。
        if HookTarget.allCases.contains(where: { HookInstaller.isInstalled($0) }) {
            do {
                try HookInstaller.installBridgeScript()
            } catch {
                NSLog("Subghost: ブリッジスクリプトの更新に失敗しました: \(error.localizedDescription)")
            }
        }
        let server = HookServer(socketPath: HookInstaller.socketPath)
        server.onRequest = { [weak self] request, connection in
            // サーバは専用スレッドで動くため、状態更新はメインアクターへ移す
            Task { @MainActor in
                await self?.handleHook(request: request, connection: connection)
            }
        }
        do {
            try server.start()
            hookServer = server
            hookServerRunning = true
        } catch {
            NSLog("Subghost: フック受信サーバを起動できませんでした: \(error.localizedDescription)")
            hookServerRunning = false
        }
    }

    func stopHookServer() {
        // 待たせている接続を解放してからでないとCLIが止まったままになる
        for session in sessions {
            session.releasePendingHook(with: .passthrough)
        }
        hookServer?.stop()
        hookServer = nil
        hookServerRunning = false
    }

    private func handleHook(request: HookRequest, connection: HookServer.Connection) async {
        guard let event = HookEventDecoder.decode(request.body) else {
            // 解釈できない形式ならCLI本来の挙動に任せる
            connection.respondPassthrough()
            return
        }

        var session = matchSession(request: request, event: event)
        if session == nil {
            // psの巡回がまだ追いついていない場合があるので一度だけ取り直す
            await pollOnce()
            session = matchSession(request: request, event: event)
        }
        guard let session else {
            // どのセッションにも紐づかなかったことを記録する（原因調査のため）
            NSLog("Subghost: フック \(event.kind.rawValue) の宛先セッションが見つかりません "
                + "(pid=\(request.pid.map(String.init) ?? "なし") tty=\(request.tty ?? "なし") "
                + "sessions=\(sessions.count))")
            writeStateDumpIfEnabled(trigger: "hook:unmatched:\(event.kind.rawValue)")
            connection.respondPassthrough()
            return
        }

        // このセッションはフックで監視できていると記録する
        var info = session.info
        info.hookSessionID = event.sessionID
        info.projectName = event.projectName
        session.replaceInfoPreservingState(info)
        // 実際に動いているセッションを送信先にする
        preferMonitorableSession()

        applyHook(event: event, to: session, connection: connection)
        writeStateDumpIfEnabled(trigger: "hook:\(event.kind.rawValue)")
    }

    /// フックのイベントを既知のセッションに突き合わせる。
    /// 確実な順に pid → tty → セッションID → 作業ディレクトリ の順で試す。
    private func matchSession(request: HookRequest, event: HookEvent) -> MonitoredSession? {
        if let pid = request.pid, let match = sessions.first(where: { $0.info.pid == pid }) {
            return match
        }
        if let tty = request.tty, let match = sessions.first(where: { $0.info.tty == tty }) {
            return match
        }
        if !event.sessionID.isEmpty,
           let match = sessions.first(where: { $0.info.hookSessionID == event.sessionID }) {
            return match
        }
        // 最後の手段: 同じ作業ディレクトリのセッションが1つだけならそれとみなす
        if let project = event.projectName {
            let candidates = sessions.filter { $0.info.projectName == project }
            if candidates.count == 1 { return candidates.first }
        }
        return nil
    }

    private func applyHook(
        event: HookEvent,
        to session: MonitoredSession,
        connection: HookServer.Connection
    ) {
        // 直前の承認待ちが未解決なら解放しておく（取りこぼし防止）
        if event.kind != .permissionRequest {
            session.releasePendingHook(with: .passthrough)
        }

        switch event.kind {
        case .permissionRequest:
            session.pendingHookConnection = connection
            let choice = PendingChoice(
                kind: .approval,
                title: event.title,
                detail: [],
                options: [
                    ChoiceOption(number: 1, label: "はい、許可する", keystroke: "1", needsEnter: false),
                    ChoiceOption(number: 2, label: "いいえ、拒否する", keystroke: "2", needsEnter: false),
                ]
            )
            apply(event: .becameAwaitingChoice(choice), to: session)
            return   // 応答はユーザーの回答時に返す

        case .notification:
            session.state = .awaitingAnswer
            session.preview = [event.title]
            onEvent?(session, .none)

        case .stop:
            apply(event: .becameCompleted(preview: [event.title]), to: session)

        case .stopFailure:
            apply(event: .becameError(preview: [event.title]), to: session)

        case .sessionStart, .sessionEnd:
            session.state = .idle
            session.pendingChoice = nil

        case .userPromptSubmit, .preToolUse, .postToolUse, .subagentStop:
            // サブエージェントの終了では親がまだ作業中なので完了扱いにしない
            if session.state != .thinking {
                apply(event: .becameThinking, to: session)
            }
        }

        connection.respondPassthrough()
    }

    /// 通知確認などで completed → idle にする
    func acknowledge(_ session: MonitoredSession) {
        session.detector.acknowledgeCompletion()
        if session.state == .completed { session.state = .idle }
    }
}
