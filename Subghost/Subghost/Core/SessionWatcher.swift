//
//  SessionWatcher.swift
//  Subghost
//
//  設計書 3.3: SessionWatcher（CLIフックの監視、状態遷移の判定）
//            SessionManager（監視対象セッションの選択・切替）
//
//  監視の中枢。検出したセッションを MonitoredSession として保持し、
//  一定間隔の pollOnce() でプロセスの生存を確認し、状態はCLIフックで更新する。
//
//  状態監視はCLIフックだけを正とする。端末画面の解析と入力送信は行わない。
//

import Foundation
import Observation

/// フック監視からUIへ渡す状態遷移。CLIへの回答・送信イベントは持たない。
nonisolated enum DetectorEvent: Equatable, Sendable {
    case none
    case becameThinking
    case becameCompleted(preview: [String])
    case becameIdle
    case becameError(preview: [String])
}

// MARK: - 一覧に出すかどうかの判断 (純粋ロジック)

/// 「もう使っていないセッション」を一覧から外すための判断。
///
/// 使い終わった CLI はプロセスとしては生き続けるため、放っておくと一覧が
/// 過去のセッションで埋まる。ただし**隠すのは表示だけ**で監視は続けており、
/// I/O を持たない純粋な判断にしてあるので、固定の `Date` で単体テストできる。
nonisolated enum SessionVisibility {

    /// 判断に使うセッション側の状態
    struct Input {
        /// 現在ユーザーが選択しているセッションか
        var isActiveTarget: Bool
        /// フックで監視できるか
        var isMonitorable: Bool
        /// 最後に動きがあった時刻
        var activityAt: Date
        /// 手動で一覧から外したときの活動時刻。以降に動きがあれば自動で戻す。
        var hiddenAtActivity: Date?
    }

    /// 判断に使う設定側の値
    struct Rules {
        /// 「すべて表示」中は絞り込みを行わない
        var revealAll: Bool
        var hideUnmonitorable: Bool
        var hideInactive: Bool
        var inactiveThreshold: TimeInterval
    }

    static func isVisible(_ input: Input, rules: Rules, at now: Date) -> Bool {
        if rules.revealAll { return true }
        // 選択中のセッションが一覧から突然消えないようにする
        if input.isActiveTarget { return true }

        // 手動で外したもの。外した後に新しい動きがあれば自動で戻る。
        if let hiddenAt = input.hiddenAtActivity, input.activityAt <= hiddenAt {
            return false
        }
        if rules.hideUnmonitorable, !input.isMonitorable { return false }
        if rules.hideInactive,
           now.timeIntervalSince(input.activityAt) >= rules.inactiveThreshold {
            return false
        }
        return true
    }
}

/// 監視中のセッション1つ分の可観測状態
@Observable
final class MonitoredSession: Identifiable {
    private(set) var info: SessionInfo
    var state: AIState = .idle
    var preview: [String] = []
    var lastCompletedAt: Date?
    /// 直近のユーザー発言（一覧に出す）
    var lastUserPrompt: String?
    /// 直近のAIの返信（一覧に出す。監視できなくても記録から読む）
    var lastReply: String?
    /// CLIセッション記録の場所。端末画面ではなく、ローカルJSONLを読むために保持する。
    var transcriptPath: String?
    /// CLIが管理している直近のタスクリスト
    var taskList: [AITaskItem] = []
    /// 解決済みの作業ディレクトリ（表示用）
    var workingDirectory: String?
    /// 最後に何か動きがあった時刻（経過時間の表示に使う）
    var lastActivityAt: Date = Date()
    /// ユーザーが一覧から手動で外したときの、その時点での活動時刻。
    /// これより新しい動きがあれば「また使い始めた」とみなして自動的に戻す。
    var hiddenAtActivity: Date?
    /// CLIセッション終了フックを受けた時刻。完了を少し見せた後、一覧から掃除する。
    var hookSessionEndedAt: Date?

    /// 表示・放置判定に使う、最も新しい活動時刻
    var effectiveActivityAt: Date {
        lastActivityAt
    }
    init(info: SessionInfo) {
        self.info = info
    }

    var id: String { info.id }

