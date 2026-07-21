//
//  NotchView.swift
//  Subghost
//
//  設計書 6. UI/UX仕様（コンパクト / 展開(通知) / 展開(入力)）
//

import SwiftUI

/// 物理ノッチと展開パネルを、1本の連続したパスとして描画する。
struct NotchSurfaceShape: Shape {
    var progress: CGFloat
    let compactWidth: CGFloat
    let compactHeight: CGFloat
    /// 上端の外側カーブを描画するため、本体の左右に確保した透明余白。
    let canvasShoulderInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let value = min(max(progress, 0), 1)
        // Dynamic Islandらしく、横方向をわずかに先行させてから下へ膨らませる。
        let horizontalProgress = smoothstep(min(value * 1.16, 1))
        let verticalProgress = smoothstep(max((value - 0.06) / 0.94, 0))
        let availableBodyWidth = max(rect.width - canvasShoulderInset * 2, 0)
        let startWidth = min(compactWidth, availableBodyWidth)
        let startHeight = min(compactHeight, rect.height)
        let width = startWidth + (availableBodyWidth - startWidth) * horizontalProgress
        let height = startHeight + (rect.height - startHeight) * verticalProgress
        let surfaceRect = CGRect(
            x: rect.midX - width / 2,
            y: rect.minY,
            width: width,
            height: height
        )
        let requestedBottomRadius = NotchLayout.compactCornerRadius
            + (NotchLayout.cornerRadius - NotchLayout.compactCornerRadius) * verticalProgress
        // 側面から底面への曲がり始めを早め、小さな角がカクっと回る印象を抑える。
        let bottomRadius = min(
            requestedBottomRadius,
            width / 2,
            height / 2
        )
        let shoulder = min(
            NotchLayout.topShoulderWidth,
            max((rect.width - width) / 2, 0)
        )

        // 上端は本体より外へ張り出し、逆カーブで側面へ溶け込ませる。
        // 画面上端と黒いノッチの間に直角の継ぎ目ができない。
        let top = surfaceRect.minY
        let bottom = surfaceRect.maxY
        let left = surfaceRect.minX
        let right = surfaceRect.maxX
        let shoulderDepth = min(shoulder, height / 2)
        let leftOuter = left - shoulder
        let rightOuter = right + shoulder

        var path = Path()
        path.move(to: CGPoint(x: leftOuter, y: top))
        path.addLine(to: CGPoint(x: rightOuter, y: top))
        path.addCurve(
            to: CGPoint(x: right, y: top + shoulderDepth),
            control1: CGPoint(x: rightOuter - shoulder * 0.46, y: top),
            control2: CGPoint(x: right, y: top + shoulderDepth * 0.42)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - bottomRadius))
        path.addCurve(
            to: CGPoint(x: right - bottomRadius, y: bottom),
            control1: CGPoint(
                x: right,
                y: bottom - bottomRadius * NotchLayout.cornerBezierControl
            ),
            control2: CGPoint(
                x: right - bottomRadius * NotchLayout.cornerBezierControl,
                y: bottom
            )
        )
        path.addLine(to: CGPoint(x: left + bottomRadius, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: bottom - bottomRadius),
            control1: CGPoint(
                x: left + bottomRadius * NotchLayout.cornerBezierControl,
                y: bottom
            ),
            control2: CGPoint(
                x: left,
                y: bottom - bottomRadius * NotchLayout.cornerBezierControl
            )
        )
        path.addLine(to: CGPoint(x: left, y: top + shoulderDepth))
        path.addCurve(
            to: CGPoint(x: leftOuter, y: top),
            control1: CGPoint(x: left, y: top + shoulderDepth * 0.42),
            control2: CGPoint(x: leftOuter + shoulder * 0.46, y: top)
        )
        path.closeSubpath()
        return path
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

