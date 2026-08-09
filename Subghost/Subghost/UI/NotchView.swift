//
//  NotchView.swift
//  Subghost
//
//  設計書 6. UI/UX仕様（コンパクト / 通知 / セッション一覧 / 履歴）
//
//  ノッチパネルの中身を描くSwiftUIビュー一式。
//  AppCoordinator.displayMode に従って、状態ドットだけのコンパクト表示から、
//  完了通知・セッション一覧・履歴・初回案内を切り替える。
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
    @State private var showAllUsage = false
    /// 黒いノッチ面の内側に表示する内容。輪郭の変形と時間差を付ける。
    @State private var renderedMode: NotchMode = .compact
    /// 0が物理ノッチ寸法、1が展開寸法。常に同じ輪郭を変形させる。
    @State private var morphProgress: CGFloat = 0
    @State private var contentOpacity: Double = 1
    /// 短時間に開閉が反転した場合、古い遅延処理を無効化する。
    @State private var transitionID = UUID()
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
        case .sessions: sessionsContent
        case .activity: activityContent
        case .onboarding: onboardingContent
        case .sleep: sleepContent
        }
    }

    private func contentWidth(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .compact: return notchWidth + NotchLayout.sideWidth * 2
        case .notification: return max(notchWidth + 280, 620)
        case .sessions: return max(notchWidth + 420, 760)
        case .activity: return max(notchWidth + 420, 760)
        case .onboarding: return max(notchWidth + 320, 680)
        case .sleep: return max(notchWidth + 300, 660)
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
                if let countdown = coordinator.sleepScheduler.countdown {
                    // まもなく寝ることは、どの表示に切り替わっていても目に入るようにする。
                    HStack(spacing: 2) {
                        Image(systemName: "zzz")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(Int(ceil(countdown.remaining)))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(countdown.isPaused ? Color.gray : Color.purple)
                } else if visible.isEmpty {
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
        // 秒数の数字だけでは何のカウントか伝わらないため、真っ先に読み上げる
        if let countdown = coordinator.sleepScheduler.countdown {
            return "Subghost。\(countdown.label) の完了により、"
                + "あと\(Int(ceil(countdown.remaining)))秒でスリープします"
        }
        guard let active = coordinator.watcher.activeSession else {
            return sessions.isEmpty
                ? "Subghost。AI CLIは実行されていません"
                : "Subghost。\(sessions.count)件のセッションを監視中"
        }

        var text = "Subghost。\(active.info.profile.displayName) "
            + "\(active.info.displayName) は\(active.state.accessibilityDescription)"
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
                Text("\(HotkeyAction.showSessions.shortcutOrName) で一覧")
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

                // ノッチからもすぐ終了できるようにする
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

            sleepReservationBanner

            let visible = coordinator.watcher.visibleSessions
            if !visible.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { session in
                            SessionRow(
                                session: session,
                                isActive: session.info.id == coordinator.watcher.activeSessionName,
                                isSleepReserved: coordinator.sleepScheduler.isReservedSession(
                                    tty: session.info.tty, pid: session.info.pid
                                ),
                                onJump: { coordinator.jump(to: session) },
                                onHide: { coordinator.hideSession(session) },
                                onToggleSleep: { coordinator.toggleSleepReservation(for: session) }
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

    /// 一覧の先頭に出す、スリープ予約の状況。
    ///
    /// 予約したこと自体を忘れると「なぜか勝手に寝る」ようにしか見えない。
    /// 予約がある間は常にここへ出し、その場で解除できるようにする。
    @ViewBuilder
    private var sleepReservationBanner: some View {
        let scheduler = coordinator.sleepScheduler
        if let countdown = scheduler.countdown {
            sleepBannerFrame {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(countdown.label) の完了により、あと \(Int(ceil(countdown.remaining))) 秒でスリープします")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    if let hold = countdown.holdMessage {
                        Text(hold)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                }
                Spacer(minLength: 6)
                Button("取り消す") { coordinator.cancelSleepCountdown() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if scheduler.isReserved {
            sleepBannerFrame {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.purple.opacity(0.9))
                // 複数を予約しているときは、最後の1つが終わるまで待つことを明示する
                Text(scheduler.reservations.count > 1
                     ? "\(scheduler.reservationLabel) のタスクがすべて終わったらスリープします"
                     : "\(scheduler.reservationLabel) のタスクが終わったらスリープします")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button("解除") { coordinator.cancelAllSleepReservations() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func sleepBannerFrame<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.22)))
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
                    Text("完了とエラーがここに表示されます")
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
                    .accessibilityIdentifier("onboarding.title")
                Text("ノッチにAI CLIのタスクが作業途中か完了したかを表示します。"
                     + "最初にフック連携を確認しましょう。")
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
                Text("完了通知")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("作業中に別のアプリを使っていても、タスクが終了したことを通知できます。通知本文は初期設定では非表示です。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.green)
                    Button("通知を有効にする") { coordinator.requestNotificationPermission() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                if let message = coordinator.onboardingNotificationMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Text("SubghostはCLIへの入力を一切送信しません。")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .done:
            VStack(alignment: .leading, spacing: 6) {
                Text("準備ができました")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("ノッチまたはメニューバーのゴーストアイコンから、いつでも設定を開けます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(HotkeyAction.showSessions.shortcutOrName) でセッション一覧を開閉できます。")
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

    // MARK: - 展開（スリープ）：まもなく寝ることを知らせ、取り消す機会を出す

    /// スリープは取り消せない操作なので、この画面の主役は残り時間と取り消しボタン。
    /// 「何が終わったから寝るのか」も併せて出し、身に覚えのない発火に気づけるようにする。
    private var sleepContent: some View {
        let scheduler = coordinator.sleepScheduler
        let countdown = scheduler.countdown

        return VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: topInset)   // ノッチ本体を避ける

            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.purple)
                Text("まもなくスリープします")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let countdown {
                    Text("\(Int(ceil(countdown.remaining))) 秒")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(countdown.isPaused ? .white.opacity(0.5) : .white)
                }
            }

            if let countdown {
                // 複数を予約していた場合は「すべて終わった」ことを明示する
                Text(countdown.completionText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(
                    value: min(max(countdown.remaining, 0), SleepPreferences.countdown),
                    total: SleepPreferences.countdown
                )
                .tint(countdown.isPaused ? Color.gray : Color.purple)

                if let hold = countdown.holdMessage {
                    Label(hold, systemImage: "pause.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.9))
                }
            } else if let message = scheduler.statusMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    coordinator.cancelSleepCountdown()
                } label: {
                    Text("取り消す")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityHint("スリープをやめます。予約は残るので、次に完了したとき改めて確認します")

                Button {
                    coordinator.cancelAllSleepReservations()
                } label: {
                    Text("予約も解除")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityHint("スリープをやめ、この予約自体を取り消します")

                Spacer()

                Button {
                    coordinator.sleepImmediately()
                } label: {
                    Label("今すぐスリープ", systemImage: "moon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(countdown == nil)
            }

            Text("Esc でも取り消せます")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { coordinator.cancelSleepCountdown() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sleepAccessibilityLabel)
    }

    private var sleepAccessibilityLabel: String {
        guard let countdown = coordinator.sleepScheduler.countdown else {
            return coordinator.sleepScheduler.statusMessage ?? "スリープの予定はありません"
        }
        var text = "\(countdown.completionText)。"
            + "あと\(Int(ceil(countdown.remaining)))秒でスリープします"
        if let hold = countdown.holdMessage { text += "。\(hold)" }
        return text
    }

}

// MARK: - セッション一覧の1行

struct SessionRow: View {
    let session: MonitoredSession
    /// 一覧で選択中のセッションか
    let isActive: Bool
    /// このセッションの完了でスリープする予約が入っているか
    let isSleepReserved: Bool
    /// 行本体を押したとき（そのタブへ移動）
    let onJump: () -> Void
    /// 一覧から外すとき（プロセスはそのまま）
    let onHide: () -> Void
    /// 完了後スリープの予約を入り切りするとき
    let onToggleSleep: () -> Void

    @State private var isHovering = false
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
        // 行全体の移動ボタンと、右側の補助操作を分けて配置する
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
                            if !session.info.isMonitorable {
                                TagBadge(
                                    text: session.info.capabilityLabel,
                                    tint: .orange.opacity(0.35)
                                )
                            }
                            if let terminal = session.info.terminalName {
                                TagBadge(text: terminal, tint: .white.opacity(0.18))
                            }
                            // 予約中であることは行を見た時点で分かるようにする
                            if isSleepReserved {
                                TagBadge(text: "完了後スリープ", tint: .purple.opacity(0.45))
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
            // 監視専用なので、CLIプロセスそのものは操作しない。
            Menu {
                Button("一覧から隠す", action: onHide)
                Button(
                    isSleepReserved
                        ? "完了後のスリープ予約を解除"
                        : "このタスクが終わったらMacをスリープ",
                    action: onToggleSleep
                )
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
        if !session.info.isMonitorable {
            parts.append(session.info.capability.summary)
        }
        if isActive { parts.append("選択中") }
        if isSleepReserved { parts.append("完了後にスリープを予約中") }
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
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .completed: return .green
        case .error: return .red
        }
    }
}

// MARK: - 状態ドット (設計書 4.1: グレー/青パルス/緑/赤)

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
