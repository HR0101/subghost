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
}

@Observable
final class AppCoordinator {

    static let shared = AppCoordinator()

    let watcher = GhosttySessionWatcher()
    let snippets = SnippetStore()
    let hotkey = HotkeyManager()
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    private(set) var mode: NotchMode = .compact
    /// パネルコントローラが算出したノッチ寸法（ビューが形状描画に使う）
    var notchMetrics: NotchMetrics?
    var isHovering = false {
        didSet { hoverChanged() }
    }
    /// 通知展開で表示中のセッション
    private(set) var notificationSession: MonitoredSession?
    var inputText = ""
    var lastSendError: String?

    /// 実際に画面へ出す表示モード（ホバー時は軽く展開してプレビュー: 設計書 6.4）
    var displayMode: NotchMode {
        if mode == .input { return .input }
        if mode == .notification { return .notification }
        if isHovering, watcher.activeSession != nil { return .notification }
        return .compact
    }

    // MARK: - 起動

    func start() {
        NotificationManager.shared.setup()

        watcher.onEvent = { [weak self] session, event in
            self?.handle(event: event, session: session)
        }
        watcher.start()

        hotkey.onHotkey = { [weak self] in
            self?.toggleInput()
        }
        hotkey.register()

        panelController = NotchPanelController(coordinator: self)
        panelController?.show()
    }

    // MARK: - 状態遷移イベント (設計書 4.1 / 4.2)

    private func handle(event: DetectorEvent, session: MonitoredSession) {
        switch event {
        case .becameCompleted(let preview):
            NotificationManager.shared.notify(session: session.info, state: .completed, preview: preview)
            showNotification(for: session)
        case .becameError(let preview):
            NotificationManager.shared.notify(session: session.info, state: .error, preview: preview)
            showNotification(for: session)
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
        setMode(.compact)
        panelController?.resignInput()
    }

    func sendPrompt() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let session = watcher.activeSession else {
            lastSendError = "送信先の ai-* セッションがありません。Ghosttyで tmux new-session -A -s ai-claude claude を実行してください。"
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

    // MARK: - クリックでGhosttyへ (設計書 4.2 / 6.4)

    func openGhostty() {
        if let session = notificationSession ?? watcher.activeSession {
            watcher.acknowledge(session)
        }
        GhosttyActivator.activate()
        if mode == .notification { collapse() }
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
