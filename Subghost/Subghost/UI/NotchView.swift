//
//  NotchView.swift
//  Subghost
//
//  設計書 6. UI/UX仕様（コンパクト / 展開(通知) / 展開(入力)）
//
//  ノッチパネルの中身を描くSwiftUIビュー一式。
//  AppCoordinator.displayMode に従って、状態ドットだけのコンパクト表示から、
//  応答のチラ見せ・セッション一覧・選択肢（承認/質問）・プロンプト入力までを切り替える。
//
//  物理ノッチと展開部分は NotchSurfaceShape が1本の連続したパスとして描く。
//  形状の寸法は NotchLayout に集約されており、パネル側のサイズ計算と
//  必ず同じ関数を通す（片方だけ変えると輪郭がずれる）。
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

    /// 黒い面の濃さ。
    /// コンパクト時は必ず不透明にする（物理ノッチと地続きに見せる必要があるため）。
    /// 展開するにつれて設定した不透明度へ寄せる。
    private var surfaceOpacity: Double {
        let target = AppearancePreferences.panelOpacity
        return 1 - (1 - target) * Double(morphProgress)
    }

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
            .fill(.black.opacity(surfaceOpacity))
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

            // 右余白：一覧に出しているセッションの小ドット
            HStack(spacing: 4) {
                let visible = coordinator.watcher.visibleSessions
                if visible.isEmpty {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                } else {
                    ForEach(visible.prefix(4)) { session in
                        StateDot(state: session.state, pulsing: session.state.shouldPulse, size: 6)
                    }
                }
            }
            .frame(width: NotchLayout.sideWidth)
        }
        .frame(height: topInset)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.jumpToTerminal() }
        // ゴーストもドットも図形を描いているだけで、支援技術には何も伝わらない。
        // このアプリの中核情報（どのセッションがどの状態か）が無音にならないよう、
        // まとめて1つの要素にして読み上げ内容を明示する。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactAccessibilityLabel)
        .accessibilityHint("該当するターミナルのタブへ移動します")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { coordinator.jumpToTerminal() }
    }

    /// コンパクト表示の読み上げ文。状態は色と絵でしか出していないため、言葉で補う。
    private var compactAccessibilityLabel: String {
        let sessions = coordinator.watcher.sessions
        guard let active = coordinator.watcher.activeSession else {
            return sessions.isEmpty
                ? "Subghost。AI CLIは実行されていません"
                : "Subghost。\(sessions.count)件のセッションを監視中"
        }

        var text = "Subghost。\(active.info.profile.displayName) "
            + "\(active.info.displayName) は\(active.state.accessibilityDescription)"
        let waiting = sessions.filter { $0.state.needsUserResponse }.count
        if waiting > 0 { text += "。\(waiting)件が応答待ちです" }
        if sessions.count > 1 { text += "。ほかに\(sessions.count - 1)件を監視中" }
        return text
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

            if let rawPreview = session?.preview, !rawPreview.isEmpty {
                // 画面共有向けに本文を伏せる設定があるため、描画の直前で差し替える
                let preview = AppearancePreferences.maskedPreview(rawPreview)
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
                // 以前は「クリックで移動」という説明文だけで、実際の操作は
                // 領域全体の onTapGesture だった。キーボードとVoiceOverから
                // 到達できるよう、本物のボタンにしている。
                Button("該当タブへ移動") { coordinator.jumpToTerminal() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityHint("このセッションが動いているターミナルのタブを前面に出します")
                Spacer()
                // ホットキーは設定で変更できるため、固定文字列にしない。
                Text("\(HotkeyAction.toggleInput.shortcutOrName) で入力")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
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
                    .accessibilityLabel(others.count > 1 ? "使用量。他のAIの使用量も表示" : "レート制限の消費率")
                    .popover(isPresented: $showAllUsage, arrowEdge: .bottom) {
                        UsagePopover(items: others)
                    }
                } else {
                    Text("実行中のAI CLI \(coordinator.watcher.sessions.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
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
                    .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("アクティビティ履歴")
                .accessibilityLabel(coordinator.activity.unreadCount > 0
                                    ? "アクティビティ履歴。未読\(coordinator.activity.unreadCount)件"
                                    : "アクティビティ履歴")

                Button {
                    coordinator.dismissExpandedPanel()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("折りたたむ")
                .accessibilityLabel("折りたたむ")

                Button {
                    coordinator.toggleMute()
                } label: {
                    Image(systemName: coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(coordinator.isMuted ? 0.55 : 0.8))
                }
                .buttonStyle(.plain)
                .help(coordinator.isMuted ? "サウンドを有効にする" : "サウンドを消音する")
                .accessibilityLabel("サウンド")
                .accessibilityValue(coordinator.isMuted ? "消音中" : "オン")
                .accessibilityHint(coordinator.isMuted ? "サウンドを有効にします" : "サウンドを消音します")

                // SettingsLink は Scene の環境が要るため、Scene外のこのパネルでは動かない。
                // 自前の設定ウインドウを開く（SettingsWindowController 参照）。
                Button {
                    coordinator.openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("設定を開く")
                .accessibilityLabel("設定を開く")

                // メニューバー項目を置かないため、終了もここから行えるようにする
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Subghostを終了")
                .accessibilityLabel("Subghostを終了")
            }
            .padding(.bottom, 2)

            if coordinator.watcher.sessions.isEmpty {
                Text("AI CLI が見つかりません。ターミナルで claude / codex / agy を起動してください")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            if shouldOfferAutoTmux {
                autoTmuxReminder
            }

            let visible = coordinator.watcher.visibleSessions
            if !visible.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { session in
                            SessionRow(
                                session: session,
                                isActive: session.info.tty == coordinator.watcher.activeSessionName,
                                onJump: { coordinator.jump(to: session) },
                                onPrompt: { coordinator.promptSession(session) },
                                onHide: { coordinator.hideSession(session) },
                                onTerminate: { coordinator.confirmTerminate(session) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: NotchLayout.sessionsListHeight(count: visible.count))
            }

            // 隠したぶんは黙って消さず、件数と戻す手段を残す
            if coordinator.watcher.revealsHiddenSessions {
                Button("放置中のセッションを隠す") {
                    coordinator.watcher.revealsHiddenSessions = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 2)
            } else if coordinator.watcher.hiddenSessionCount > 0 {
                HStack(spacing: 6) {
                    Text("他に \(coordinator.watcher.hiddenSessionCount) 件（放置・監視不可）")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("すべて表示") {
                        coordinator.watcher.unhideAll()
                        coordinator.watcher.revealsHiddenSessions = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 2)
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
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("セッション一覧へ戻る")

                Text("アクティビティ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !coordinator.activity.entries.isEmpty {
                    Button("すべて消去") {
                        coordinator.activity.clear()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
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
                        .fill(.white.opacity(step == coordinator.onboardingStep ? 0.9 : 0.35))
                        .frame(width: 5, height: 5)
                }
                Spacer()
                if coordinator.onboardingStep != .done {
                    Button("スキップ") { coordinator.skipOnboarding() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            // 進捗はドットの濃淡でしか示していないため、言葉でも伝える。
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "セットアップ \(coordinator.onboardingStep.rawValue + 1) / \(OnboardingStep.allCases.count)"
            )

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
                Text("tmux を使うかどうか")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("フックの登録だけで、状態の監視・完了通知・承認への回答が使えます。"
                     + "ノッチからプロンプトを送りたい場合のみ tmux が必要です。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 8) {
                    let hasTmux = TmuxClient.resolveTmuxPath() != nil
                    Image(systemName: hasTmux ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(hasTmux ? .green : .white.opacity(0.5))
                    Text(hasTmux
                         ? "tmux があります。プロンプトの送信まで使えます"
                         : "tmux はありません。監視のみの構成で動きます")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
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
                Text("\(HotkeyAction.toggleInput.shortcutOrName) でプロンプト入力欄を開閉できます。")
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
    /// tmux の導入を勧めるか。
    ///
    /// tmuxを使わず「監視だけ」で使うのも正規の構成なので、
    /// 送信を必要としない人にまで出し続けない。設定で止められる。
    private var shouldOfferAutoTmux: Bool {
        guard !autoTmuxInstalled, NotchPreferences.suggestsTmuxSetup else { return false }
        return coordinator.watcher.sessions.contains { $0.info.tmuxTarget == nil }
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

            // 監視だけで使う人向けの出口。勧誘を出し続けない。
            Button("監視だけで使う") {
                NotchPreferences.setSuggestsTmuxSetup(false)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.6))
            .help("この案内を今後表示しません。設定の「セッション一覧」からいつでも戻せます")
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
        return "tmuxを挟むとノッチからプロンプトを送れます（無くても監視と通知は動きます）"
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
                            isDefault: isEnterDefault(option, in: choice),
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
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(multiSelection.isEmpty ? .white.opacity(0.55) : .white)
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
                    Text(choiceKeyHint(for: choice))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Button("ターミナルで開く") { coordinator.jumpToTerminal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Esc で閉じる")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .focusable()
        .focused($choiceFocused)
        .onKeyPress { press in handleChoiceKey(press) }
        .onExitCommand { coordinator.dismissChoice() }
        // 次の問いへ移ったらチェックを持ち越さない
        .onChange(of: choice) { multiSelection = [] }
        // 選択肢はキーボード操作が主なので、パネル全体を1つの通知として読み上げる。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(choiceAccessibilityLabel(for: choice))
    }

    /// ⏎ で選ばれる既定の選択肢か。
    ///
    /// 承認リクエストの先頭は通常「はい／許可」で、⏎ を既定に割り当てると
    /// 誤打鍵がそのまま許可になってしまう。承認では既定を置かず、
    /// 数字キーかクリックによる明示的な選択だけを受け付ける。
    private func isEnterDefault(_ option: ChoiceOption, in choice: PendingChoice) -> Bool {
        guard !choice.isMultiSelect, choice.kind != .approval else { return false }
        return option == choice.options.first
    }

    /// 画面下のキー操作ヒント。実装している操作だけを出す。
    private func choiceKeyHint(for choice: PendingChoice?) -> String {
        guard let choice else { return "" }
        if choice.isMultiSelect { return "数字キーで選択・解除 / ⏎ で決定" }
        if choice.kind == .approval { return "数字キーで回答（誤操作防止のため ⏎ の既定はありません）" }
        return "数字キーで回答 / ⏎ で先頭を選択"
    }

    private func choiceAccessibilityLabel(for choice: PendingChoice?) -> String {
        guard let choice else { return "回答待ちの問い合わせはありません" }
        return "\(choice.kind.displayName)。\(choice.title)。"
            + "選択肢\(choice.options.count)件。数字キーで回答できます"
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
            // 承認リクエストでは⏎に既定を割り当てない（isEnterDefault と同じ理由）。
            guard let first = choice.options.first,
                  isEnterDefault(first, in: choice)
            else { return .ignored }
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
                .accessibilityLabel("セッション一覧へ戻る")

                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)

                // 送信先セッション選択 (設計書 4.3: 複数ある場合はドロップダウン)
                if let active = coordinator.watcher.activeSession {
                    // ドット自体は装飾。状態は下の送信先ラベルが読み上げる。
                    StateDot(state: active.state, pulsing: active.state.shouldPulse, size: 7)
                }
                // 送信先の候補は「実際に送れるセッション」だけに絞る。
                // 選べるのに送れない相手が並んでいると、書いてから断られることになる。
                let selectable = coordinator.watcher.visibleSessions.filter {
                    $0.info.canSendPrompt
                }
                if selectable.count > 1 {
                    Picker("送信先", selection: activeSessionBinding) {
                        ForEach(selectable) { session in
                            Text("\(session.info.displayName)（\(session.state.displayName)）")
                                .tag(Optional(session.info.tty))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("送信先セッション")
                } else {
                    Text(coordinator.watcher.activeSession?.info.displayName ?? "セッションなし")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("送信先")
                        .accessibilityValue(activeSessionAccessibilityValue)
                }
                Spacer()
                Text("⌘↩ 送信")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Text("Esc で閉じる")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
            }

            ZStack(alignment: .topLeading) {
                if coordinator.inputText.isEmpty {
                    Text("プロンプトを入力…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                TextEditor(text: $coordinator.inputText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(8)
                    .focused($inputFocused)
                    .accessibilityLabel("プロンプト")
                    .accessibilityHint("コマンド・リターンで送信します")
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
                // 設定画面に「Tabで送信先を切り替える」と書かれていたが、
                // SessionWatcher.cycleActiveSession() に呼び出し元が無く未実装だった。
                .onKeyPress(.tab, phases: .down) { _ in
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

            HStack {
                Text(coordinator.watcher.sessions.count > 1
                     ? "⌥↑ / ⌥↓ で送信履歴 ・ Tab で送信先切替"
                     : "⌥↑ / ⌥↓ で送信履歴")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("下書きは送信先ごとに保存されます")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let error = coordinator.lastSendError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if coordinator.watcher.sessions.isEmpty {
                Text("AI CLI が見つかりません。ターミナルで claude / codex / agy を起動してください")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if coordinator.watcher.activeSession?.info.canSendPrompt == false {
                // 入力欄は送れる相手がいるときにしか出さないので、通常ここには来ない。
                // Pickerで送れない相手へ切り替えた場合の保険。
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

    /// 送信先が1件のときの読み上げ内容。状態ドットは装飾なので、状態もここに含める。
    private var activeSessionAccessibilityValue: String {
        guard let active = coordinator.watcher.activeSession else { return "セッションなし" }
        return "\(active.info.displayName)、\(active.state.accessibilityDescription)"
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
    /// 一覧から外すとき（プロセスはそのまま）
    let onHide: () -> Void
    /// CLIごと終了させるとき（確認は呼び出し側で取る）
    let onTerminate: () -> Void

    @State private var isHovering = false
    @State private var isPromptHovering = false
    @State private var isMuteHovering = false
    @State private var isHideHovering = false
    /// このセッションを黙らせているか。
    /// SessionMuteStore は実行中のみの保持で @Observable の変更通知が
    /// このビューまで届かないため、押した結果をここへ写して表示に反映する。
    @State private var isMuted = false

    private var mutedIconOpacity: Double {
        if isMuted { return isMuteHovering ? 0.9 : 0.55 }
        return isMuteHovering ? 0.95 : 0.35
    }

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
                            // tmuxの有無でできることが変わるので、それを明示する。
                            // 「送信可」は既定の状態なので、欠けているときだけ出す。
                            if session.info.capability < .full {
                                TagBadge(
                                    text: session.info.capabilityLabel,
                                    tint: .orange.opacity(0.35)
                                )
                            }
                            if let terminal = session.info.terminalName {
                                TagBadge(text: terminal, tint: .white.opacity(0.18))
                            }
                            Text(elapsedText)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        // 2行目: 直近のユーザー発言
                        if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                            HStack(spacing: 4) {
                                Text("あなた：")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
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
            // 状態はバッジの文字とゴーストの色で示しているが、行全体を1つのボタンとして
            // 読み上げるため、状態・エージェント・経過時間を明示的に組み立てる。
            .accessibilityLabel(rowAccessibilityLabel)
            .accessibilityHint("このセッションのターミナルのタブへ移動します")

            // 送信経路（tmux）が無いセッションでは、押せないボタンを出すより
            // 最初から出さない方が「何ができるか」が伝わる。
            if session.info.canSendPrompt {
                Button(action: onPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(isPromptHovering ? 0.95 : 0.6))
                        .frame(width: 24, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(isPromptHovering ? 0.2 : 0.07))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isPromptHovering = $0 }
                .help("このセッションへプロンプトを送る")
                .accessibilityLabel("\(session.info.displayName) へプロンプトを送る")
            }

            // このセッションだけを黙らせる。設定を開かずに、うるさい1本を素早く止められる。
            Button {
                AppCoordinator.shared.sessionMutes.toggle(session.info)
                isMuted = AppCoordinator.shared.sessionMutes.isMuted(session.info)
            } label: {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(mutedIconOpacity))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(isMuteHovering ? 0.2 : 0.07))
                    )
            }
            .buttonStyle(.plain)
            .onHover { isMuteHovering = $0 }
            .help(isMuted ? "このセッションの知らせを再開する" : "このセッションだけ知らせを止める")
            .accessibilityLabel(
                isMuted
                    ? "\(session.info.displayName) の知らせを再開する"
                    : "\(session.info.displayName) の知らせを止める"
            )

            // 使い終わったセッションを一覧から片付ける。
            // 既定は「隠すだけ」。プロセスの終了は取り消せないので、
            // 誤って作業中のCLIを消さないよう長押し相当のメニューの奥に置く。
            Menu {
                Button("一覧から隠す", action: onHide)
                Divider()
                Button("CLIを終了する…", role: .destructive, action: onTerminate)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHideHovering ? 0.95 : 0.35))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(isHideHovering ? 0.2 : 0.07))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 22)
            .onHover { isHideHovering = $0 }
            .help("このセッションを一覧から片付ける")
            .accessibilityLabel("\(session.info.displayName) を一覧から片付ける")
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
        // 一覧を開き直すたびに、実際のミュート状態へ表示を合わせる
        .onAppear { isMuted = AppCoordinator.shared.sessionMutes.isMuted(session.info) }
    }

    /// 行全体をひとまとまりで読み上げるための文言
    private var rowAccessibilityLabel: String {
        var parts = [
            session.info.profile.displayName,
            session.info.displayName,
            session.state.accessibilityDescription,
        ]
        // 送信ボタンの有無は見た目でしか分からないため、できることを言葉でも伝える
        if session.info.capability < .full {
            parts.append(session.info.capability.summary)
        }
        if isActive { parts.append("現在の送信先") }
        if let prompt = session.lastUserPrompt, !prompt.isEmpty {
            parts.append("直近の指示 \(prompt)")
        }
        if let reply = secondaryText, !reply.isEmpty { parts.append("応答 \(reply)") }
        parts.append("最終更新 \(elapsedText)")
        return parts.joined(separator: "、")
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
        if let line = session.preview.first(where: { !$0.isEmpty }) {
            return AppearancePreferences.maskedPreview(line)
        }
        if let reply = session.lastReply, !reply.isEmpty {
            return AppearancePreferences.maskedPreview(reply)
        }
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
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(entry.summary.isEmpty ? entry.agentName : entry.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 終了済みでも内容は読めるべきなので、選択とコピーを許可する。
                        .textSelection(.enabled)
                }

                Text(hasLiveSession ? "開く" : "終了済み")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(hasLiveSession ? 0.75 : 0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(entry.isRead ? 0.04 : 0.09))
            )
        }
        .buttonStyle(.plain)
        // 以前は .disabled(!hasLiveSession) で行全体を無効化しており、
        // 終了済みセッションの本文を読むことも選択することもできなかった。
        // 移動できないことは「終了済み」表示とヒントで伝え、閲覧は妨げない。
        .allowsHitTesting(hasLiveSession)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(hasLiveSession
                           ? "ターミナルのタブへ移動します"
                           : "このセッションは終了しているため移動できません")
    }

    private var accessibilityLabel: String {
        var parts = [entry.kind.displayName, entry.agentName, entry.sessionName]
        if !entry.summary.isEmpty { parts.append(entry.summary) }
        if !entry.isRead { parts.append("未読") }
        if !hasLiveSession { parts.append("終了済み") }
        return parts.joined(separator: "、")
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
                        .foregroundStyle(.white.opacity(0.6))
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
        // 肯定/否定を緑・赤で塗り分けているが、色だけでは伝わらないため言葉でも示す。
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("キー \(option.keystroke.uppercased()) でも選べます")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var parts = ["\(option.number > 0 ? "選択肢\(option.number)、" : "")\(option.label)"]
        if option.isAffirmative { parts.append("肯定の選択肢") }
        if option.isNegative { parts.append("否定の選択肢") }
        if isMultiSelect { parts.append(isSelected ? "チェック済み" : "未チェック") }
        if isDefault { parts.append("リターンキーの既定") }
        return parts.joined(separator: "、")
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

    /// 「視差効果を減らす」が有効なら点滅させない。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// 点滅を止めている間も「注意が必要」と分かるよう、リングで強調する。
    private var shouldPulse: Bool { pulsing && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .phaseAnimator([1.0, 0.35]) { view, phase in
                view.opacity(shouldPulse ? phase : 1)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
            .overlay {
                if pulsing, reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: max(1, size * 0.18))
                        .padding(-max(1.5, size * 0.28))
                }
            }
            .shadow(color: color.opacity(0.7), radius: shouldPulse ? 4 : 2)
            // 単独では意味を持たないため、既定では装飾扱い。
            // 状態を伝える必要がある箇所では呼び出し側がラベルを付ける。
            .accessibilityHidden(true)
    }
}


// MARK: - 使用量の表示

/// レート制限の消費率を "5h 68% 48m | 7d 40% 6h48m" の形で出す
struct UsageBadge: View {
    let usage: UsageStats
    /// 黒いノッチ面の上に置く場合は true。
    /// ポップオーバーのような明るい背景では、白のハードコードでは読めなくなるため
    /// システム色へ切り替える。（以前は colorScheme を切り替えていたが、
    /// `.white` は colorScheme に反応しないため明背景でほぼ不可視だった）
    var onDarkBackground = true

    private var labelColor: Color {
        onDarkBackground ? .white.opacity(0.7) : .secondary
    }

    private var mutedColor: Color {
        onDarkBackground ? .white.opacity(0.6) : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            // どのCLIの使用量かを、そのAIアプリの公式アイコンで示す（左）
            AgentBadgeIcon(agentID: usage.agentID, size: 14)
            if let window = usage.fiveHour {
                windowView(label: "5h", window: window)
            }
            if usage.fiveHour != nil, usage.sevenDay != nil {
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(onDarkBackground ? .white.opacity(0.45) : .secondary)
                    .accessibilityHidden(true)
            }
            if let window = usage.sevenDay {
                windowView(label: "7d", window: window)
            }
        }
        .help("\(agentLabel) のレート制限の消費率と、リセットまでの残り時間")
        // 「5h 68% 48m」は目で拾う前提の圧縮表記なので、読み上げは言葉に開く。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agentLabel) の使用量")
        .accessibilityValue(usageAccessibilityValue)
    }

    private var usageAccessibilityValue: String {
        var parts: [String] = []
        if let window = usage.fiveHour { parts.append(describe("5時間枠", window)) }
        if let window = usage.sevenDay { parts.append(describe("7日枠", window)) }
        return parts.isEmpty ? "取得できていません" : parts.joined(separator: "、")
    }

    private func describe(_ name: String, _ window: UsageWindow) -> String {
        var text = "\(name) \(Int(window.usedPercent.rounded()))パーセント使用"
        if window.isCritical { text += "、残りわずか" }
        else if window.isWarning { text += "、警告" }
        if let remaining = window.remainingText() { text += "、リセットまで \(remaining)" }
        return text
    }

    private func windowView(label: String, window: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(labelColor)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(for: window))
            if let remaining = window.remainingText() {
                Text(remaining)
                    .font(.system(size: 10))
                    .foregroundStyle(mutedColor)
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
                    UsageBadge(usage: usage, onDarkBackground: false)
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
