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
}

@Observable
final class AppCoordinator {

    static let shared = AppCoordinator()

    let watcher = SessionWatcher()
    let snippets = SnippetStore()
    let hotkey = HotkeyManager()
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// ユーザーが閉じた問い合わせ（セッション名 → 内容）。同じ内容では再展開しない。
    @ObservationIgnored private var dismissedChoices: [String: PendingChoice] = [:]

    private(set) var mode: NotchMode = .compact
    /// パネルコントローラが算出したノッチ寸法（ビューが形状描画に使う）
    var notchMetrics: NotchMetrics?
    var isHovering = false {
        didSet { hoverChanged() }
    }
    /// 通知展開で表示中のセッション
    private(set) var notificationSession: MonitoredSession?
    /// 承認/質問の回答待ちで表示中のセッション
    private(set) var choiceSession: MonitoredSession?
    var inputText = ""
    var lastSendError: String?
    /// 回答送信に失敗したときのメッセージ
    var lastChoiceError: String?

    /// 実際に画面へ出す表示モード（ホバー時は軽く展開してプレビュー: 設計書 6.4）
    var displayMode: NotchMode {
        if mode == .input { return .input }
        if mode == .choice { return .choice }
        if mode == .notification { return .notification }
        if isHovering, watcher.activeSession != nil { return .notification }
        return .compact
    }

    /// 承認モードで表示中の選択肢
    var pendingChoice: PendingChoice? { choiceSession?.pendingChoice }

    // MARK: - 起動

    func start() {
        NotificationManager.shared.setup()

        // 監視より先にパネルを用意する。
        // 起動直後の1回目のポーリングで承認待ちを見つけた場合、
        // パネルが未生成だとノッチを開けないため。
        panelController = NotchPanelController(coordinator: self)
        panelController?.show()

        hotkey.onHotkey = { [weak self] in
            self?.toggleInput()
        }
        hotkey.register()

        watcher.onEvent = { [weak self] session, event in
            self?.handle(event: event, session: session)
        }
        watcher.startHookServer()
        watcher.start()
    }

    // MARK: - 状態遷移イベント (設計書 4.1 / 4.2)

    private func handle(event: DetectorEvent, session: MonitoredSession) {
        switch event {
        case .becameCompleted(let preview):
            SoundAlerts.shared.play(for: .completed)
            NotificationManager.shared.notify(session: session.info, state: .completed, preview: preview)
            showNotification(for: session)
        case .becameError(let preview):
            SoundAlerts.shared.play(for: .error)
            NotificationManager.shared.notify(session: session.info, state: .error, preview: preview)
            showNotification(for: session)
        case .becameAwaitingChoice(let choice):
            SoundAlerts.shared.play(for: session.state)
            NotificationManager.shared.notifyChoice(session: session.info, choice: choice)
            showChoice(for: session)
        case .choiceResolved:
            dismissedChoices[session.info.tty] = nil
            // ターミナル側で回答された場合はノッチを畳む
            if choiceSession === session { collapse() }
        case .becameThinking, .becameIdle, .none:
            break
        }
    }

    /// 応答完了時にノッチを下方向へ展開し、数秒後に自動で折りたたむ (設計書 4.2)
    func showNotification(for session: MonitoredSession) {
        guard mode != .input else { return }
        notificationSession = session
        setMode(.notification)

        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
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
        collapseTask?.cancel()
        lastChoiceError = nil
        notificationSession = nil
        choiceSession = session
        setMode(.choice)
        // 既に承認モードでも選択肢の数で高さが変わるため、必ずフレームを取り直す
        panelController?.modeChanged()
        panelController?.focusInput()   // 数字キーで回答できるようキーフォーカスを取る
    }

    /// 選択肢へ回答する（ノッチのボタン／数字キーから呼ばれる）
    func respond(with option: ChoiceOption) {
        guard let session = choiceSession else { return }
        lastChoiceError = nil
        Task {
            do {
                try await watcher.respond(with: option, in: session)
                collapse()
            } catch {
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
        collapseTask?.cancel()
        lastSendError = nil
        setMode(.input)
        panelController?.focusInput()
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
            lastSendError = "AI CLI が見つかりません。ターミナルで claude / codex / antigravity を起動してください。"
            return
        }
        guard session.info.isMonitorable else {
            lastSendError = SessionError.notMonitorable.localizedDescription
            return
        }
        lastSendError = nil
        Task {
            do {
                try await watcher.sendPrompt(text, to: session)
                snippets.recordHistory(text)
                inputText = ""
                collapse()
            } catch {
                lastSendError = error.localizedDescription
            }
        }
    }

    func insertSnippet(_ snippet: Snippet) {
        if inputText.isEmpty {
            inputText = snippet.body
        } else {
            inputText += " " + snippet.body
        }
    }

    // MARK: - クリックでターミナルへ (設計書 4.2 / 6.4、追補: Jump)

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
