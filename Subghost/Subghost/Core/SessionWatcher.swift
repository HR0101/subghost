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
//  2つの監視経路が合流する場所であり、ここが本ファイルの要点:
//  - フック経路: CLIからのイベントが正、tmux不要（Claude Code / Codex）
//  - tmux経路 : capture-pane の画面文字から推測、tmuxが要る（全CLI）
//
//  一度フックが繋がったセッションには StateDetector.ingest を二度と呼ばない。
//  画面解析が止まるため、イベントを取りこぼすと Working のまま固まる。
//  その唯一の受け皿が reconcileStaleHookState で、tmuxがあれば取り直し、
//  無ければ一定時間後に idle へ倒す。フック処理を触るときもこの網は残すこと。
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
    private(set) var tmuxAvailable = true

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

    /// フック未着イベント（stopが来ない等）で固着した .thinking を裏取りするまでの猶予。
    /// 短すぎるとフックイベント到着直後の一瞬を誤って裏取りしかねないため、数秒は待つ。
    private static let hookStaleCheckDelay: TimeInterval = 5.0
    /// tmuxで裏取りできても busy/prompt のどちらとも判定できない画面が続いた場合の猶予
    private static let hookStaleUnknownScreenInterval: TimeInterval = 30.0
    /// tmuxが無く画面で裏取りできない場合、最後の手段として強制的にidleへ戻すまでの猶予
    private static let hookStaleForceIdleInterval: TimeInterval = 600.0
    /// completed のまま放置された場合にidleへ自動遷移するまでの秒数（tmux接続時のStateDetectorと揃える）
    private static let completedHoldInterval: TimeInterval = 8.0

    func pollOnce() async {
        tmuxAvailable = TmuxClient.resolveTmuxPath() != nil

        // 1. 実行中プロセスからAI CLIを検出する（エイリアス・命名規則に依存しない）
        let agents = await AgentDiscovery.discover(profiles: CLIProfile.withCustomAliases(customAliases))
        reconcile(agents: agents)

        // tmuxが持っている最終出力時刻を取り込む（放置セッションの判定に使う）。
        // 全ペイン分を1回のtmux呼び出しでまとめて取る。
        if tmuxAvailable {
            let activity = await TmuxClient.activityByTTY()
            for session in sessions {
                if let at = activity[session.info.tty] { session.tmuxActivityAt = at }
            }
        }

        // 2. 状態判定。フック接続の有無で経路が異なる。
        let now = Date()
        let stable = UserDefaults.standard.object(forKey: "stableInterval") as? Double ?? 1.5
        for session in sessions {
            if session.info.isHookConnected {
                // フックイベント自体は正確だが、取りこぼし（フックサーバ再起動、CLIの
                // クラッシュ、stopイベント未着等）が起きると自己修復する手段が無く
                // Working等のまま永久に固着してしまう。ingestによる画面解析は
                // フック接続後は行わないため、ここで独立した安全網をかける。
                await reconcileStaleHookState(session: session, at: now)
                continue
            }
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

        refreshCodexUsage()
        await refreshConversationTails()
        writeStateDumpIfEnabled()
    }

    /// フック接続セッションの状態が、実際のCLIの様子と食い違っていないか裏取りする（安全網）。
    /// tmuxも繋がっていれば画面で確認し、無ければ長時間経過を根拠に強制的に戻す。
    private func reconcileStaleHookState(session: MonitoredSession, at now: Date) async {
        switch session.state {
        case .thinking:
            let elapsed = now.timeIntervalSince(session.lastActivityAt)
            guard elapsed >= Self.hookStaleCheckDelay else { return }
            let profile = session.info.profile

            if let target = session.info.tmuxTarget,
               let text = await TmuxClient.capturePane(target: target) {
                let cleaned = StateDetector.clean(text, profile: profile)
                // busyの判定は経過時間・トークン数を残したテキストで行う
                // (StateDetector.stripDecoration のコメント参照)
                if StateDetector.matches(
                    pattern: profile.busyPattern,
                    in: StateDetector.stripDecoration(text, profile: profile)) {
                    return   // 実際にまだ動作中
                }
                if StateDetector.matches(
                    pattern: profile.promptPattern, in: StateDetector.tail(of: cleaned, lines: 12)) {
                    session.state = .completed
                    session.lastCompletedAt = now
                    session.preview = StateDetector.extractPreview(from: text, profile: profile)
                    return
                }
                // busyでもプロンプト待ちでもない画面（予期しない表示等）は判定を急がず、
                // 猶予をおいてもなお変わらなければ安全側のidleへ倒す
                if elapsed >= Self.hookStaleUnknownScreenInterval {
                    session.state = .idle
                }
            } else if elapsed >= Self.hookStaleForceIdleInterval {
                // 画面を確認する手段が無い場合の最後の保険
                session.state = .idle
            }

        case .completed:
            guard let completedAt = session.lastCompletedAt,
                  now.timeIntervalSince(completedAt) >= Self.completedHoldInterval
            else { return }
            session.state = .idle

        default:
            return
        }
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
            if session.info.pid != agent.pid || session.info.tmuxTarget != agent.tmuxTarget {
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
        // tmux配下ではペインのptyであり、アタッチ中クライアントのttyとは別物
        let tty = info.tmuxSession == nil ? info.tty : nil
        guard let tty else { return nil }
        return TerminalActivator.hostingTerminal(tty: tty)?.displayName
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

    // MARK: - プロンプト送信 (設計書 4.3 / PromptSender)

    func sendPrompt(_ text: String, to session: MonitoredSession) async throws {
        // フック接続セッションの固着検知は「最後の活動時刻」からの経過時間を見るため、
        // ここで動かさないと直前のフックイベントからの古い経過時間のまま安全網が
        // 誤って発動しうる（プロンプト送信直後に stale 判定されてしまう）。
        session.lastActivityAt = Date()

        // 送信経路は tmux だけ。キー入力の合成は対象タブを前面に出す必要があり、
        // 「裏で動いているCLIへ送る」という前提を満たせないため使わない。
        // 送れないセッションでは、そもそも入力欄を出さない（UI側で抑止済み）。
        guard let target = session.info.tmuxTarget else {
            throw SessionError.notMonitorable
        }
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
        try await respond(with: [option], in: session)
    }

    /// 複数選択の回答をまとめて送信する。
    /// 単一選択でも要素1つの配列として扱えるため、こちらが実体になる。
    func respond(with options: [ChoiceOption], in session: MonitoredSession) async throws {
        guard let first = options.first else { return }
        let isMultiSelect = session.pendingChoice?.isMultiSelect ?? false
        // sendPromptと同じ理由で、フック接続セッションの固着検知が誤発動しないよう
        // ユーザー操作の瞬間に「最後の活動時刻」を更新しておく
        session.lastActivityAt = Date()

        // フック経由の承認は、待たせている接続に判定を返すだけでよい（キー送信は不要）
        if session.pendingHookConnection != nil {
            let decision: HookDecision = first.isNegative
                ? .deny(reason: "Subghostで拒否しました")
                : .allow
            session.releasePendingHook(with: decision)
            session.pendingChoice = nil
            session.state = .thinking
            return
        }

        guard let target = session.info.tmuxTarget else {
            // tmuxもフック接続も無い場合、背景のタブへ入力を届ける手段がない。
            // キー入力の合成は「前面のタブ」にしか届かず、他を見ている間は送れないため、
            // 空振りさせずに理由を返す（誤送信も防ぐ）。
            throw SessionError.backgroundInputUnavailable
        }

        // フールプルーフ: 表示してから回答するまでの間に画面が別の内容へ進んでいないか、
        // キーを送る前に確かめる。読めた場合のみ照合し、崩れていれば中止する。
        // (実機で確認した不具合: 会話が進んだ後の画面に古い前提のままキーを送り誤爆した)
        let expectedLabels = (session.pendingChoice?.options ?? options).map(\.label)
        if let currentText = await TmuxClient.capturePane(target: target),
           !ChoicePrompt.matchesCurrentScreen(optionLabels: expectedLabels, in: currentText) {
            throw SessionError.choiceScreenChanged
        }

        // フォールバック用の総数は「選んだ数」ではなく「この問いの選択肢の総数」。
        // 選ばなかった項目があると、選んだ数だけでは↓が足りず自由記述欄止まりになる。
        let totalOptionCount = session.pendingChoice?.options.count ?? options.count

        if isMultiSelect {
            try await TmuxClient.sendChoices(options, totalOptionCount: totalOptionCount, to: target)
        } else {
            try await TmuxClient.sendChoice(first, totalOptionCount: totalOptionCount, to: target)
        }
        session.pendingChoice = nil

        // 同じ呼び出しに問いが残っていれば、完了扱いにせず次の1問を出す
        if !session.questionQueue.isEmpty {
            presentNextQuestion(in: session)
            return
        }

        let event = session.detector.noteUserAnsweredChoice(at: Date())
        apply(event: event, to: session)
        if event == .none { session.state = .thinking }
    }

    /// 残りの質問から次の1問をノッチへ出す。
    ///
    /// CLIは前の回答を受け取ってから次の問いを描画するため、すぐに次を出すと
    /// 送ったキーが前の画面に入ってしまう。描画が追いつく分だけ待ってから表示する。
    private func presentNextQuestion(in session: MonitoredSession) {
        guard !session.questionQueue.isEmpty else { return }
        session.state = .awaitingAnswer

        Task { [weak self] in
            try? await Task.sleep(for: Self.nextQuestionDelay)
            guard let self, !session.questionQueue.isEmpty else { return }
            let next = session.questionQueue.removeFirst()
            self.apply(event: .becameAwaitingChoice(next), to: session)
        }
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

        // フックが今回初めて繋がったセッションで、直前の状態が「画面解析由来かもしれない
        // thinking」だった場合、それを信用しない。フック接続後は画面解析(ingest)が
        // 二度と行われず、フックイベントだけが状態を動かす頼りになるため、ここで
        // リセットしておかないと、対応するフックイベントが来ない限り Working のまま
        // 永久に固着してしまう。
        // (実機で確認した不具合: 開発中に何度も再起動する過程で、起動直後の一瞬に
        //  画面上のスピナー等の残骸を busyPattern と誤判定し、フック接続後もずっと
        //  そのまま残り続けていた)
        if isFirstHookConnection, session.state == .thinking {
            session.state = .idle
        }
        // 一覧に出すため、直近のユーザー発言を記録から拾う
        if let path = event.transcriptPath,
           let prompt = TranscriptReader.latestUserText(transcriptPath: path) {
            session.lastUserPrompt = prompt
        }
        // 実際に動いているセッションを送信先にする
        preferMonitorableSession()

        applyHook(event: event, to: session, connection: connection)
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
        to session: MonitoredSession,
        connection: HookServer.Connection
    ) {
        // 直前の承認待ちが未解決なら解放しておく（取りこぼし防止）
        if event.kind != .permissionRequest {
            session.releasePendingHook(with: .passthrough)

            // フック接続済みセッションは画面解析(ingest)を行わないため、ターミナル側で
            // 直接選択肢に回答された場合、それを検知して pendingChoice を解消する手段が
            // 他に無い。ここで拾わないと、ノッチに古い選択肢が居座り続けてしまう。
            // (permissionRequest は .becameAwaitingChoice で確実に上書きされるので対象外)
            //
            // notification は対象から除く。Claude Codeは無回答が続くと催促のため
            // notification を繰り返し送ってくることがあり、それを「解消された」と
            // 誤判定してノッチを閉じてしまっていた（実機で確認した不具合）。
            // notification 自体は直後の分岐で記録を読み直し、本当に解消したかを
            // 正しく判定する。
            if session.pendingChoice != nil, event.kind != .notification {
                apply(event: .choiceResolved, to: session)
            }
        }

        switch event.kind {
        case .permissionRequest:
            // AskUserQuestion は「ツール実行の許可」ではなく「選択肢への回答」なので、
            // 許可/拒否の2択で見せるのは誤り。自動で許可し、Claude Codeに本来の
            // 質問を出させてから、Notification経由で実際の選択肢を表示する。
            if event.toolName == "AskUserQuestion" {
                // ツール実行を許可し、Claude Codeに本来の質問を出させる。
                connection.respond(json: HookDecision.allow.json)
                // 選択肢は tool_input に入っているので、記録を待たずそのまま表示する。
                // 複数の問いが含まれる場合は、先頭を出して残りをキューへ積む。
                if !event.embeddedQuestions.isEmpty {
                    enqueue(questions: event.embeddedQuestions, in: session)
                } else {
                    session.state = .awaitingAnswer
                    onEvent?(session, .none)
                    if let path = event.transcriptPath { pollForQuestion(path: path, in: session) }
                }
                return
            }

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
            // Notificationのペイロードには本文しか入っていないため、
            // セッション記録から直近の質問と選択肢を復元して選べるようにする。
            //
            // 重要: Claude Codeは質問を記録へ書き込む前にNotificationを発火する（実測）。
            // 発火直後は記録に未回答の質問が無いため、少し待ってから読み直す。
            //
            // また、Claude Codeは無回答が続くと催促のためにも Notification を送ってくる。
            // 質問と無関係なNotificationまで「質問中」として表示すると、実際には
            // 何も聞かれていないのに状態が変わってしまう（実機で確認した不具合）。
            // そのため、質問が実際に見つかるまでは状態を変えずポーリングだけ行う。
            let questions = event.transcriptPath
                .map { TranscriptReader.latestQuestions(transcriptPath: $0) } ?? []
            if !questions.isEmpty {
                enqueue(questions: questions, in: session)
            } else if let path = event.transcriptPath {
                pollForQuestion(path: path, in: session)
            }

        case .stop:
            // フックは完了を知らせるだけで本文を持たないため、記録から応答を読み出す
            let answer = event.transcriptPath
                .map { TranscriptReader.latestAssistantText(transcriptPath: $0) } ?? []
            apply(event: .becameCompleted(preview: answer.isEmpty ? ["応答が完了しました"] : answer),
                  to: session)

        case .stopFailure:
            apply(event: .becameError(preview: [event.title]), to: session)

        case .sessionStart:
            session.state = .idle
            session.pendingChoice = nil
            session.questionQueue = []
            SoundAlerts.shared.play(.sessionStart, session: session.info)

        case .sessionEnd:
            session.state = .idle
            session.pendingChoice = nil
            session.questionQueue = []

        case .preCompact:
            // コンテキストが逼迫していることを音だけで知らせる（状態は変えない）
            SoundAlerts.shared.play(.contextLimit, session: session.info)

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
