//
//  SessionWatcher.swift
//  Subghost
//
//  設計書 3.3: SessionWatcher（pane出力の監視、状態遷移の判定）
//            SessionManager（監視対象セッションの選択・切替）
//
//  監視の中枢。検出したセッションを MonitoredSession として保持し、
//  一定間隔の pollOnce() で状態を更新する。副作用（通知・音・記録）はここが持ち、
//  判定そのものは純粋ロジックの StateDetector に任せる。
//
//  状態監視はCLIフックだけを正とする。端末画面の解析と入力送信は行わない。
//

import Foundation
import Observation

/// セッション操作のエラー
nonisolated enum SessionError: Error, LocalizedError {
    case notMonitorable
    case backgroundInputUnavailable
    /// 表示してから回答するまでの間に画面の内容が変わっていた（フールプルーフ: 送らずに中止）
    case choiceScreenChanged

    var errorDescription: String? {
        switch self {
        case .notMonitorable:
            return "このセッションはtmuxの外で動いているため、送信できません。tmux内で起動し直すと操作できます。"
        case .backgroundInputUnavailable:
            return "他の画面を見ながら回答するには tmux が必要です。"
                + "ターミナルで tmux を実行してからCLIを起動すると、ノッチから直接回答できます。"
        case .choiceScreenChanged:
            return "表示してから画面の内容が変わったため、誤操作を避けて送信を中止しました。"
                + "ターミナルで直接ご確認ください。"
        }
    }
}

// MARK: - 一覧に出すかどうかの判断 (純粋ロジック)

