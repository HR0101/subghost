//
//  AppCoordinator.swift
//  Subghost
//
//  設計書 3.3: NotchViewModel（UI状態の保持・更新）＋各コンポーネントの結線
//

import AppKit
import Observation

/// ノッチの表示モード (設計書 6.2)
enum NotchMode: Equatable {
    case compact        // 状態アイコンのみ
    case notification   // 応答チラ見せ
    case input          // プロンプト入力欄
    case choice         // 承認リクエスト／質問への回答
    case sessions       // 複数CLIの一覧
    case activity       // 完了・エラー・回答待ちの履歴
    case onboarding      // 初回起動時の案内
}

/// 初回起動時の案内（ようこそ→フック連携→権限確認→完了）の各段階
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case hooks
    case permissions
    case done
}

/// セッションを切り替えても入力途中の内容を混ぜないための下書き置き場。
nonisolated struct PromptDraftStore {
    private var drafts: [String: String] = [:]

    func text(for key: String) -> String {
        drafts[key] ?? ""
    }

    mutating func setText(_ text: String, for key: String) {
        drafts[key] = text
    }
}

@Observable
final class AppCoordinator {

    static let shared = AppCoordinator()

    let watcher = SessionWatcher()
    let snippets = SnippetStore()
    let activity = ActivityStore()
    let hotkey = HotkeyManager()
    let customAliasStore = CustomAliasStore()
    /// セッション個別のミュート（実行中のみ保持。AlertGate から参照される）
    let sessionMutes = SessionMuteStore()
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var notificationPresentationTask: Task<Void, Never>?
    /// ユーザーが閉じた問い合わせ（セッション名 → 内容）。同じ内容では再展開しない。
    @ObservationIgnored private var dismissedChoices: [String: PendingChoice] = [:]

    private(set) var mode: NotchMode = .compact
    /// パネルコントローラが算出したノッチ寸法（ビューが形状描画に使う）
    var notchMetrics: NotchMetrics?
    private(set) var isHovering = false {
        didSet { hoverChanged() }
    }
    private var isPointerInside = false
    /// 通知展開で表示中のセッション
    private(set) var notificationSession: MonitoredSession?
    /// 承認/質問の回答待ちで表示中のセッション
    private(set) var choiceSession: MonitoredSession?
    /// セッションごとの入力下書き。TTY再利用時の混同を避けるためPIDも含める。
    private var promptDrafts = PromptDraftStore()
    var inputText: String {
        get { promptDrafts.text(for: promptDraftKey) }
        set { promptDrafts.setText(newValue, for: promptDraftKey) }
    }
    var lastSendError: String?
    /// 回答送信に失敗したときのメッセージ
    var lastChoiceError: String?
    /// 回答を送信中か（二重送信の防止と表示用）
    private(set) var isSendingChoice = false
    /// 送信できた選択肢のラベル（一瞬「送信しました」を出す）
    private(set) var choiceSentLabel: String?
    /// 消音中か（一覧のスピーカーアイコンと連動）。
    /// SoundAlerts.isEnabled はUserDefaultsを都度読むだけの static var で、@Observable の
    /// 変更検知の対象にならない（他クラスの静的プロパティのため）。ここにストアドプロパティとして
    /// キャッシュし、変更のたびに明示的に更新することでボタンの見た目を追従させる。
    /// (実機で確認した不具合: ボタンを押しても消音自体は効くが、アイコン表示が変わらなかった)
    private(set) var isMuted: Bool = !SoundAlerts.isEnabled
    @ObservationIgnored private var soundDefaultsObserver: NSObjectProtocol?

    // MARK: - 初回起動の案内

    @ObservationIgnored private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// フック有効化ボタンを押した結果（成功メッセージ／エラー）。ステップごとに保持する。
    var onboardingHookMessage: [HookTarget: String] = [:]

