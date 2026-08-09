//
//  AppCoordinator.swift
//  Subghost
//
//  設計書 3.3: NotchViewModel（UI状態の保持・更新）＋各コンポーネントの結線
//
//  UI状態を一手に持つシングルトン。監視・通知・音・ホットキー・パネルを
//  ここで結線し、SwiftUI 側は本クラスの値を読むだけにする。
//
//  表示の要点:
//  要求されたモードは NotchMode だが、実際に描画されるのは displayMode。
//  オンボーディング > 通知 > セッション一覧 > 活動 > ホバー > コンパクト
//  の優先順位を適用する。Subghostは監視専用で、CLIへの入力は行わない。
//

import AppKit
import Observation

/// ノッチの表示モード (設計書 6.2)
enum NotchMode: Equatable {
    case compact        // 状態アイコンのみ
    case notification   // 応答チラ見せ
    case sessions       // 複数CLIの一覧
    case activity       // 完了・エラーの履歴
    case onboarding      // 初回起動時の案内
    case sleep          // まもなくスリープする案内（取り消しの機会）
}

/// 初回起動時の案内（ようこそ→フック連携→権限確認→完了）の各段階
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case hooks
    case permissions
    case done
}

@Observable
final class AppCoordinator {

    static let shared = AppCoordinator()

    let watcher = SessionWatcher()
    let activity = ActivityStore()
    let hotkey = HotkeyManager()
    let customAliasStore = CustomAliasStore()
    /// セッション個別のミュート（実行中のみ保持。AlertGate から参照される）
    let sessionMutes = SessionMuteStore()
    /// タスク完了後のスリープ予約（実行中のみ保持。詳細は SleepScheduler 参照）
    let sleepScheduler = SleepScheduler()
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var notificationPresentationTask: Task<Void, Never>?
    private(set) var mode: NotchMode = .compact
    /// パネルコントローラが算出したノッチ寸法（ビューが形状描画に使う）
    var notchMetrics: NotchMetrics?
    private(set) var isHovering = false {
        didSet { hoverChanged() }
    }
    private var isPointerInside = false
    /// 通知展開で表示中のセッション
    private(set) var notificationSession: MonitoredSession?
    /// 消音中か（一覧のスピーカーアイコンと連動）。
    /// SoundAlerts.isEnabled はUserDefaultsを都度読むだけの static var で、@Observable の
    /// 変更検知の対象にならない（他クラスの静的プロパティのため）。ここにストアドプロパティとして
    /// キャッシュし、変更のたびに明示的に更新することでボタンの見た目を追従させる。
    /// (実機で確認した不具合: ボタンを押しても消音自体は効くが、アイコン表示が変わらなかった)
    private(set) var isMuted: Bool = !SoundAlerts.isEnabled
    @ObservationIgnored private var soundDefaultsObserver: NSObjectProtocol?

    // MARK: - 初回起動の案内

    @ObservationIgnored private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    @ObservationIgnored private static let migrationVersionKey = "migrationVersion"
    @ObservationIgnored private static let currentMigrationVersion = 2
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// フック有効化ボタンを押した結果（成功メッセージ／エラー）。ステップごとに保持する。
    var onboardingHookMessage: [HookTarget: String] = [:]
    private(set) var onboardingNotificationMessage: String?

    /// 実際に画面へ出す表示モード（ホバー時は軽く展開してプレビュー: 設計書 6.4）
    var displayMode: NotchMode {
        // まもなくスリープする案内は、取り消す機会そのもの。案内や通知に埋もれさせない。
        if mode == .sleep { return .sleep }
        // 通知や一覧に割り込まれて初回案内が埋もれないようにする。
        if mode == .onboarding { return .onboarding }
        if mode == .notification { return .notification }
        // 明示的に開いた一覧は、ホバーが外れても表示を維持する。
        if mode == .sessions { return .sessions }
        if mode == .activity { return .activity }
        // ホバー中は常に一覧を出す。
        // ホバーからも素早くセッション一覧へ入れる。
        if isHovering { return .sessions }
        return .compact
    }

    // MARK: - 起動

    func start() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        if isUITesting {
            UserDefaults.standard.set(false, forKey: Self.hasCompletedOnboardingKey)
            UserDefaults.standard.set(false, forKey: "soundEnabled")
        } else {
            migrateRemovedFeaturesIfNeeded()
        }
        if AppearancePreferences.hidePreviewText { activity.redactSummaries() }
        NotificationManager.shared.setup()
        SoundAlerts.shared.play(.appLaunched)

        // 監視より先にパネルを用意し、初回イベントから表示できるようにする。
        panelController = NotchPanelController(coordinator: self)
        panelController?.show()

