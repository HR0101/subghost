//
//  NotchView.swift
//  Subghost
//
//  設計書 6. UI/UX仕様（コンパクト / 展開(通知) / 展開(入力)）
//

import SwiftUI

struct NotchView: View {
    @Bindable var coordinator: AppCoordinator
    @FocusState private var inputFocused: Bool
    @State private var historyIndex: Int?

    private var metrics: NotchMetrics? { coordinator.notchMetrics }
    private var topInset: CGFloat { metrics?.topInset ?? 34 }
    private var notchWidth: CGFloat { metrics?.notchWidth ?? 190 }

    var body: some View {
        let mode = coordinator.displayMode

        VStack(spacing: 0) {
            Group {
                switch mode {
                case .compact: compactContent
                case .notification: notificationContent
                case .input: inputContent
                }
            }
            .frame(width: contentWidth(for: mode))
            .background {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: 0,
                        bottomLeading: mode == .compact ? 9 : NotchLayout.cornerRadius,
                        bottomTrailing: mode == .compact ? 9 : NotchLayout.cornerRadius,
                        topTrailing: 0
                    ),
                    style: .continuous
                )
                .fill(.black)
                .shadow(color: .black.opacity(mode == .compact ? 0 : 0.45), radius: 10, y: 5)
            }
            .onHover { coordinator.isHovering = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
        .onChange(of: mode) { _, newMode in
            if newMode == .input {
                historyIndex = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    inputFocused = true
                }
            } else {
                inputFocused = false
            }
        }
    }

    private func contentWidth(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .compact: return notchWidth + NotchLayout.sideWidth * 2
        case .notification: return max(notchWidth + 220, 560)
        case .input: return max(notchWidth + 280, 640)
        }
    }

    // MARK: - コンパクト：状態アイコンのみ (設計書 4.1 / 6.2)

    private var compactContent: some View {
        HStack(spacing: 0) {
            // 左余白：アクティブセッションの状態
            HStack {
                StateDot(
                    state: coordinator.watcher.activeSession?.state ?? .idle,
                    pulsing: coordinator.watcher.activeSession?.state == .thinking
                )
            }
            .frame(width: NotchLayout.sideWidth)

            Spacer(minLength: notchWidth)

            // 右余白：全セッションの小ドット
            HStack(spacing: 4) {
                if coordinator.watcher.sessions.isEmpty {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                } else {
                    ForEach(coordinator.watcher.sessions.prefix(4)) { session in
                        StateDot(state: session.state, pulsing: session.state == .thinking, size: 6)
                    }
                }
            }
            .frame(width: NotchLayout.sideWidth)
        }
        .frame(height: topInset)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.openGhostty() }
    }

    // MARK: - 展開（通知）：応答チラ見せ (設計書 4.2 / 6.2)

    private var notificationContent: some View {
        let session = coordinator.notificationSession ?? coordinator.watcher.activeSession

        return VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)   // ノッチ本体を避ける

            HStack(spacing: 8) {
                StateDot(state: session?.state ?? .idle, pulsing: session?.state == .thinking)
                Text(session?.info.profile.displayName ?? "セッションなし")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let name = session?.info.tmuxName {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(session?.state.displayName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let preview = session?.preview, !preview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            } else {
                Text(session == nil
                     ? "tmuxの ai-* セッションが見つかりません"
                     : "応答待ち…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            HStack {
                Text("クリックでGhosttyを開く")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("⌥Space で入力")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.openGhostty() }
    }

    // MARK: - 展開（入力）：クイックプロンプト (設計書 4.3 / 4.4)

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)

            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                // 送信先セッション選択 (設計書 4.3: 複数ある場合はドロップダウン)
                if coordinator.watcher.sessions.count > 1 {
                    Picker("送信先", selection: activeSessionBinding) {
                        ForEach(coordinator.watcher.sessions) { session in
                            Text(session.info.tmuxName).tag(Optional(session.info.tmuxName))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 180)
                } else {
                    Text(coordinator.watcher.activeSession?.info.tmuxName ?? "セッションなし")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text("Esc で閉じる")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            TextField("プロンプトを入力してEnterで送信…", text: $coordinator.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                .focused($inputFocused)
                .onSubmit {
                    historyIndex = nil
                    coordinator.sendPrompt()
                }
                .onExitCommand { coordinator.collapse() }
                .onKeyPress(.upArrow) { historyUp(); return .handled }
                .onKeyPress(.downArrow) { historyDown(); return .handled }

            // スニペットチップ (設計書 4.4)
            if !coordinator.snippets.snippets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(coordinator.snippets.snippets) { snippet in
                            Button {
                                coordinator.insertSnippet(snippet)
                            } label: {
                                Text(snippet.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let error = coordinator.lastSendError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if coordinator.watcher.sessions.isEmpty {
                Text(coordinator.watcher.tmuxAvailable
                     ? "セッション未検出：Ghosttyで aiclaude 等（tmux new-session -A -s ai-claude claude）を実行してください"
                     : "tmuxが見つかりません。設定でパスを指定するかインストールしてください")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// watcherはletプロパティのため@Bindable経由でBindingを作れず、手動で用意する
    private var activeSessionBinding: Binding<String?> {
        Binding(
            get: { coordinator.watcher.activeSessionName },
            set: { coordinator.watcher.activeSessionName = $0 }
        )
    }

    // MARK: - 履歴呼び出し (設計書 4.4: 上矢印キー)

    private func historyUp() {
        let history = coordinator.snippets.history
        guard !history.isEmpty else { return }
        let next = historyIndex.map { min($0 + 1, history.count - 1) } ?? 0
        historyIndex = next
        coordinator.inputText = history[next]
    }

    private func historyDown() {
        guard let index = historyIndex else { return }
        if index <= 0 {
            historyIndex = nil
            coordinator.inputText = ""
        } else {
            historyIndex = index - 1
            coordinator.inputText = coordinator.snippets.history[index - 1]
        }
    }
}

// MARK: - 状態ドット (設計書 4.1: グレー/青パルス/緑/赤)

struct StateDot: View {
    let state: AIState
    var pulsing = false
    var size: CGFloat = 9

    private var color: Color {
        switch state {
        case .idle: return .gray
        case .thinking: return .blue
        case .completed: return .green
        case .error: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .phaseAnimator([1.0, 0.35]) { view, phase in
                view.opacity(pulsing ? phase : 1)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
            .shadow(color: color.opacity(0.7), radius: pulsing ? 4 : 2)
    }
}