    /// 実際に画面へ出す表示モード（ホバー時は軽く展開してプレビュー: 設計書 6.4）
    var displayMode: NotchMode {
        if mode == .input { return .input }
        // 送信中／送信完了表示のあいだは一覧へ切り替えない
        if mode == .choice { return .choice }
        // 初回案内は、本当に急ぎの選択肢対応の次に優先する。
        // 通知や一覧に割り込まれて案内が埋もれないようにするため。
        if mode == .onboarding { return .onboarding }
        if mode == .notification { return .notification }
        // 入力画面の戻るボタンから開いた一覧は、ホバーが外れても表示を維持する。
        if mode == .sessions { return .sessions }
        if mode == .activity { return .activity }
        // ホバー中は常に一覧を出す。
        // メニューバー項目を置かないため、ここが設定・終了への唯一の入口になる。
        if isHovering { return .sessions }
        return .compact
    }

    /// 承認モードで表示中の選択肢
    var pendingChoice: PendingChoice? { choiceSession?.pendingChoice }

    // MARK: - 起動

    func start() {
        NotificationManager.shared.setup()
        SoundAlerts.shared.play(.appLaunched)

        // 監視より先にパネルを用意する。
        // 起動直後の1回目のポーリングで承認待ちを見つけた場合、
        // パネルが未生成だとノッチを開けないため。
        panelController = NotchPanelController(coordinator: self)
        panelController?.show()

        hotkey.onAction = { [weak self] action in
            self?.perform(action)
        }
        hotkey.register()

        watcher.onEvent = { [weak self] session, event in
            self?.handle(event: event, session: session)
        }
        watcher.customAliases = customAliasStore.aliases
        watcher.startHookServer()
        watcher.start()

        // 設定画面（@AppStorage経由）からサウンド設定が変わった場合にも
        // ノッチのアイコンを追従させる。ノッチのボタン経由の変更は toggleMute() が
        // 直接 isMuted を更新するため、ここでの再代入は実質的な変化がなければ無視される。
        soundDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let current = !SoundAlerts.isEnabled
            if self.isMuted != current { self.isMuted = current }
        }