    /// 同じtty上でCLIが起動し直された場合などに、状態ごと作り直す
    func replaceInfo(_ newInfo: SessionInfo) {
        // フック由来の情報は ps では得られないため引き継ぐ
        var merged = newInfo
        merged.hookSessionID = info.hookSessionID
        merged.projectName = info.projectName

        info = merged
        state = .idle
        preview = []
        lastCompletedAt = nil
        transcriptPath = nil
        taskList = []
    }

    /// 識別情報だけを差し替える（状態は維持する）
    func replaceInfoPreservingState(_ newInfo: SessionInfo) {
        info = newInfo
    }

}

/// ai-* セッションの検出・ポーリング・状態遷移イベントの発火を担う。
@MainActor
@Observable
final class SessionWatcher {

    private(set) var sessions: [MonitoredSession] = []
    var activeSessionName: String? {
        didSet {
            guard oldValue != activeSessionName else { return }
            UserDefaults.standard.set(activeSessionName, forKey: "activeSessionName")
        }
    }
    /// 表示対象をユーザーが明示的に選んだか。
    private(set) var isActiveSessionUserChosen = false

    /// ユーザー操作による表示対象の指定
    func chooseActiveSession(_ id: String) {
        activeSessionName = id
        isActiveSessionUserChosen = true
    }

    /// 検出はできたが監視も操作もできないセッションがあるか
    var hasUnmonitorableSession: Bool {
        sessions.contains { !$0.info.isMonitorable }
    }

    /// CLIごとの使用量。Claudeはstatusline経由、Codexはセッション記録から取得する。
    private(set) var usageByAgent: [String: UsageStats] = [:]

    /// 取得済みの全AIの使用量（アイコン順に並べる）
    var allUsage: [UsageStats] {
        let order = ["claude", "codex", "antigravity"]
        return usageByAgent.values.sorted {
            (order.firstIndex(of: $0.agentID) ?? 99) < (order.firstIndex(of: $1.agentID) ?? 99)
        }
    }

    /// 最後に使ったAIの使用量。無ければ取得済みのうち最も新しいもの。
    var usage: UsageStats? {
        let lastUsed = sessions
            .max { $0.lastActivityAt < $1.lastActivityAt }?
            .info.profile.id
        if let lastUsed, let stats = usageByAgent[lastUsed] { return stats }
        return usageByAgent.values.max { $0.updatedAt < $1.updatedAt }
    }

    /// フック受信サーバが動いているか
    private(set) var hookServerRunning = false
    /// CLIから最後にHookイベントを実受信した時刻。登録済み表示だけでは分からない疎通確認に使う。
    private(set) var lastHookEventAt: Date?
    /// CLI種別ごとの最終受信。設定画面で「登録済み」と「実際に動作」を区別する。
    private(set) var lastHookEventAtBySource: [String: Date] = [:]
    /// セッションへ結び付けられなかったイベント件数。
    private(set) var unmatchedHookEventCount = 0
    /// 設定画面からローカル受信サーバまでの疎通を最後に確認した時刻。
    private(set) var lastHealthCheckAt: Date?
    @ObservationIgnored private var hookServer: HookServer?

