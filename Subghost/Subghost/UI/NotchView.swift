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
    @FocusState private var choiceFocused: Bool
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
                case .choice: choiceContent
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
            historyIndex = newMode == .input ? nil : historyIndex
            inputFocused = false
            choiceFocused = false
            // パネルがキーウインドウになるのを待ってからフォーカスを与える
            guard newMode == .input || newMode == .choice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if newMode == .input {
                    inputFocused = true
                } else {
                    choiceFocused = true
                }
            }
        }
    }

    private func contentWidth(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .compact: return notchWidth + NotchLayout.sideWidth * 2
        case .notification: return max(notchWidth + 220, 560)
        case .input: return max(notchWidth + 280, 640)
        case .choice: return max(notchWidth + 320, 680)
        }
    }

    // MARK: - コンパクト：状態アイコンのみ (設計書 4.1 / 6.2)

    private var compactContent: some View {
        HStack(spacing: 0) {
            // 左余白：アクティブセッションの状態
            HStack {
                StateDot(
                    state: coordinator.watcher.activeSession?.state ?? .idle,
                    pulsing: coordinator.watcher.activeSession?.state.shouldPulse ?? false
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
                        StateDot(state: session.state, pulsing: session.state.shouldPulse, size: 6)
                    }
                }
            }
            .frame(width: NotchLayout.sideWidth)
        }
        .frame(height: topInset)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.jumpToTerminal() }
    }

    // MARK: - 展開（通知）：応答チラ見せ (設計書 4.2 / 6.2)

    private var notificationContent: some View {
        let session = coordinator.notificationSession ?? coordinator.watcher.activeSession

        return VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)   // ノッチ本体を避ける

            HStack(spacing: 8) {
                StateDot(state: session?.state ?? .idle, pulsing: session?.state.shouldPulse ?? false)
                Text(session?.info.profile.displayName ?? "セッションなし")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let name = session?.info.displayName {
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
            } else if let session, !session.info.isMonitorable {
                Text("tmuxの外で動いているため状態を読めません。クリックでタブへ移動します")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Text(session == nil
                     ? "AI CLI が見つかりません"
                     : "応答待ち…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            HStack {
                Text("クリックで該当タブへ移動")
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
        .onTapGesture { coordinator.jumpToTerminal() }
    }

    // MARK: - 展開（承認/質問）：Approve / Ask

    private var choiceContent: some View {
        let session = coordinator.choiceSession
        let choice = coordinator.pendingChoice

        return VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)   // ノッチ本体を避ける

            HStack(spacing: 8) {
                Image(systemName: choice?.kind == .question
                      ? "questionmark.circle.fill" : "hand.raised.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(choice?.kind == .question ? Color.yellow : Color.orange)
                Text(session?.info.profile.displayName ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let name = session?.info.displayName {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(choice?.kind.displayName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let choice {
                // 問いかけの文脈（差分の要約など）
                if !choice.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(choice.detail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(choice.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 5) {
                    ForEach(choice.options) { option in
                        ChoiceOptionRow(option: option, isDefault: option == choice.options.first) {
                            coordinator.respond(with: option)
                        }
                    }
                }
            } else {
                Text("回答待ちの問い合わせはありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if let error = coordinator.lastChoiceError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                HStack {
                    Text("数字キーで回答 / ⏎ で先頭を選択")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Button("ターミナルで開く") { coordinator.jumpToTerminal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Esc で閉じる")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .focusable()
        .focused($choiceFocused)
        .focusEffectDisabled()
        .onKeyPress { press in handleChoiceKey(press) }
        .onExitCommand { coordinator.dismissChoice() }
    }

    /// 数字キー・y/n・Enterで選択肢へ回答する
    private func handleChoiceKey(_ press: KeyPress) -> KeyPress.Result {
        guard let choice = coordinator.pendingChoice else { return .ignored }

        if press.key == .return {
            guard let first = choice.options.first else { return .ignored }
            coordinator.respond(with: first)
            return .handled
        }

        let typed = String(press.characters).lowercased()
        guard let option = choice.options.first(where: { $0.keystroke.lowercased() == typed }) else {
            return .ignored
        }
        coordinator.respond(with: option)
        return .handled
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
                if let active = coordinator.watcher.activeSession {
                    StateDot(state: active.state, pulsing: active.state.shouldPulse, size: 7)
                }
                if coordinator.watcher.sessions.count > 1 {
                    Picker("送信先", selection: activeSessionBinding) {
                        // 送信できないセッションは選択肢に出さない
                        ForEach(coordinator.watcher.sessions.filter(\.info.isMonitorable)) { session in
                            Text("\(session.info.displayName)（\(session.state.displayName)）")
                                .tag(Optional(session.info.tty))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: 220)
                } else {
                    Text(coordinator.watcher.activeSession?.info.displayName ?? "セッションなし")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if coordinator.watcher.sessions.count > 1 {
                    Text("⇥ 送信先切替")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
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
                .onKeyPress(.tab) {
                    guard coordinator.watcher.sessions.count > 1 else { return .ignored }
                    coordinator.watcher.cycleActiveSession()
                    return .handled
                }

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
                Text("AI CLI が見つかりません。ターミナルで claude / codex / antigravity を起動してください")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if coordinator.watcher.activeSession?.info.isMonitorable == false {
                Text(coordinator.watcher.tmuxAvailable
                     ? "このセッションはtmuxの外で動いているため送信できません。tmux内で起動し直してください"
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

// MARK: - 選択肢の1行 (Approve / Ask)

struct ChoiceOptionRow: View {
    let option: ChoiceOption
    /// Enterで選ばれる既定の選択肢か
    let isDefault: Bool
    let action: () -> Void

    @State private var isHovering = false

    /// 「はい」系は緑、「いいえ」系は赤、それ以外は無彩色で示す
    private var tint: Color {
        if option.isAffirmative { return .green }
        if option.isNegative { return .red }
        return .white
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(option.keystroke.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.85)))

                Text(option.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                if isDefault {
                    Text("⏎")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(isHovering ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(isDefault ? 0.5 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 状態ドット (設計書 4.1: グレー/青パルス/緑/赤 ＋ 回答待ちの橙/黄)

struct StateDot: View {
    let state: AIState
    var pulsing = false
    var size: CGFloat = 9

    private var color: Color {
        switch state {
        case .idle: return .gray
        case .thinking: return .blue
        case .awaitingApproval: return .orange
        case .awaitingAnswer: return .yellow
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