/// 「もう使っていないセッション」を一覧から外すための判断。
///
/// 使い終わった CLI はプロセスとしては生き続けるため、放っておくと一覧が
/// 過去のセッションで埋まる。ただし**隠すのは表示だけ**で監視は続けており、
/// 回答が必要になったセッションは条件に関わらず必ず表示する（見逃し防止）。
///
/// I/O を持たない純粋な判断にしてあるので、固定の `Date` で単体テストできる。
nonisolated enum SessionVisibility {

    /// 判断に使うセッション側の状態
    struct Input {
        /// 承認待ち・質問待ちなど、答えないとCLIが進めない状態か
        var needsUserResponse: Bool
        /// 現在プロンプトの送信先に選ばれているか
        var isActiveTarget: Bool
        /// tmux かフックで監視・操作できるか
        var isMonitorable: Bool
        /// 最後に動きがあった時刻（tmuxの記録を含む）
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
        // 回答しないとCLIが止まるものは、どの設定よりも優先して見せる
        if input.needsUserResponse { return true }
        // 送信先が一覧から消えると、どこへ送るのか分からなくなる
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
    /// 解決済みの作業ディレクトリ（表示用）
    var workingDirectory: String?
    /// 最後に何か動きがあった時刻（経過時間の表示に使う）
    var lastActivityAt: Date = Date()
    /// tmuxが記録しているペインの最終出力時刻。
    /// `lastActivityAt` はフック受信時にしか動かないため、tmux経路のセッションでは
    /// Subghostの起動時刻のまま止まってしまう。放置されたセッションを見分けるには
    /// Subghostの再起動をまたいでも失われないこちらが要る。
    var tmuxActivityAt: Date?
    /// ユーザーが一覧から手動で外したときの、その時点での活動時刻。
    /// これより新しい動きがあれば「また使い始めた」とみなして自動的に戻す。
    var hiddenAtActivity: Date?

    /// 表示・放置判定に使う、最も新しい活動時刻
    var effectiveActivityAt: Date {
        guard let tmuxActivityAt else { return lastActivityAt }
        return max(lastActivityAt, tmuxActivityAt)
    }
    /// ノッチから回答すべき選択肢（承認/質問）。なければ nil。
    var pendingChoice: PendingChoice?
    /// まだ尋ねていない残りの質問。
    /// AskUserQuestion は複数の問いを1回で送ってくるが、CLIは1問ずつ順に尋ねる。
    /// 1問答えるたびにここから次を取り出して表示する。
    @ObservationIgnored var questionQueue: [PendingChoice] = []

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
        questionQueue = []
        lastCompletedAt = nil
    }

    /// この選択肢に回答を返せるか。
    /// 承認はフックの戻り値で答えられるが、質問への回答はCLIへ文字を送る必要があり、
    /// tmuxを介していないセッションでは送る手段がない。
    /// 背景（他の画面を見ている間）でも回答を届けられるか。
    /// フックの戻り値かtmuxのpty書き込みのみが該当する。キー入力の合成は前面タブが要るため含めない。
    var canRespondToChoice: Bool {
        pendingHookConnection != nil || info.tmuxTarget != nil
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

    /// 1問答えてから次の問いをノッチへ出すまでの待ち時間。
    /// CLIが次の問いを描画し終える前に出すと、送ったキーが前の画面に入る。
    static let nextQuestionDelay = Duration.milliseconds(500)

    private(set) var sessions: [MonitoredSession] = []
    var activeSessionName: String? {
        didSet {
            guard oldValue != activeSessionName else { return }
            UserDefaults.standard.set(activeSessionName, forKey: "activeSessionName")
        }
    }
    /// 旧UIとのソース互換用。tmux方式は廃止したため常にfalse。
    private(set) var tmuxAvailable = false

    /// 送信先をユーザーが明示的に選んだか。
    /// 真のあいだは自動切り替えを行わない（意図しないCLIへの誤送信を防ぐ）。
    private(set) var isActiveSessionUserChosen = false

    /// ユーザー操作による送信先の指定
    func chooseActiveSession(_ tty: String) {
        activeSessionName = tty
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
    @ObservationIgnored private var hookServer: HookServer?

    /// 状態遷移イベントの通知先（AppCoordinatorが設定）
    @ObservationIgnored var onEvent: ((MonitoredSession, DetectorEvent) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var activeSession: MonitoredSession? {
        sessions.first { $0.info.tty == activeSessionName } ?? sessions.first
    }

    // MARK: - 一覧に出すセッションの絞り込み

    /// 一覧に出すセッション。
    ///
    /// 絞り込みは**表示だけ**の話で、監視は全セッションに対して続ける。
    /// 隠したセッションで承認待ちが起きたら見逃しになるため、
    /// 回答が要る状態と現在の送信先は、どの条件よりも優先して必ず出す。
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
                needsUserResponse: session.state.needsUserResponse,
                isActiveTarget: session.info.tty == activeSessionName,
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

    /// セッションのCLIプロセスを終了させる。
    ///
    /// 取り消せない操作なので、呼び出し側で必ず確認を取ること。
    /// SIGKILLではなくSIGTERMを送り、CLIに後始末（記録の書き出し等）をさせる。
    func terminate(_ session: MonitoredSession) {
        guard session.info.pid > 0 else { return }
        kill(session.info.pid, SIGTERM)
        // 次の巡回でプロセスが消えていれば reconcile が一覧から外す。
        // 終了を待たずに一覧から消して、押した手応えを返す。
        session.hiddenAtActivity = session.effectiveActivityAt
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

    /// ユーザー登録のカスタムエイリアス（AppCoordinatorが変更のたびに同期する）
    var customAliases: [CustomAlias] = []

    /// Stopイベントを取りこぼした場合、Working表示を永久に残さないための安全弁。
    private static let hookStaleForceIdleInterval: TimeInterval = 600.0

    func pollOnce() async {
        // 1. 実行中プロセスからAI CLIを検出する（エイリアス・命名規則に依存しない）
        let agents = await AgentDiscovery.discover(profiles: CLIProfile.withCustomAliases(customAliases))
        reconcile(agents: agents)

        // 2. 状態はフックだけで更新する。画面文字のポーリングはしない。
        let now = Date()
        for session in sessions {
            await reconcileStaleHookState(session: session, at: now)
        }

        refreshCodexUsage()
        await refreshConversationTails()
        writeStateDumpIfEnabled()
    }

    /// Stopイベントを取りこぼしてもWorkingが永久に残らないようにする安全網。
    private func reconcileStaleHookState(session: MonitoredSession, at now: Date) async {
        guard session.state == .thinking,
              now.timeIntervalSince(session.lastActivityAt) >= Self.hookStaleForceIdleInterval
        else { return }
        session.state = .completed
    }

    /// 各セッションの直近のやり取りを記録から読み出す。
    /// 状態（動作中か）が分からないセッションでも、送ったプロンプトと返信は出せる。
    private func refreshConversationTails() async {
        for session in sessions {
            let pid = session.info.pid
            let profileID = session.info.profile.id
            let needsTail = !(session.info.isHookConnected && session.lastUserPrompt != nil)
            // 作業ディレクトリは一度解決すれば変わらないので、未取得のときだけ求める
            let needsCwd = session.info.workingDirectory == nil

            guard needsTail || needsCwd else { continue }

            // ファイルI/Oとlsofを伴うため、メインアクターの外で実行する
            let result = await Task.detached { () -> (ConversationTail, String?) in
                let cwd = needsCwd ? ConversationLocator.workingDirectory(pid: pid) : nil
                let tail = needsTail
                    ? ConversationLocator.conversationTail(pid: pid, profileID: profileID)
                    : ConversationTail(userPrompt: nil, assistantReply: nil)
                return (tail, cwd)
            }.value

            if let prompt = result.0.userPrompt { session.lastUserPrompt = prompt }
            if let reply = result.0.assistantReply { session.lastReply = reply }
            if let cwd = result.1 {
                var info = session.info
                info.workingDirectory = cwd
                session.replaceInfoPreservingState(info)
            }
        }
    }

    /// Codexの使用量をセッション記録から読み出す。
    /// Codexにはstatuslineの仕組みが無いため、記録の `token_count` イベントを見る。
    private func refreshCodexUsage() {
        guard sessions.contains(where: { $0.info.profile.id == "codex" }) else { return }
        guard let path = CodexRollout.latestPath() else { return }
        guard let text = TranscriptReader.readTail(path: path) else { return }
        if let stats = UsageParser.parseCodexRateLimits(inJSONLines: text) {
            usageByAgent[stats.agentID] = stats
        }
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
        let incoming = Dictionary(agents.map { ($0.tty, $0) }, uniquingKeysWith: { first, _ in first })

        // 消えたセッションを外す
        sessions.removeAll { incoming[$0.info.tty] == nil }

        for session in sessions {
            guard let agent = incoming[session.info.tty] else { continue }
            // 同じttyでもCLIが再起動していれば作り直す必要がある
            if session.info.pid != agent.pid {
                session.replaceInfo(SessionInfo(agent: agent))
            }
        }

        let existing = Set(sessions.map { $0.info.tty })
        for agent in agents where !existing.contains(agent.tty) {
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
        if let name = activeSessionName, incoming[name] == nil {
            isActiveSessionUserChosen = false
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

    /// そのセッションが動いているターミナルの名前を求める
    private func resolveTerminalName(for info: SessionInfo) -> String? {
        TerminalActivator.hostingTerminal(tty: info.tty)?.displayName
    }

    /// 送信先が監視できないセッションのままなら、監視できるものへ移す。
    ///
    /// フックは「CLIが動いたとき」にしか発火しないため、放置されたセッションは
    /// いつまでも監視不可のままになる。そちらが選ばれていると、実際には動作している
    /// セッションがあるのに「監視できません」と表示され続けてしまう。
    private func preferMonitorableSession() {
        // ユーザーが明示的に選んだ送信先は勝手に変えない。
        // 変えてしまうと、監視できないセッションを選んで入力している最中に
        // 送信先がすり替わり、別のCLIへプロンプトが飛ぶ。
        guard !isActiveSessionUserChosen else { return }
        guard let active = activeSession, !active.info.isMonitorable else { return }
        guard let better = sessions.first(where: { $0.info.isMonitorable }) else { return }
        activeSessionName = better.info.tty
    }

    // MARK: - 送信先の切替 (設計書 4.3: 複数セッションの選択)

    /// 送信先セッションを次へ循環切替する（入力モードのTabキー用）
    /// 送信できないセッションは飛ばす。
    func cycleActiveSession() {
        let names = sessions.filter { $0.info.canSendPrompt }.map { $0.info.tty }
        if let next = Self.nextSessionName(in: names, after: activeSession?.info.tty) {
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
            // 一連の問いは終わっている。積み残しを次の応答へ持ち越さない。
            session.questionQueue = []
        case .becameError(let preview):
            session.state = .error
            session.preview = preview
            session.questionQueue = []
        case .becameIdle:
            session.state = .idle
            session.questionQueue = []
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
        // statuslineからの使用量は別経路。応答は不要なので即座に返す。
        if request.path == "/usage" {
            if let stats = UsageParser.parse(request.body) { usageByAgent[stats.agentID] = stats }
            connection.respondPassthrough()
            return
        }
        guard let event = HookEventDecoder.decode(request.body) else {
            // 解釈できない形式ならCLI本来の挙動に任せる
            connection.respondPassthrough()
            return
        }
        lastHookEventAt = Date()

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
        let isFirstHookConnection = session.info.hookSessionID == nil
        var info = session.info
        info.hookSessionID = event.sessionID
        info.projectName = event.projectName
        session.replaceInfoPreservingState(info)
        session.lastActivityAt = Date()

        if isFirstHookConnection { session.state = .completed }
        // 一覧に出すため、直近のユーザー発言を記録から拾う
        if let path = event.transcriptPath,
           let prompt = TranscriptReader.latestUserText(transcriptPath: path) {
            session.lastUserPrompt = prompt
        }
        preferMonitorableSession()

        applyHook(event: event, source: request.source, to: session, connection: connection)
        writeStateDumpIfEnabled(trigger: "hook:\(event.kind.rawValue)")
    }

    /// 記録に質問が書かれるまで短い間隔で読み直す。
    /// Notification発火時点では質問がまだ記録に無いため（実測）、遅れて現れるのを待つ。
    private func pollForQuestion(path: String, in session: MonitoredSession) {
        Task { @MainActor in
            // 0.3秒間隔で最大2秒ほど待つ
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(300))
                // 既に選択肢が表示されていたら打ち切る（別経路で先に見つかった等）。
                // 状態そのものは呼び出し元で変えていないため、質問と無関係な
                // 催促Notificationのポーリング中に completed/idle へ進んでいても
                // 問題なく空振りできる。
                guard session.pendingChoice == nil else { return }
                let questions = TranscriptReader.latestQuestions(transcriptPath: path)
                if !questions.isEmpty {
                    enqueue(questions: questions, in: session)
                    return
                }
            }
        }
    }

    /// 一連の質問を受け取り、先頭をノッチへ出して残りをキューに積む
    private func enqueue(questions: [PendingChoice], in session: MonitoredSession) {
        guard let first = questions.first else { return }
        session.questionQueue = Array(questions.dropFirst())
        apply(event: .becameAwaitingChoice(first), to: session)
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
        source: String,
        to session: MonitoredSession,
        connection: HookServer.Connection
    ) {
        // 監視専用。すべてのフックへ即座に空応答を返し、CLIの入力や承認には介入しない。
        connection.respondPassthrough()
        switch event.kind {
        case .stop:
            // フックは完了を知らせるだけで本文を持たないため、記録から応答を読み出す
            let answer = event.transcriptPath
                .map { TranscriptReader.latestAssistantText(transcriptPath: $0) } ?? []
            apply(event: .becameCompleted(preview: answer.isEmpty ? ["応答が完了しました"] : answer),
                  to: session)

        case .stopFailure:
            apply(event: .becameCompleted(preview: ["タスクが終了しました"]), to: session)

        case .sessionStart:
            session.state = .completed
            session.pendingChoice = nil
            session.questionQueue = []
            SoundAlerts.shared.play(.sessionStart, session: session.info)

        case .sessionEnd:
            session.state = .completed
            session.pendingChoice = nil
            session.questionQueue = []

        case .preCompact:
            // コンテキストが逼迫していることを音だけで知らせる（状態は変えない）
            SoundAlerts.shared.play(.contextLimit, session: session.info)

        case .userPromptSubmit, .preToolUse, .postToolUse, .subagentStop,
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