        if !isUITesting {
            hotkey.onAction = { [weak self] action in
                self?.perform(action)
            }
            hotkey.register()
        }

        watcher.onEvent = { [weak self] session, event in
            self?.handle(event: event, session: session)
        }
        wireSleepScheduler()
        watcher.customAliases = customAliasStore.aliases
        if !isUITesting {
            watcher.startHookServer()
            watcher.start()
        }

        // 設定画面（@AppStorage経由）からサウンド設定が変わった場合にも
        // ノッチのアイコンを追従させる。ノッチのボタン経由の変更は toggleMute() が
        // 直接 isMuted を更新するため、ここでの再代入は実質的な変化がなければ無視される。
        soundDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = !SoundAlerts.isEnabled
                if self.isMuted != current { self.isMuted = current }
            }
        }

        // 初回起動時だけ、案内をノッチへ自動で出す。
        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            setMode(.onboarding)
        }
    }

    /// 旧版がユーザー環境へ追加した自動tmux起動と旧フックを一度だけ片付ける。
    private func migrateRemovedFeaturesIfNeeded() {
        let defaults = UserDefaults.standard
        let version = defaults.integer(forKey: Self.migrationVersionKey)
        guard version < Self.currentMigrationVersion else { return }
        var succeeded = true

        if version < 1 {
            do {
                if ShellIntegration.isInstalled() { try ShellIntegration.uninstall() }
            } catch {
                succeeded = false
                NSLog("Subghost: 旧tmux自動起動設定を解除できませんでした: \(error.localizedDescription)")
            }
        }

        if version < 2 {
            do {
                for target in HookTarget.allCases where HookInstaller.isInstalled(target) {
                    try HookInstaller.install(target)
                }
            } catch {
                succeeded = false
                NSLog("Subghost: 監視専用フックへ移行できませんでした: \(error.localizedDescription)")
            }
        }
        if succeeded { defaults.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey) }
    }

    // MARK: - タスク完了後のスリープ (追補)

    /// スケジューラへ、現在のセッションと表示状態を渡す口を用意する。
    ///
    /// スケジューラ自身は監視も画面も知らない。判断に要る材料をここで注入し、
    /// 「寝てよいか」の判断とその実行だけを向こうに任せる。
    private func wireSleepScheduler() {
        sleepScheduler.sessionsProvider = { [weak self] in
            self?.watcher.sessions.map {
                SleepSessionSnapshot(info: $0.info, state: $0.state)
            } ?? []
        }
        sleepScheduler.onCountdownStarted = { [weak self] in self?.presentSleepCountdown() }
        sleepScheduler.onCountdownFinished = { [weak self] in
            guard let self, self.mode == .sleep else { return }
            self.collapse()
        }
    }

    /// このセッションのタスクが終わったらスリープする予約を入り切りする。
    /// 複数を予約した場合は、そのすべてが終わってからスリープする。
    func toggleSleepReservation(for session: MonitoredSession) {
        let info = session.info
        let target = SleepTarget.session(tty: info.tty, pid: info.pid)
        if sleepScheduler.isReservedSession(tty: info.tty, pid: info.pid) {
            sleepScheduler.cancelReservation(target)
            return
        }
        sleepScheduler.reserve(
            target,
            label: "\(info.profile.displayName)（\(info.displayName)）"
        )
    }

    /// このCLIのタスクが終わったらスリープする予約を入り切りする（設定画面から）
    func toggleSleepReservation(forAgent profile: CLIProfile) {
        let target = SleepTarget.agent(profileID: profile.id)
        if sleepScheduler.isReservedAgent(profileID: profile.id) {
            sleepScheduler.cancelReservation(target)
            return
        }
        sleepScheduler.reserve(target, label: profile.displayName)
    }

    /// 待ち時間を取り消す（予約は残るので、次に完了したらまた待ち時間へ入る）
    func cancelSleepCountdown() {
        sleepScheduler.cancelCountdown(message: "スリープを取り消しました。予約は残しています。")
        if mode == .sleep { collapse() }
    }

    /// 予約を1件だけ解除する
    func cancelSleepReservation(_ target: SleepTarget) {
        sleepScheduler.cancelReservation(target)
        if mode == .sleep, !sleepScheduler.isReserved { collapse() }
    }

    /// 予約をすべて解除する
    func cancelAllSleepReservations() {
        sleepScheduler.cancelAllReservations()
        if mode == .sleep { collapse() }
    }

    /// 待たずに今すぐ寝る
    func sleepImmediately() {
        sleepScheduler.sleepImmediately()
    }

    /// まもなくスリープすることをノッチへ出す。
    ///
    /// 他の展開表示より優先して、取り消せるカウントダウンを表示する。
    private func presentSleepCountdown() {
        notificationPresentationTask?.cancel()
        collapseTask?.cancel()
        notificationSession = nil
        setMode(.sleep)
        panelController?.modeChanged()
    }

    // MARK: - グローバルショートカット (設計書 4.3)

    /// 割り当てられた操作を実行する。
    func perform(_ action: HotkeyAction) {
        switch action {
        case .showSessions:
            displayMode == .sessions ? collapse() : showSessions()
        case .showActivity:
            showActivity()
        case .jumpToTerminal:
            jumpToTerminal()
        case .toggleMute:
            toggleMute()
        }
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

    func requestNotificationPermission() {
        NotificationManager.shared.requestAuthorization { [weak self] allowed in
            self?.onboardingNotificationMessage = allowed
                ? "通知を有効にしました。"
                : "通知は許可されていません。後からシステム設定で変更できます。"
        }
    }

    // MARK: - 状態遷移イベント (設計書 4.1 / 4.2)

    private func handle(event: DetectorEvent, session: MonitoredSession) {
        switch event {
        case .becameCompleted(let preview):
            activity.record(kind: .completed, session: session.info, preview: preview)
            SoundAlerts.shared.play(for: .completed, session: session.info)
            NotificationManager.shared.notify(session: session.info, state: .completed, preview: preview)
            // スリープ予約より先に通知・音を出す。寝る前に「何が終わったか」は必ず残す。
            sleepScheduler.noteFinished(SleepSessionSnapshot(info: session.info, state: .completed))
            if AlertGate.allowsAutoExpand(.completed, session: session.info) {
                showNotification(for: session)
            }
        case .becameError(let preview):
            activity.record(kind: .error, session: session.info, preview: preview)
            SoundAlerts.shared.play(for: .error, session: session.info)
            NotificationManager.shared.notify(session: session.info, state: .error, preview: preview)
            sleepScheduler.noteFinished(SleepSessionSnapshot(info: session.info, state: .error))
            if AlertGate.allowsAutoExpand(.error, session: session.info) {
                showNotification(for: session)
            }
        case .becameThinking, .becameIdle, .none:
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
        // オンボーディング中は通常の完了/エラー通知でセットアップ画面を
        // 上書きしない（実機レビューで指摘: 上書きされた後は自動で戻らなかった）。
        guard mode != .onboarding else { return }
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

    /// 監視中のセッション一覧を表示する。
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
        setMode(.compact)
        panelController?.resignInput()
    }

    // MARK: - クリックでターミナルへ (設計書 4.2 / 6.4、追補: Jump)

    // MARK: - 一覧の片付け

    /// 一覧から外す（CLIプロセスはそのまま動かし続ける）
    func hideSession(_ session: MonitoredSession) {
        watcher.hide(session)
    }

    /// CLIごと終了させる。取り消せない操作なので必ず確認を取る。
    ///
    /// ノッチのパネルは statusBar より上にいるため、パネル内にシートを出すと
    /// 隠れてしまう。アプリモーダルの NSAlert で確実に前へ出す。
    func confirmTerminate(_ session: MonitoredSession) {
        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "\(session.info.displayName) の \(session.info.profile.displayName) を終了しますか？"
        alert.informativeText =
            "作業中だった場合、途中の内容は失われることがあります。"
            + "終了させず、一覧から隠すだけにもできます。"
        alert.addButton(withTitle: "終了する")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "隠すだけ")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            watcher.terminate(session)
        case .alertThirdButtonReturn:
            watcher.hide(session)
        default:
            break
        }
    }

    /// 一覧から選んだセッションのタブへ移動する
    func jump(to session: MonitoredSession) {
        watcher.chooseActiveSession(session.info.id)
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
        let target = notificationSession ?? watcher.activeSession
        if let target {
            watcher.activeSessionName = target.info.id
            watcher.acknowledge(target)
        }
        if mode == .notification { collapse() }

        Task {
            if let target {
                await TerminalActivator.jump(to: target.info)
            } else {
                TerminalActivator.activate()
            }
        }
    }

    // MARK: - 設定ウインドウ

    /// 設定ウインドウを開く。
    ///
    /// 表示そのものは `SettingsWindowController` が持つ（SwiftUIの Settings シーンに
    /// 依存しない理由はそちらのコメントを参照）。
    func openSettings() {
        // 先に畳む。resignInput() が NSApp.deactivate() を呼ぶため、
        // 順番を逆にすると show() の中の activate() が打ち消される。
        collapse()
        SettingsWindowController.shared.show()
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
        if added {
            watcher.customAliases = customAliasStore.aliases
        }
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