        // 初回起動時だけ、案内をノッチへ自動で出す。
        // メニューバー・Dockに何も置かない設計のため、フック連携や権限といった
        // 重要な設定に自分から気づいてもらう手段がノッチの外に無い。
        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            setMode(.onboarding)
        }
    }

    // MARK: - グローバルショートカット (設計書 4.3)

    /// 割り当てられた操作を実行する。
    /// 回答系は、回答待ちのセッションが無ければ何もしない（押し間違いで誤送信しないため）。
    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleInput:
            toggleInput()
        case .showSessions:
            showSessions()
        case .showActivity:
            showActivity()
        case .jumpToTerminal:
            jumpToTerminal()
        case .approveChoice:
            respondToPendingChoice(affirmative: true)
        case .denyChoice:
            respondToPendingChoice(affirmative: false)
        case .toggleMute:
            toggleMute()
        }
    }

    /// ショートカットから「はい／いいえ」で答える。
    /// ノッチを開いていなくても、回答待ちのセッションがあればそれを対象にする。
    private func respondToPendingChoice(affirmative: Bool) {
        let target = choiceSession ?? watcher.sessionAwaitingResponse
        guard let session = target, let choice = session.pendingChoice else { return }
        guard let option = affirmative ? choice.affirmativeOption : choice.negativeOption else {
            // はい／いいえが揃っていない問いは、選択肢を見せて選んでもらう
            showChoice(for: session)
            return
        }
        if choiceSession !== session { choiceSession = session }
        respond(with: option)
    }

    // MARK: - 初回起動の案内

    /// 次のステップへ進む
    func advanceOnboarding() {
        guard let next = OnboardingStep(rawValue: onboardingStep.rawValue + 1) else {
            finishOnboarding()
            return
        }
        onboardingStep = next
    }

    /// 案内をスキップして終える（後からいつでも「セットアップ」タブで同じ操作ができる）
    func skipOnboarding() {
        finishOnboarding()
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        onboardingStep = .welcome
        if mode == .onboarding { collapse() }
    }

    /// フック連携をワンクリックで有効化する（案内内の「有効にする」ボタンから呼ぶ）。
    /// 既存の「統合」タブと同じ HookInstaller を使うため、動作・安全性は同一。
    func enableHookFromOnboarding(_ target: HookTarget) {
        do {
            try HookInstaller.install(target)
            onboardingHookMessage[target] = "登録しました。実行中の\(target.displayName)は再起動すると反映されます。"
        } catch {
            onboardingHookMessage[target] = "登録に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - 状態遷移イベント (設計書 4.1 / 4.2)

    private func handle(event: DetectorEvent, session: MonitoredSession) {
        switch event {
        case .becameCompleted(let preview):
            NotificationManager.shared.invalidateChoice(for: session.info)
            activity.record(kind: .completed, session: session.info, preview: preview)
            SoundAlerts.shared.play(for: .completed, session: session.info)
            NotificationManager.shared.notify(session: session.info, state: .completed, preview: preview)
            if AlertGate.allowsAutoExpand(.completed, session: session.info) {
                showNotification(for: session)
            }
        case .becameError(let preview):
            NotificationManager.shared.invalidateChoice(for: session.info)
            activity.record(kind: .error, session: session.info, preview: preview)
            SoundAlerts.shared.play(for: .error, session: session.info)
            NotificationManager.shared.notify(session: session.info, state: .error, preview: preview)
            if AlertGate.allowsAutoExpand(.error, session: session.info) {
                showNotification(for: session)
            }
        case .becameAwaitingChoice(let choice):
            let event: NotificationEvent = choice.kind == .approval ? .approval : .question
            activity.record(
                kind: choice.kind == .approval ? .approval : .question,
                session: session.info,
                preview: [choice.title]
            )
            SoundAlerts.shared.play(for: session.state, session: session.info)
            NotificationManager.shared.notifyChoice(session: session.info, choice: choice)
            // ミュート中でも、回答しないとCLIが止まる問いは黙って捨てない。
            // ノッチを自動で開かないだけで、一覧には回答待ちとして残り続ける。
            if AlertGate.allowsAutoExpand(event, session: session.info) {
                showChoice(for: session)
            }
        case .choiceResolved:
            NotificationManager.shared.invalidateChoice(for: session.info)
            dismissedChoices[session.info.tty] = nil
            // ターミナル側で回答された場合はノッチを畳む
            if choiceSession === session { collapse() }
        case .becameThinking, .becameIdle:
            NotificationManager.shared.invalidateChoice(for: session.info)
        case .none:
            break
        }
    }

    /// 応答完了時にノッチを下方向へ展開し、数秒後に自動で折りたたむ (設計書 4.2)
    func showNotification(for session: MonitoredSession) {
        notificationPresentationTask?.cancel()
        notificationPresentationTask = Task { [weak self] in
            guard let self else { return }
            if NotchPreferences.smartNotificationSuppression,
               await TerminalActivator.isSessionFrontmost(session.info) {
                return
            }
            guard !Task.isCancelled else { return }
            self.presentNotification(for: session)
        }
    }

    private func presentNotification(for session: MonitoredSession) {
        // 非同期の前面タブ判定中に入力や承認が開いた場合、それを通知で上書きしない。
        guard mode != .input, mode != .choice else { return }
        notificationSession = session
        setMode(.notification)

        collapseTask?.cancel()
        let displaySeconds = max(NotchPreferences.notificationDisplayDuration, 1.0)
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(displaySeconds))
            // ホバー中は畳まない
            while let self, self.isHovering, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.mode == .notification else { return }
            self.collapse()
        }
    }

    // MARK: - 承認/質問モード (Approve / Ask)

    /// 回答待ちのセッションをノッチへ展開する。
    /// 通知の自動折りたたみは行わない（ユーザーが答えるまで消さない）。
    func showChoice(for session: MonitoredSession) {
        // 入力中は割り込まない。閉じたときに collapse() が改めて拾う。
        guard mode != .input else { return }
        notificationPresentationTask?.cancel()
        collapseTask?.cancel()
        lastChoiceError = nil
        notificationSession = nil
        choiceSession = session
        setMode(.choice)
        // 既に承認モードでも選択肢の数で高さが変わるため、必ずフレームを取り直す
        panelController?.modeChanged()
        takeChoiceFocusIfAppropriate(for: session)

        // 既定では自動で閉じない（回答するまで表示し続ける）。設定で秒数が
        // 指定されている場合のみ、その時間が経過し、かつホバー中でなければ畳む。
        // (実機で確認: 無回答のまま勝手に閉じるのはバグとして修正済みだが、
        // 自動で閉じたい人向けに設定でだけ選べるようにする)
        let autoCloseSeconds = NotchPreferences.choiceAutoCloseInterval
        guard autoCloseSeconds > 0 else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(autoCloseSeconds))
            while let self, self.isHovering, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled,
                  self.mode == .choice, self.choiceSession === session
            else { return }
            // collapse() だけだと、まだ未回答という理由で resumePendingChoiceIfNeeded() が
            // 即座に再展開してしまう。dismissChoice() 経由にして「閉じた」記録を残し、
            // 同じ問いを再展開しないようにする（Escキーで閉じた場合と同じ扱い）。
            self.dismissChoice()
        }
    }

    /// 選択肢が出たときにキーボードフォーカスを取るか判断する。
    ///
    /// 無条件に `NSApp.activate()` すると、ユーザーが他アプリで文章を書いている最中でも
    /// 打鍵を横取りし、数字キーが意図しない回答として送信されてしまう。
    /// - 設定で無効にされていれば取らない
    /// - 対象セッションのターミナルが既に前面なら、そちらで直接答えられるので取らない
    private func takeChoiceFocusIfAppropriate(for session: MonitoredSession) {
        guard NotchPreferences.focusChoiceOnAppear else { return }
        Task { [weak self] in
            guard await !TerminalActivator.isSessionFrontmost(session.info) else { return }
            guard let self, self.mode == .choice, self.choiceSession === session else { return }
            self.panelController?.focusInput()
        }
    }

    /// 選択肢へ回答する（ノッチのボタン／数字キーから呼ばれる）
    func respond(with option: ChoiceOption) {
        respond(with: [option])
    }

    /// 複数選択の回答をまとめて送る（チェックした項目と決定ボタンから呼ばれる）
    func respond(with options: [ChoiceOption]) {
        guard let session = choiceSession, !isSendingChoice, !options.isEmpty else { return }
        lastChoiceError = nil
        isSendingChoice = true
        Task {
            defer { isSendingChoice = false }
            do {
                try await watcher.respond(with: options, in: session)
                // 同じ呼び出しに問いが残っていれば、畳まずに次の問いを待つ
                let hasMoreQuestions = !session.questionQueue.isEmpty
                // 送信できたことを一瞬見せてから畳む（いきなり一覧へ飛ばさない）
                choiceSentLabel = options.map(\.label).joined(separator: "、")
                try? await Task.sleep(for: .milliseconds(700))
                choiceSentLabel = nil
                if !hasMoreQuestions { collapse() }
            } catch {
                // 失敗は選択肢を出したまま理由を見せる（畳まない）
                lastChoiceError = error.localizedDescription
            }
        }
    }

    /// 回答せずにノッチだけ閉じる（CLIへは何も送らない）
    func dismissChoice() {
        rememberDismissal()
        collapse()
    }

    /// 閉じた問い合わせを記録し、同じ内容で再展開しないようにする
    private func rememberDismissal() {
        guard let session = choiceSession, let choice = session.pendingChoice else { return }
        dismissedChoices[session.info.tty] = choice
    }

    /// 折りたたみ後、まだ回答されていない問い合わせが残っていれば改めて展開する
    private func resumePendingChoiceIfNeeded() {
        guard mode == .compact else { return }
        guard let session = watcher.sessionAwaitingResponse,
              let choice = session.pendingChoice,
              dismissedChoices[session.info.tty] != choice
        else { return }
        showChoice(for: session)
    }

    // MARK: - 入力モード (設計書 4.3)

    func toggleInput() {
        if mode == .input {
            collapse()
        } else {
            expandInput()
        }
    }

    func expandInput() {
        notificationPresentationTask?.cancel()
        collapseTask?.cancel()
        lastSendError = nil
        setMode(.input)
        panelController?.focusInput()
    }

    /// 入力内容を保持したまま、送信先を選べるセッション一覧へ戻る。
    func showSessions() {
        notificationPresentationTask?.cancel()
        collapseTask?.cancel()
        // 終了済みセッションのミュート記録を捨てる。
        // ttyは使い回されるため、残しておくと無関係なセッションが黙ってしまう。
        sessionMutes.prune(livingSessions: watcher.sessions.map(\.info))
        setMode(.sessions)
        panelController?.resignInput()
    }

    func showActivity() {
        notificationPresentationTask?.cancel()
        collapseTask?.cancel()
        activity.markAllRead()
        setMode(.activity)
        panelController?.resignInput()
    }

    func collapse() {
        collapseTask?.cancel()
        notificationSession = nil
        choiceSession = nil
        setMode(.compact)
        panelController?.resignInput()
        resumePendingChoiceIfNeeded()
    }

    func sendPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let session = watcher.activeSession else {
            lastSendError = "AI CLI が見つかりません。ターミナルで claude / codex / agy を起動してください。"
            return
        }
        let submittedDraftKey = promptDraftKey
        // tmuxが無くてもキー入力の合成で送れるため、そちらの可否も見る
        guard session.info.tmuxTarget != nil || KeystrokeSender.isTrusted else {
            lastSendError = KeystrokeError.accessibilityNotTrusted.localizedDescription
            return
        }
        lastSendError = nil
        Task {
            do {
                try await watcher.sendPrompt(text, to: session)
                SoundAlerts.shared.play(.promptSent)
                snippets.recordHistory(text)
                // 送信中にPickerが切り替わっても、送信したセッションの下書きだけを消す。
                promptDrafts.setText("", for: submittedDraftKey)
                collapse()
            } catch {
                lastSendError = error.localizedDescription
            }
        }
    }

    private var promptDraftKey: String {
        guard let session = watcher.activeSession else { return "no-session" }
        return "\(session.info.pid):\(session.info.tty)"
    }

    func insertSnippet(_ snippet: Snippet) {
        if inputText.isEmpty {
            inputText = snippet.body
        } else {
            inputText += " " + snippet.body
        }
    }

    // MARK: - クリックでターミナルへ (設計書 4.2 / 6.4、追補: Jump)

    /// 一覧から選んだセッションを送信先にして、プロンプト入力欄を開く
    func promptSession(_ session: MonitoredSession) {
        watcher.chooseActiveSession(session.info.tty)
        expandInput()
    }

    /// 一覧から選んだセッションのタブへ移動する
    func jump(to session: MonitoredSession) {
        watcher.chooseActiveSession(session.info.tty)
        watcher.acknowledge(session)
        collapse()
        Task { await TerminalActivator.jump(to: session.info) }
    }

    func jump(to entry: ActivityEntry) {
        activity.markRead(entry.id)
        guard let session = watcher.sessions.first(where: {
            $0.info.tty == entry.sessionTTY && $0.info.pid == entry.sessionPID
        }) else { return }
        jump(to: session)
    }

    func hasLiveSession(for entry: ActivityEntry) -> Bool {
        watcher.sessions.contains {
            $0.info.tty == entry.sessionTTY && $0.info.pid == entry.sessionPID
        }
    }

    /// 対象セッションが動いているターミナルのタブへ移動する
    func jumpToTerminal() {
        // 回答待ちのままターミナルへ移る場合は、戻ってきた直後に再展開しないよう記録しておく
        if mode == .choice { rememberDismissal() }

        let target = choiceSession ?? notificationSession ?? watcher.activeSession
        if let target {
            watcher.activeSessionName = target.info.tty
            watcher.acknowledge(target)
        }
        if mode == .notification || mode == .choice { collapse() }

        Task {
            if let target {
                await TerminalActivator.jump(to: target.info)
            } else {
                TerminalActivator.activate()
            }
        }
    }

    // MARK: - 表示先ディスプレイ (追補)

    /// 表示先の設定が変わったときにノッチを配置し直す
    func reloadDisplayPlacement() {
        panelController?.relayout()
    }

    /// 設定画面で表示関連の値が変わったとき、現在のパネルへ即時反映する。
    func preferencesChanged() {
        hoverTask?.cancel()
        if !NotchPreferences.hoverExpansionEnabled {
            isHovering = false
        } else if isPointerInside {
            hoverChanged(to: true)
        }
        panelController?.preferencesChanged()
    }

    // MARK: - サウンドの消音

    func toggleMute() {
        isMuted.toggle()
        UserDefaults.standard.set(!isMuted, forKey: "soundEnabled")
    }

    // MARK: - カスタムエイリアス

    /// 追加後、watcherの参照済みリストも同期する（次回ポーリングから反映）。
    @discardableResult
    func addCustomAlias(name: String, baseProfileID: String) -> Bool {
        let added = customAliasStore.add(name: name, baseProfileID: baseProfileID)
        if added { watcher.customAliases = customAliasStore.aliases }
        return added
    }

    func removeCustomAlias(_ alias: CustomAlias) {
        customAliasStore.remove(alias)
        watcher.customAliases = customAliasStore.aliases
    }

    /// ビューが実際に描画した高さを伝える。
    /// パネルを内容ぴったりにして、透明な余白がクリックを奪わないようにする。
    func reportContentHeight(_ height: CGFloat, for mode: NotchMode) {
        panelController?.adjustHeight(to: height, for: mode)
    }

    // MARK: - ホバー展開・収納

    /// 展開アニメーションでビューの境界が入れ替わる瞬間にも mouseExited が届く。
    /// 本当に外へ出た場合だけ畳むための短い猶予。
    private static let hoverExitGrace: Duration = .milliseconds(180)

    func hoverChanged(to hovering: Bool) {
        isPointerInside = hovering
        hoverTask?.cancel()

        if hovering {
            guard NotchPreferences.hoverExpansionEnabled else {
                if isHovering { isHovering = false }
                return
            }
            // 展開済みなら、一時的な exit → enter で再アニメーションさせない。
            guard !isHovering else { return }
            let delay = max(NotchPreferences.hoverDelay, 0)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.isPointerInside else { return }
                self.isHovering = true
            }
        } else if NotchPreferences.collapseOnMouseExit {
            // SwiftUIは表示モードの切替中にも一瞬exitを通知することがある。
            // 少し待ち、画面座標でも本当に外へ出た場合だけ収納する。
            guard isHovering else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hoverExitGrace)
                guard let self, !Task.isCancelled else { return }

                // 拡大アニメーション中のビュー差し替えでonHoverだけがfalseに
                // なった場合は、実際にマウスが外へ出るまで監視を続ける。
                while !self.isPointerInside,
                      self.panelController?.containsCurrentMouseLocation() == true,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                guard !Task.isCancelled,
                      !self.isPointerInside,
                      self.panelController?.containsCurrentMouseLocation() != true
                else { return }
                self.isHovering = false
            }
        }
    }

    /// 外側クリックまたは一覧の閉じるボタンから、ホバー展開を明示的に閉じる。
    func dismissExpandedPanel() {
        hoverTask?.cancel()
        isHovering = false
        if mode == .notification || mode == .sessions || mode == .activity { collapse() }
    }

    /// パネル外のクリックで閉じてよい、自動表示中のモードか。
    var canCloseOnOutsideClick: Bool {
        NotchPreferences.closeOnOutsideClick
            && (mode == .notification || displayMode == .sessions || mode == .activity)
    }

    // MARK: - 内部

    private func setMode(_ newMode: NotchMode) {
        guard mode != newMode else { return }
        mode = newMode
        panelController?.modeChanged()
    }

    private func hoverChanged() {
        panelController?.modeChanged()
    }
}