struct NotchView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(NotchPreferences.expansionAnimationDurationKey)
    private var expansionAnimationDuration = NotchPreferences.defaultExpansionAnimationDuration
    @FocusState private var inputFocused: Bool
    @FocusState private var choiceFocused: Bool
    @State private var historyIndex: Int?
    @State private var showAllUsage = false
    @State private var autoTmuxInstalled = ShellIntegration.isInstalled()
    @State private var autoTmuxMessage: String?
    @State private var autoTmuxMessageIsError = false
    /// 黒いノッチ面の内側に表示する内容。輪郭の変形と時間差を付ける。
    @State private var renderedMode: NotchMode = .compact
    /// 0が物理ノッチ寸法、1が展開寸法。常に同じ輪郭を変形させる。
    @State private var morphProgress: CGFloat = 0
    @State private var contentOpacity: Double = 1
    /// 短時間に開閉が反転した場合、古い遅延処理を無効化する。
    @State private var transitionID = UUID()
    /// 複数選択でチェックした選択肢の番号
    @State private var multiSelection: Set<Int> = []
    /// ゴーストへの「覗き込み」合図（コンパクト表示にマウスが乗るたびに+1）
    @State private var ghostPeekTrigger = 0

    private var metrics: NotchMetrics? { coordinator.notchMetrics }
    private var topInset: CGFloat { metrics?.topInset ?? 34 }
    private var notchWidth: CGFloat { metrics?.notchWidth ?? 190 }

    var body: some View {
        let requestedMode = coordinator.displayMode

        ZStack(alignment: .top) {
            // 表示モードが変わっても差し替えない、1枚のノッチ面。
            // 大きな透明キャンバス内で中央上端を固定し、左右と下へ膨らむ。
            NotchSurfaceShape(
                progress: morphProgress,
                compactWidth: notchWidth + NotchLayout.sideWidth * 2,
                compactHeight: topInset,
                canvasShoulderInset: NotchLayout.topShoulderWidth
            )
            .fill(.black)
            .shadow(
                color: .black.opacity(morphProgress * 0.45),
                radius: 10 * morphProgress,
                y: 5 * morphProgress
            )

            content(for: renderedMode)
                .frame(width: contentWidth(for: renderedMode))
                // 内容の差し替えで輪郭まで新しいビューにしない。
                // 先に黒い面を膨らませ、スペースができてから内容を見せる。
                .opacity(contentOpacity)
                .mask(alignment: .top) {
                    NotchSurfaceShape(
                        progress: morphProgress,
                        compactWidth: notchWidth + NotchLayout.sideWidth * 2,
                        compactHeight: topInset,
                        // 内容のマスクは本体幅と同じなので、外側余白は不要。
                        canvasShoulderInset: 0
                    )
                    .fill(.white)
                }
                // 実際の内容高をパネルの最終寸法に反映する。
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.height, initial: true) { _, height in
                                coordinator.reportContentHeight(height, for: renderedMode)
                            }
                    }
                )
        }
        .contentShape(
            NotchSurfaceShape(
                progress: morphProgress,
                compactWidth: notchWidth + NotchLayout.sideWidth * 2,
                compactHeight: topInset,
                canvasShoulderInset: NotchLayout.topShoulderWidth
            )
        )
        .onHover { coordinator.hoverChanged(to: $0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            renderedMode = requestedMode
            morphProgress = requestedMode == .compact ? 0 : 1
            contentOpacity = 1
        }
        .onChange(of: requestedMode) { _, newMode in
            transition(to: newMode)
            if newMode == .sessions {
                autoTmuxInstalled = ShellIntegration.isInstalled()
            }
            historyIndex = newMode == .input ? nil : historyIndex
            inputFocused = false
            choiceFocused = false
            // パネルがキーウインドウになるのを待ってからフォーカスを与える
            guard newMode == .input || newMode == .choice else { return }
            let focusDelay = max(0.08, animationDuration(to: newMode) * 0.42)
            DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
                guard coordinator.displayMode == newMode else { return }
                if newMode == .input {
                    inputFocused = true
                } else {
                    choiceFocused = true
                }
            }
        }
    }

    private func morphAnimation(to mode: NotchMode) -> Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        return .spring(
            response: animationDuration(to: mode),
            dampingFraction: 0.82,
            blendDuration: 0.12
        )
    }

    private func animationDuration(to mode: NotchMode) -> TimeInterval {
        mode == .compact
            ? NotchLayout.collapseAnimationDuration
            : NotchPreferences.normalizedExpansionAnimationDuration(
                expansionAnimationDuration
            )
    }

    /// 輪郭と内容を同時に差し替えず、Dynamic Islandのように段階的に見せる。
    private func transition(to newMode: NotchMode) {
        let token = UUID()
        transitionID = token
        let duration = reduceMotion ? 0.01 : animationDuration(to: newMode)

        if newMode == .compact {
            withAnimation(.easeOut(duration: min(0.10, duration * 0.30))) {
                contentOpacity = 0
            }
            withAnimation(morphAnimation(to: newMode)) {
                morphProgress = 0
            }
            schedule(after: duration * 0.58, token: token) {
                renderedMode = .compact
                withAnimation(.easeIn(duration: min(0.12, duration * 0.35))) {
                    contentOpacity = 1
                }
            }
            return
        }

        if morphProgress < 0.99 {
            // コンパクト内容は展開開始とともに消し、開いた領域へ新しい内容を出す。
            withAnimation(.easeOut(duration: min(0.10, duration * 0.22))) {
                contentOpacity = 0
            }
            withAnimation(morphAnimation(to: newMode)) {
                morphProgress = 1
            }
            schedule(after: duration * 0.16, token: token) {
                renderedMode = newMode
            }
            schedule(after: duration * 0.34, token: token) {
                withAnimation(.easeIn(duration: min(0.16, duration * 0.32))) {
                    contentOpacity = 1
                }
            }
        } else {
            // 展開済みモード間では輪郭を縮めず、内容だけを素早く交差させる。
            withAnimation(.easeOut(duration: 0.08)) {
                contentOpacity = 0
            }
            schedule(after: 0.08, token: token) {
                renderedMode = newMode
                withAnimation(.easeIn(duration: 0.12)) {
                    contentOpacity = 1
                }
            }
        }
    }

    private func schedule(
        after delay: TimeInterval,
        token: UUID,
        action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard transitionID == token else { return }
            action()
        }
    }

    @ViewBuilder
    private func content(for mode: NotchMode) -> some View {
        switch mode {
        case .compact: compactContent
        case .notification: notificationContent
        case .input: inputContent
        case .choice: choiceContent
        case .sessions: sessionsContent
        case .activity: activityContent
        case .onboarding: onboardingContent
        }
    }

    private func contentWidth(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .compact: return notchWidth + NotchLayout.sideWidth * 2
        case .notification: return max(notchWidth + 280, 620)
        case .input: return max(notchWidth + 280, 640)
        case .choice: return max(notchWidth + 320, 680)
        case .sessions: return max(notchWidth + 420, 760)
        case .activity: return max(notchWidth + 420, 760)
        case .onboarding: return max(notchWidth + 320, 680)
        }
    }

    // MARK: - コンパクト：状態アイコンのみ (設計書 4.1 / 6.2)

    private var compactContent: some View {
        HStack(spacing: 0) {
            // 左余白：アクティブセッションの状態
            HStack {
                PixelGhostView(
                    state: coordinator.watcher.activeSession?.state ?? .idle,
                    peekTrigger: ghostPeekTrigger
                )
            }
            .frame(width: NotchLayout.sideWidth)
            // マウスが乗った瞬間だけ一瞬「覗き込む」。展開判定(coordinator.hoverChanged)とは
            // 別に、ゴースト自体のちょっとした反応として独立させている。
            .onHover { hovering in
                if hovering { ghostPeekTrigger += 1 }
            }

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
                PixelGhostView(state: session?.state ?? .idle, pixelSize: 2.5)
                Text(session?.info.profile.displayName ?? "セッションなし")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let name = session?.info.displayName {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if let usage = coordinator.watcher.usage {
                    UsageBadge(usage: usage)
                }
                Text(session?.state.displayName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let preview = session?.preview, !preview.isEmpty {
                // 応答は長くなるため、折り返して読めるようにし、スクロールできるようにする
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: 210, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            } else if let session, !session.info.isMonitorable {
                Text("このセッションはまだ状態を読めません。フック連携を有効にしていれば、CLIが動き出した時点で監視が始まります")
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

    // MARK: - 展開（一覧）：複数CLIをまとめて見る

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: topInset)   // ノッチ本体を避ける

            // 上段: 使用量と操作アイコン
            HStack(spacing: 8) {
                if let usage = coordinator.watcher.usage {
                    let others = coordinator.watcher.allUsage
                    Button {
                        if others.count > 1 { showAllUsage.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            UsageBadge(usage: usage)
                            if others.count > 1 {
                                Image(systemName: showAllUsage ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(others.count > 1 ? "他のAIの使用量も表示" : "レート制限の消費率")
                    .popover(isPresented: $showAllUsage, arrowEdge: .bottom) {
                        UsagePopover(items: others)
                    }
                } else {
                    Text("実行中のAI CLI \(coordinator.watcher.sessions.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    coordinator.showActivity()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                        if coordinator.activity.unreadCount > 0 {
                            Text("\(coordinator.activity.unreadCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red.opacity(0.85)))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("アクティビティ履歴")

                Button {
                    coordinator.dismissExpandedPanel()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("折りたたむ")

                Button {
                    coordinator.toggleMute()
                } label: {
                    Image(systemName: coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(coordinator.isMuted ? 0.4 : 0.75))
                }
                .buttonStyle(.plain)
                .help(coordinator.isMuted ? "サウンドを有効にする" : "サウンドを消音する")

                SettingsLink {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("設定を開く")

                // メニューバー項目を置かないため、終了もここから行えるようにする
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Subghostを終了")
            }
            .padding(.bottom, 2)

            if coordinator.watcher.sessions.isEmpty {
                Text("AI CLI が見つかりません。ターミナルで claude / codex / agy を起動してください")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            if shouldOfferAutoTmux {
                autoTmuxReminder
            }

            if !coordinator.watcher.sessions.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(coordinator.watcher.sessions) { session in
                            SessionRow(
                                session: session,
                                isActive: session.info.tty == coordinator.watcher.activeSessionName,
                                onJump: { coordinator.jump(to: session) },
                                onPrompt: { coordinator.promptSession(session) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: NotchLayout.sessionsListHeight(
                    count: coordinator.watcher.sessions.count
                ))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 展開（履歴）：見逃したイベントを確認

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: topInset)

            HStack(spacing: 8) {
                Button {
                    coordinator.showSessions()
                } label: {
                    Label("一覧", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)

                Text("アクティビティ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !coordinator.activity.entries.isEmpty {
                    Button("すべて消去") {
                        coordinator.activity.clear()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }

            if coordinator.activity.entries.isEmpty {
                ContentUnavailableView {
                    Label("履歴はまだありません", systemImage: "clock")
                } description: {
                    Text("完了・エラー・承認待ち・質問がここに表示されます")
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 150)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(coordinator.activity.entries) { entry in
                            ActivityRow(
                                entry: entry,
                                hasLiveSession: coordinator.hasLiveSession(for: entry),
                                onOpen: { coordinator.jump(to: entry) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: min(
                    CGFloat(coordinator.activity.entries.count) * 66,
                    NotchLayout.sessionsListMaxHeight
                ))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 展開（初回案内）：ようこそ→フック連携→権限→完了

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: topInset)

            // 現在地が一目で分かるよう、段階をドットで示す
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Circle()
                        .fill(.white.opacity(step == coordinator.onboardingStep ? 0.9 : 0.25))
                        .frame(width: 5, height: 5)
                }
                Spacer()
                if coordinator.onboardingStep != .done {
                    Button("スキップ") { coordinator.skipOnboarding() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            onboardingStepContent

            HStack {
                Spacer()
                Button(coordinator.onboardingStep == .done ? "はじめる" : "次へ") {
                    coordinator.advanceOnboarding()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.9)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var onboardingStepContent: some View {
        switch coordinator.onboardingStep {
        case .welcome:
            VStack(alignment: .leading, spacing: 6) {
                Text("👻 Subghostへようこそ")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("ノッチにAI CLIの状態を表示し、質問への回答や通知をまとめて扱えるようにします。"
                     + "最初にいくつかだけ設定を確認しましょう。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }

        case .hooks:
            VStack(alignment: .leading, spacing: 8) {
                Text("フック連携（推奨）")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("有効にすると、画面の文字解析に頼らず正確に状態を検知できます。誤判定も無くなります。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                ForEach(HookTarget.allCases) { target in
                    onboardingHookRow(target)
                }
            }

        case .permissions:
            VStack(alignment: .leading, spacing: 8) {
                Text("アクセシビリティ権限")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("質問への回答をノッチから送るには、アクセシビリティの許可が必要です"
                     + "（tmux経由のセッションでは不要です）。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 8) {
                    Image(systemName: KeystrokeSender.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(KeystrokeSender.isTrusted ? .green : .orange)
                    Text(KeystrokeSender.isTrusted ? "許可済みです" : "まだ許可されていません")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if !KeystrokeSender.isTrusted {
                        Button("システム設定を開く") { KeystrokeSender.requestTrust() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                    }
                }
            }

        case .done:
            VStack(alignment: .leading, spacing: 6) {
                Text("準備ができました")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("歯車アイコン（ノッチにカーソルを合わせると出てきます）からいつでも設定を開けます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(HotkeyPreset.current.displayName) でプロンプト入力欄を開閉できます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func onboardingHookRow(_ target: HookTarget) -> some View {
        let isOn = HookInstaller.isInstalled(target)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isOn ? .green : .white.opacity(0.4))
                Text(target.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if !isOn {
                    Button("有効にする") { coordinator.enableHookFromOnboarding(target) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                }
            }
            if let message = coordinator.onboardingHookMessage[target] {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// tmux外で起動したことを検出した場合だけ、自動化を案内する。
    /// フック連携済みでも、ユーザーがtmux利用を望む場合に見落とさないよう表示する。
    private var shouldOfferAutoTmux: Bool {
        !autoTmuxInstalled
            && coordinator.watcher.sessions.contains { $0.info.tmuxTarget == nil }
    }

    private var autoTmuxReminder: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("tmux外で起動しているセッションがあります")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(autoTmuxMessage ?? autoTmuxDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(autoTmuxMessageIsError ? .red : .white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if TmuxClient.resolveTmuxPath() != nil {
                Button("次回から自動起動") {
                    enableAutoTmux()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("claude / codex / agy（カスタムエイリアス含む）を自動的にtmux内で起動します")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var autoTmuxDescription: String {
        if TmuxClient.resolveTmuxPath() == nil {
            return "tmuxが見つかりません。brew install tmux の後に自動起動を設定できます"
        }
        return "ボタンを押すと、次に開くターミナルからtmuxを挟み忘れなくなります"
    }

    private func enableAutoTmux() {
        do {
            try ShellIntegration.install(extraCommands: coordinator.customAliasStore.aliases.map(\.name))
            autoTmuxInstalled = true
            autoTmuxMessage = nil
            autoTmuxMessageIsError = false
        } catch {
            autoTmuxMessage = "自動起動を設定できませんでした: \(error.localizedDescription)"
            autoTmuxMessageIsError = true
        }
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
                // 複数の問いが続く場合は「2 / 3」で残りが分かるようにする
                if let progress = choice?.progressLabel {
                    Text(progress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                }
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
                        ChoiceOptionRow(
                            option: option,
                            // 複数選択に既定の選択肢は無い（⏎は決定に割り当てる）
                            isDefault: !choice.isMultiSelect && option == choice.options.first,
                            isMultiSelect: choice.isMultiSelect,
                            isSelected: multiSelection.contains(option.number)
                        ) {
                            if choice.isMultiSelect {
                                toggleSelection(option)
                            } else {
                                coordinator.respond(with: option)
                            }
                        }
                    }
                }

                // 複数選択は選び終えてから確定する
                if choice.isMultiSelect {
                    Button { submitMultiSelection(choice) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(multiSelection.isEmpty
                                 ? "1つ以上選んでください"
                                 : "\(multiSelection.count)件を決定")
                            Spacer()
                            Text("⏎")
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(multiSelection.isEmpty ? .white.opacity(0.4) : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(multiSelection.isEmpty ? .white.opacity(0.06) : .accentColor.opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(multiSelection.isEmpty)
                }

                // 背景で回答できないセッションは、その理由と対処を明示する
                if session?.canRespondToChoice == false {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                        Text("他の画面を見ながら回答するには tmux 内で起動してください。今はターミナルのタブで直接お選びください")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("回答待ちの問い合わせはありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if let sent = coordinator.choiceSentLabel {
                Label("「\(sent)」を送信しました", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else if coordinator.isSendingChoice {
                Label("送信中…", systemImage: "paperplane")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            } else if let error = coordinator.lastChoiceError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                HStack {
                    Text(choice?.isMultiSelect == true
                         ? "数字キーで選択・解除 / ⏎ で決定"
                         : "数字キーで回答 / ⏎ で先頭を選択")
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
        // 次の問いへ移ったらチェックを持ち越さない
        .onChange(of: choice) { multiSelection = [] }
    }

    /// 数字キー・y/n・Enterで選択肢へ回答する
    private func handleChoiceKey(_ press: KeyPress) -> KeyPress.Result {
        guard let choice = coordinator.pendingChoice else { return .ignored }

        if press.key == .return {
            // 複数選択では⏎は「決定」。先頭を選ぶ動作にはしない。
            if choice.isMultiSelect {
                submitMultiSelection(choice)
                return .handled
            }
            guard let first = choice.options.first else { return .ignored }
            coordinator.respond(with: first)
            return .handled
        }

        let typed = String(press.characters).lowercased()
        guard let option = choice.options.first(where: { $0.keystroke.lowercased() == typed }) else {
            return .ignored
        }
        if choice.isMultiSelect {
            toggleSelection(option)
        } else {
            coordinator.respond(with: option)
        }
        return .handled
    }

    /// 複数選択のチェックを付け外しする
    private func toggleSelection(_ option: ChoiceOption) {
        if multiSelection.contains(option.number) {
            multiSelection.remove(option.number)
        } else {
            multiSelection.insert(option.number)
        }
    }

    /// チェックした選択肢をまとめて送信する
    private func submitMultiSelection(_ choice: PendingChoice) {
        let selected = choice.options.filter { multiSelection.contains($0.number) }
        guard !selected.isEmpty else { return }
        coordinator.respond(with: selected)
        multiSelection = []
    }

    // MARK: - 展開（入力）：クイックプロンプト (設計書 4.3 / 4.4)

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)

            HStack(spacing: 8) {
                Button {
                    coordinator.showSessions()
                } label: {
                    Label("一覧", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("セッション一覧へ戻る")

                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                // 送信先セッション選択 (設計書 4.3: 複数ある場合はドロップダウン)
                if let active = coordinator.watcher.activeSession {
                    StateDot(state: active.state, pulsing: active.state.shouldPulse, size: 7)
                }
                if coordinator.watcher.sessions.count > 1 {
                    Picker("送信先", selection: activeSessionBinding) {
                        ForEach(coordinator.watcher.sessions) { session in
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
                Text("⌘↩ 送信")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Esc で閉じる")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ZStack(alignment: .topLeading) {
                if coordinator.inputText.isEmpty {
                    Text("プロンプトを入力…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $coordinator.inputText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(8)
                    .focused($inputFocused)
            }
            .frame(minHeight: 88, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                historyIndex = nil
                coordinator.sendPrompt()
                return .handled
            }
                .onExitCommand { coordinator.collapse() }
                .onKeyPress(.upArrow, phases: .down) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    historyUp()
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    historyDown()
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

            HStack {
                Text("⌥↑ / ⌥↓ で送信履歴")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("下書きは送信先ごとに保存されます")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }

            if let error = coordinator.lastSendError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if coordinator.watcher.sessions.isEmpty {
                Text("AI CLI が見つかりません。ターミナルで claude / codex / agy を起動してください")
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
            set: { if let tty = $0 { coordinator.watcher.chooseActiveSession(tty) } }
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

// MARK: - セッション一覧の1行

struct SessionRow: View {
    let session: MonitoredSession
    /// 現在の送信先か
    let isActive: Bool
    /// 行本体を押したとき（そのタブへ移動）
    let onJump: () -> Void
    /// 送信ボタンを押したとき（このセッションへプロンプトを送る）
    let onPrompt: () -> Void

    @State private var isHovering = false
    @State private var isPromptHovering = false

    /// 先頭に出す見出し。CLIが起動しているフォルダ名と直近の用件を並べる。
    private var title: String {
        let folder = session.info.folderName ?? session.info.shortName
        guard let prompt = session.lastUserPrompt, !prompt.isEmpty else { return folder }
        return "\(folder) · \(prompt)"
    }

    var body: some View {
        // 入れ子のButtonは正しく動作しないため、移動と送信を並べて配置する
        HStack(alignment: .top, spacing: 8) {
            Button(action: onJump) {
                HStack(alignment: .top, spacing: 10) {
                    PixelGhostView(state: session.state, pixelSize: 2.5)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        // 1行目: 見出しと各種バッジ
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            TagBadge(text: session.info.profile.displayName, tint: agentTint)
                            TagBadge(text: session.state.displayName, tint: stateTint)
                            if let terminal = session.info.terminalName {
                                TagBadge(text: terminal, tint: .white.opacity(0.18))
                            }
                            Text(elapsedText)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }

                        // 2行目: 直近のユーザー発言
                        if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                            HStack(spacing: 4) {
                                Text("あなた：")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.4))
                                Text(prompt)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }

                        // 3行目: 直近のAIの返信（状態が読めなくても記録から出す）
                        if let reply = secondaryText {
                            Text(reply)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onPrompt) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(isPromptHovering ? 0.95 : 0.5))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(isPromptHovering ? 0.2 : 0.07))
                    )
            }
            .buttonStyle(.plain)
            .onHover { isPromptHovering = $0 }
            .help("このセッションへプロンプトを送る")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(isHovering ? 0.14 : (isActive ? 0.09 : 0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(isActive ? 0.2 : 0), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    /// CLIごとに色を変えて見分けやすくする
    private var agentTint: Color {
        switch session.info.profile.id {
        case "claude": return Color.orange.opacity(0.35)
        case "codex": return Color.blue.opacity(0.4)
        default: return Color.green.opacity(0.35)
        }
    }

    private var stateTint: Color {
        switch session.state {
        case .idle: return Color.gray.opacity(0.3)
        case .thinking: return Color.blue.opacity(0.55)
        case .awaitingApproval: return Color.orange.opacity(0.5)
        case .awaitingAnswer: return Color.yellow.opacity(0.45)
        case .completed: return Color.green.opacity(0.45)
        case .error: return Color.red.opacity(0.5)
        }
    }

    /// 3行目: 直近のAIの返信。状態が読めなくても記録から出す。
    private var secondaryText: String? {
        if let line = session.preview.first(where: { !$0.isEmpty }) { return line }
        if let reply = session.lastReply, !reply.isEmpty { return reply }
        // 返信がまだ無いときだけ、監視できていれば状態を出す
        return session.info.isMonitorable ? session.state.displayName : nil
    }

    /// 最後の動きからの経過時間
    private var elapsedText: String {
        let seconds = Int(Date().timeIntervalSince(session.lastActivityAt))
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

/// 角丸の小さなラベル
struct TagBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint))
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let hasLiveSession: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                AgentBadgeIcon(agentID: entry.agentID, size: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Label(entry.kind.displayName, systemImage: iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(entry.sessionName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(entry.createdAt, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(entry.summary.isEmpty ? entry.agentName : entry.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(hasLiveSession ? "開く" : "終了済み")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(hasLiveSession ? 0.7 : 0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(entry.isRead ? 0.04 : 0.09))
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasLiveSession)
    }

    private var iconName: String {
        switch entry.kind {
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .completed: return .green
        case .error: return .red
        case .approval: return .orange
        case .question: return .yellow
        }
    }
}

// MARK: - 選択肢の1行 (Approve / Ask)

struct ChoiceOptionRow: View {
    let option: ChoiceOption
    /// Enterで選ばれる既定の選択肢か
    let isDefault: Bool
    /// 複数選択の問いか（チェックボックスで表示する）
    var isMultiSelect: Bool = false
    /// 複数選択でチェック済みか
    var isSelected: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    /// 「はい」系は緑、「いいえ」系は赤、それ以外は無彩色で示す
    private var tint: Color {
        if option.isAffirmative { return .green }
        if option.isNegative { return .red }
        return .white
    }

    /// 枠線の濃さ。複数選択では選択中を強調する。
    private var borderOpacity: Double {
        if isMultiSelect { return isSelected ? 0.7 : 0 }
        return isDefault ? 0.5 : 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(option.keystroke.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.85)))

                if isMultiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.45))
                }

                Text(option.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    // 長いラベルは途中で切らず2行まで折り返す
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if isDefault {
                    Text("⏎")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(borderOpacity), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// 背景の濃さ。選択中とホバー中を段階的に示す。
    private var backgroundOpacity: Double {
        if isMultiSelect, isSelected { return 0.22 }
        return isHovering ? 0.18 : 0.08
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


// MARK: - 使用量の表示

/// レート制限の消費率を "5h 68% 48m | 7d 40% 6h48m" の形で出す
struct UsageBadge: View {
    let usage: UsageStats

    var body: some View {
        HStack(spacing: 6) {
            // どのCLIの使用量かを、そのAIアプリの公式アイコンで示す（左）
            AgentBadgeIcon(agentID: usage.agentID, size: 14)
            if let window = usage.fiveHour {
                windowView(label: "5h", window: window)
            }
            if usage.fiveHour != nil, usage.sevenDay != nil {
                Text("|").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
            }
            if let window = usage.sevenDay {
                windowView(label: "7d", window: window)
            }
        }
        .help("\(agentLabel) のレート制限の消費率と、リセットまでの残り時間")
    }

    private func windowView(label: String, window: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(for: window))
            if let remaining = window.remainingText() {
                Text(remaining)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var agentLabel: String {
        switch usage.agentID {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return usage.agentID
        }
    }

    /// 残りが少ないほど強い色にする
    private func color(for window: UsageWindow) -> Color {
        if window.isCritical { return .red }
        if window.isWarning { return .orange }
        return .green
    }
}


// MARK: - 全AIの使用量ポップオーバー

/// アイコンをクリックしたとき、取得済みの全AIの使用量を並べて出す
struct UsagePopover: View {
    let items: [UsageStats]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AIごとの使用量")
                .font(.system(size: 12, weight: .semibold))
            ForEach(items, id: \.agentID) { usage in
                HStack(spacing: 8) {
                    AgentBadgeIcon(agentID: usage.agentID, size: 16)
                    Text(agentLabel(usage.agentID))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 84, alignment: .leading)
                    UsageBadge(usage: usage)
                        .environment(\.colorScheme, .light)
                }
            }
            Text("最後に使ったAIの使用量をノッチに表示しています")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    private func agentLabel(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "antigravity": return "Antigravity"
        default: return id
        }
    }
}