    /// 状態遷移イベントの通知先（AppCoordinatorが設定）
    @ObservationIgnored var onEvent: ((MonitoredSession, DetectorEvent) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var activeSession: MonitoredSession? {
        sessions.first { $0.info.id == activeSessionName } ?? sessions.first
    }

    // MARK: - 一覧に出すセッションの絞り込み

    /// 一覧に出すセッション。
    ///
    /// 絞り込みは**表示だけ**の話で、監視は全セッションに対して続ける。
    /// 現在選択しているセッションは、どの条件よりも優先して必ず出す。
    var visibleSessions: [MonitoredSession] {
        let now = Date()
        return sessions.filter { isVisible($0, at: now) }
    }

    /// 一覧から外されているセッションの件数（「他に N 件」の表示に使う）
    var hiddenSessionCount: Int { sessions.count - visibleSessions.count }

    /// 「すべて表示」を押している間だけ、絞り込みを一時的に解除する。
    /// 設定を変えに行かなくても、隠れているものをその場で確認できるようにする。
    var revealsHiddenSessions = false

    func isVisible(_ session: MonitoredSession, at now: Date = Date()) -> Bool {
        SessionVisibility.isVisible(
            SessionVisibility.Input(
                isActiveTarget: session.info.id == activeSessionName,
                isMonitorable: session.info.isMonitorable,
                activityAt: session.effectiveActivityAt,
                hiddenAtActivity: session.hiddenAtActivity
            ),
            rules: SessionVisibility.Rules(
                revealAll: revealsHiddenSessions,
                hideUnmonitorable: NotchPreferences.hideUnmonitorableSessions,
                hideInactive: NotchPreferences.hideInactiveSessions,
                inactiveThreshold: NotchPreferences.inactiveSessionThreshold
            ),
            at: now
        )
    }

    /// 一覧から手動で外す（プロセスはそのまま）
    func hide(_ session: MonitoredSession) {
        session.hiddenAtActivity = session.effectiveActivityAt
    }

    /// 手動で外したセッションをすべて戻す
    func unhideAll() {
        for session in sessions { session.hiddenAtActivity = nil }
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
                let base = GeneralPreferences.pollInterval
                let interval = self.sessions.isEmpty ? max(base, 8.0) : base
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// ユーザー登録のカスタムエイリアス（AppCoordinatorが変更のたびに同期する）
    var customAliases: [CustomAlias] = []

    func pollOnce() async {
        // 1. 実行中プロセスからAI CLIを検出する（エイリアス・命名規則に依存しない）
        let agents = await AgentDiscovery.discover(profiles: CLIProfile.withCustomAliases(customAliases))
        reconcile(agents: agents)

        refreshCodexUsageIfNeeded()
        await refreshWorkingDirectories()
        refreshTranscriptContent()
        writeStateDumpIfEnabled()
    }

    /// プライバシー設定を有効にした瞬間に、メモリ上の本文も消す。
    /// 次のフックからは設定を戻すまで再取得しない。
    func redactPreviewContent() {
        for session in sessions {
            session.preview = []
            session.lastUserPrompt = nil
            session.lastReply = nil
            session.transcriptPath = nil
            session.taskList = []
        }
    }

    /// フックで得た記録末尾から、送信内容・返信・タスクを更新する。
    /// 1回の読み込みを各項目で共有し、端末画面の状態には依存しない。
    private func refreshTranscriptContent() {
        guard !AppearancePreferences.hidePreviewText else { return }
        for session in sessions {
            refreshTranscriptContent(for: session)
        }
    }

    private func refreshTranscriptContent(for session: MonitoredSession) {
        guard !AppearancePreferences.hidePreviewText else { return }

        if session.info.profile.id == CLIProfile.claude.id,
           let sessionID = session.info.hookSessionID,
           let tasks = TranscriptReader.latestClaudeTaskList(sessionID: sessionID) {
            session.taskList = tasks
        }

        guard let path = session.transcriptPath,
              let text = TranscriptReader.readTail(path: path)
        else { return }

        if let prompt = TranscriptReader.latestUserText(inJSONLines: text) {
            session.lastUserPrompt = prompt
        }
        if session.info.profile.id != CLIProfile.claude.id,
           let tasks = TranscriptReader.latestTaskList(inJSONLines: text) {
            session.taskList = tasks
        }
        // 応答途中の本文も一覧・展開表示に追従させる。完了時はStop処理が
        // 最終本文を確定するため、ここで古い本文を上書きしない。
        if session.state == .thinking {
            let answer = TranscriptReader.latestAssistantText(inJSONLines: text)
            if !answer.isEmpty {
                session.preview = answer
                session.lastReply = answer.joined(separator: " ")
            }
        }
    }

    /// 各セッションの作業ディレクトリを解決する。
    private func refreshWorkingDirectories() async {
        for session in sessions {
            let pid = session.info.pid
            // 作業ディレクトリは一度解決すれば変わらないので、未取得のときだけ求める
            guard pid > 0, session.info.workingDirectory == nil else { continue }

            // ファイルI/Oとlsofを伴うため、メインアクターの外で実行する
            let cwd = await Task.detached {
                ConversationLocator.workingDirectory(pid: pid)
            }.value

            if let cwd {
                var info = session.info
                info.workingDirectory = cwd
                session.replaceInfoPreservingState(info)
            }
        }
    }

    /// Codexの使用量をセッション記録から読み出す。
    /// Codexにはstatuslineの仕組みが無いため、記録の `token_count` イベントを見る。
    @ObservationIgnored private var lastCodexUsageRefreshAt: Date?

    private func refreshCodexUsageIfNeeded(at now: Date = Date()) {
        guard UsagePreferences.isCodexCollectionEnabled else {
            usageByAgent.removeValue(forKey: CLIProfile.codex.id)
            return
        }
        guard sessions.contains(where: { $0.info.profile.id == "codex" }) else { return }
        guard lastCodexUsageRefreshAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastCodexUsageRefreshAt = now
        guard let path = CodexRollout.latestPath() else { return }
        guard let text = TranscriptReader.readTail(path: path) else { return }
        if let stats = UsageParser.parseCodexRateLimits(inJSONLines: text) {
            usageByAgent[stats.agentID] = stats
        }
    }

    /// 使用量の取得を切った直後に、前回値も画面から取り除く。
    func clearUsage(for agentID: String) {
        usageByAgent.removeValue(forKey: agentID)
        if agentID == CLIProfile.codex.id { lastCodexUsageRefreshAt = nil }
    }

    /// 内部状態をJSONで書き出す（診断用）。
    /// `defaults write com.HR.Subghost writeStateDump -bool true` で有効になる。
    /// 常駐アプリはUIしか手掛かりが無く原因調査が難しいため、外から観測できる口を用意する。
    private func writeStateDumpIfEnabled(trigger: String = "poll") {
        guard DiagnosticsPreferences.writeStateDump else { return }

        let payload: [String: Any] = [
            "trigger": trigger,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "activeSessionName": activeSessionName ?? "(なし)",
            "hookServerRunning": hookServerRunning,
            "sessions": sessions.map { session in
                [
                    "tty": session.info.tty,
                    "pid": Int(session.info.pid),
                    "profile": session.info.profile.id,
                    "state": session.state.rawValue,
                    "isMonitorable": session.info.isMonitorable,
                    "monitoringSource": session.info.monitoringSource,
                    "hookSessionID": session.info.hookSessionID ?? "(なし)",
                    "lastActivitySecondsAgo": Date().timeIntervalSince(session.lastActivityAt),
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
        let incoming = Dictionary(uniqueKeysWithValues: agents.map { (SessionInfo(agent: $0).id, $0) })

        // ps由来で、まだフックと結び付いていない消滅プロセスだけを外す。
        // フック由来のバックグラウンドセッションはpsに出ないため保持する。
        let now = Date()
        sessions.removeAll {
            if let endedAt = $0.hookSessionEndedAt, now.timeIntervalSince(endedAt) >= 60 { return true }
            return incoming[$0.info.id] == nil && !$0.info.isHookConnected
        }

        for session in sessions {
            guard let agent = incoming[session.info.id] else { continue }
            var refreshed = SessionInfo(agent: agent)
            refreshed.hookSessionID = session.info.hookSessionID
            refreshed.projectName = session.info.projectName
            refreshed.workingDirectory = session.info.workingDirectory
            refreshed.terminalName = session.info.terminalName
            session.replaceInfoPreservingState(refreshed)
        }

        let existing = Set(sessions.map { $0.info.id })
        for agent in agents where !existing.contains(SessionInfo(agent: agent).id) {
            var info = SessionInfo(agent: agent)
            // ターミナルの特定はプロセス走査を伴うため、検出時に一度だけ行う
            info.terminalName = resolveTerminalName(for: info)
            sessions.append(MonitoredSession(info: info))
        }

        // 表示順を安定させる（CLI種別 → tty）
        sessions.sort {
            ($0.info.profile.id, $0.info.tty) < ($1.info.profile.id, $1.info.tty)
        }

        // 選んでいたセッションが終了したら、ユーザー指定は解除して自動選択に戻す
        if let name = activeSessionName, !sessions.contains(where: { $0.info.id == name }) {
            isActiveSessionUserChosen = false
        }

        if activeSessionName == nil || !sessions.contains(where: { $0.info.id == activeSessionName }) {
            // 前回選択していたセッションが生きていればそれを優先する
            let saved = UserDefaults.standard.string(forKey: "activeSessionName")
            activeSessionName = saved.flatMap { savedID in
                sessions.contains(where: { $0.info.id == savedID }) ? savedID : nil
            }
                // 監視できるセッションを優先して選ぶ
                ?? sessions.first { $0.info.isMonitorable }?.info.id
                ?? sessions.first?.info.id
        }
        preferMonitorableSession()
    }

    /// そのセッションが動いているターミナルの名前を求める
    private func resolveTerminalName(for info: SessionInfo) -> String? {
        TerminalActivator.hostingTerminal(tty: info.tty)?.displayName
    }

    /// 選択中の対象が監視できないままなら、監視できるものへ移す。
    ///
    /// フックは「CLIが動いたとき」にしか発火しないため、放置されたセッションは
    /// いつまでも監視不可のままになる。そちらが選ばれていると、実際には動作している
    /// セッションがあるのに「監視できません」と表示され続けてしまう。
    private func preferMonitorableSession() {
        // ユーザーが明示的に選んだ対象は勝手に変えない。
        guard !isActiveSessionUserChosen else { return }
        guard let active = activeSession, !active.info.isMonitorable else { return }
        guard let better = sessions.first(where: { $0.info.isMonitorable }) else { return }
        activeSessionName = better.info.id
    }

    // MARK: - 表示対象の切替 (設計書 4.3: 複数セッションの選択)

    /// 表示対象を次へ循環切替する。
    func cycleActiveSession() {
        let names = sessions.map { $0.info.id }
        if let next = Self.nextSessionName(in: names, after: activeSession?.info.id) {
            chooseActiveSession(next)
        }
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
        }
        onEvent?(session, event)
    }

    // MARK: - フック方式

    /// フック受信サーバを起動する。失敗時はプロセス検出だけを続ける。
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
            // 監視専用なので、CLIへは受信スレッド上で先に空応答する。
            // MainActorの混雑、ps、記録I/OがCLIを待たせることはない。
            connection.respondPassthrough()
            // サーバは専用スレッドで動くため、状態更新はメインアクターへ移す
            Task { @MainActor in
                await self?.handleHook(request: request)
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
        hookServer?.stop()
        hookServer = nil
        hookServerRunning = false
    }

    private func handleHook(request: HookRequest) async {
        if request.path == "/health" {
            lastHealthCheckAt = Date()
            return
        }
        // statuslineからの使用量は別経路。
        if request.path == "/usage" {
            if let stats = UsageParser.parse(request.body) { usageByAgent[stats.agentID] = stats }
            return
        }
        guard request.path == "/hook", HookTarget(rawValue: request.source) != nil else { return }
        guard let event = HookEventDecoder.decode(request.body) else {
            return
        }
        let receivedAt = Date()
        lastHookEventAt = receivedAt
        lastHookEventAtBySource[request.source] = receivedAt

        var session = matchSession(request: request, event: event)
        if session == nil {
            session = makeHookNativeSession(request: request, event: event)
        }
        guard let session else {
            unmatchedHookEventCount += 1
            // どのセッションにも紐づかなかったことを記録する（原因調査のため）
            NSLog("Subghost: フック \(event.kind.rawValue) の宛先セッションが見つかりません "
                + "(pid=\(request.pid.map(String.init) ?? "なし") tty=\(request.tty ?? "なし") "
                + "sessions=\(sessions.count))")
            writeStateDumpIfEnabled(trigger: "hook:unmatched:\(event.kind.rawValue)")
            return
        }

        // このセッションはフックで監視できていると記録する
        let isFirstHookConnection = session.info.hookSessionID == nil
        var info = session.info
        info.hookSessionID = event.sessionID
        info.projectName = event.projectName
        session.replaceInfoPreservingState(info)
        session.lastActivityAt = Date()
        if event.kind != .sessionEnd { session.hookSessionEndedAt = nil }

        if isFirstHookConnection { session.state = .completed }
        if let path = event.transcriptPath { session.transcriptPath = path }

        // 会話本文の表示を明示的に有効にしている場合だけ記録を読む。
        if !AppearancePreferences.hidePreviewText {
            if event.kind == .userPromptSubmit {
                // 新しい往復が始まったら、前の返信とタスクを混ぜない。
                session.preview = []
                session.lastReply = nil
                session.taskList = []
                if let prompt = event.prompt {
                    session.lastUserPrompt = TranscriptReader.oneLine(prompt)
                } else if let path = session.transcriptPath,
                          let prompt = TranscriptReader.latestUserText(transcriptPath: path) {
                    session.lastUserPrompt = prompt
                }
            } else {
                refreshTranscriptContent(for: session)
            }
        }
        preferMonitorableSession()

        applyHook(event: event, to: session)
        writeStateDumpIfEnabled(trigger: "hook:\(event.kind.rawValue)")
    }

    /// フックのイベントを既知のセッションに突き合わせる。
    /// CLIが発行するsession_idを最優先し、TTYは候補が1つだけの場合に限る。
    private func matchSession(request: HookRequest, event: HookEvent) -> MonitoredSession? {
        if !event.sessionID.isEmpty,
           let match = sessions.first(where: { $0.info.hookSessionID == event.sessionID }) {
            return match
        }
        if let pid = request.pid, let match = sessions.first(where: { $0.info.pid == pid }) {
            return match
        }
        if let tty = request.tty {
            let candidates = sessions.filter { $0.info.tty == tty }
            if candidates.count == 1 { return candidates[0] }
        }
        // 最後の手段: 同じ作業ディレクトリのセッションが1つだけならそれとみなす
        if let project = event.projectName {
            let candidates = sessions.filter { $0.info.folderName == project }
            if candidates.count == 1 { return candidates.first }
        }
        return nil
    }

    private func makeHookNativeSession(request: HookRequest, event: HookEvent) -> MonitoredSession? {
        guard !event.sessionID.isEmpty,
              CLIProfile.builtins.contains(where: { $0.id == request.source })
        else { return nil }
        let info = SessionInfo(
            hookSource: request.source,
            sessionID: event.sessionID,
            pid: request.pid,
            tty: request.tty,
            cwd: event.cwd
        )
        let session = MonitoredSession(info: info)
        sessions.append(session)
        sessions.sort { ($0.info.profile.id, $0.info.id) < ($1.info.profile.id, $1.info.id) }
        return session
    }

    private func applyHook(
        event: HookEvent,
        to session: MonitoredSession
    ) {
        switch event.kind {
        case .stop:
            // フックは完了を知らせるだけで本文を持たないため、記録から応答を読み出す
            let answer: [String]
            if !AppearancePreferences.hidePreviewText, let path = event.transcriptPath {
                answer = session.preview.isEmpty
                    ? TranscriptReader.latestAssistantText(transcriptPath: path)
                    : session.preview
            } else {
                answer = []
            }
            let reply = answer.joined(separator: " ")
            session.lastReply = reply.isEmpty ? nil : reply
            apply(event: .becameCompleted(preview: answer.isEmpty ? ["応答が完了しました"] : answer),
                  to: session)

        case .stopFailure:
            apply(event: .becameError(preview: ["APIエラーでタスクが終了しました"]), to: session)

        case .sessionStart:
            session.state = .completed
            SoundAlerts.shared.play(.sessionStart, session: session.info)

        case .sessionEnd:
            session.state = .completed
            session.hookSessionEndedAt = Date()

        case .preCompact:
            // コンテキストが逼迫していることを音だけで知らせる（状態は変えない）
            SoundAlerts.shared.play(.contextLimit, session: session.info)

        case .userPromptSubmit, .preToolUse, .postToolUse, .postCompact,
             .subagentStart, .subagentStop,
             .notification, .permissionRequest:
            // サブエージェントの終了では親がまだ作業中なので完了扱いにしない
            if session.state != .thinking {
                apply(event: .becameThinking, to: session)
            }
        }
    }

    /// 完了は次のタスク開始まで保持する。
    func acknowledge(_ session: MonitoredSession) {
        // 監視表示だけなので、通知を開いても状態は変えない。
    }
}
