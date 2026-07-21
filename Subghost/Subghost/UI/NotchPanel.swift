//
//  NotchPanel.swift
//  Subghost
//
//  設計書 6.1: ノッチオーバーレイ（NSPanel .nonactivatingPanel / .borderless）
//

import AppKit
import CoreGraphics
import SwiftUI

// MARK: - NSScreen との橋渡し

extension NSScreen {

    /// CoreGraphicsのディスプレイID
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 再接続・再起動をまたいで安定する識別子。
    /// ディスプレイUUIDを使い、取得できない場合のみ表示名で代用する。
    var stableIdentifier: String {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String?
        else { return localizedName }
        return text
    }

    /// 物理的なノッチを持つか
    var hasPhysicalNotch: Bool { safeAreaInsets.top > 0 }

    var descriptor: ScreenDescriptor {
        ScreenDescriptor(
            id: stableIdentifier,
            name: localizedName,
            hasNotch: hasPhysicalNotch,
            // 主ディスプレイは CGMainDisplayID で判定する。
            // NSScreen.main は「フォーカスされている画面」であり主ディスプレイではない。
            isPrimary: displayID == CGMainDisplayID(),
            isActive: self == NSScreen.main
        )
    }

    /// 設定で選ばれている表示先の画面
    static func preferredNotchScreen(
        preference: DisplayPreference = .current
    ) -> NSScreen? {
        let screens = NSScreen.screens
        guard let chosen = DisplaySelector.select(
            from: screens.map(\.descriptor), preference: preference)
        else { return nil }

        if UserDefaults.standard.bool(forKey: "logDisplaySelection") {
            let detail = screens.map {
                "\($0.localizedName)[notch=\($0.hasPhysicalNotch) main=\($0 == NSScreen.main) safeTop=\($0.safeAreaInsets.top)]"
            }.joined(separator: " / ")
            NSLog("Subghost[display] 設定=\(preference) 画面=\(detail) 選択=\(chosen.name)")
        }

        return screens.first { $0.stableIdentifier == chosen.id }
    }
}

// MARK: - ノッチ位置の算出

struct NotchMetrics: Equatable {
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchWidth: CGFloat
    let topInset: CGFloat   // ノッチ高さ（非搭載機はメニューバー相当）
    let topY: CGFloat       // パネル上端のy座標

    /// ノッチ非搭載画面で使う擬似ノッチの幅（実機のノッチ幅に合わせている）
    static let pseudoNotchWidth: CGFloat = 190
    /// メニューバー高さを測れなかった場合の既定値
    static let fallbackMenuBarHeight: CGFloat = 24

    static func compute() -> NotchMetrics {
        // 設定で指定された画面を使う。未指定ならノッチ搭載画面→メインの順 (設計書 6.1)
        guard let screen = NSScreen.preferredNotchScreen() else {
            return NotchMetrics(
                screenFrame: .zero, hasNotch: false,
                notchWidth: pseudoNotchWidth, topInset: fallbackMenuBarHeight, topY: 0)
        }

        return make(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryWidths: zip(screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea)
        )
    }

    /// NSScreenに依存しない寸法計算（テスト対象の純粋ロジック）
    ///
    /// 重要: ノッチの有無によらず `topY` は画面の絶対上端（`frame.maxY`）とする。
    /// `visibleFrame.maxY` はメニューバーを除いた領域の上端なので、
    /// それを使うとメニューバーの高さぶん下にずれて表示されてしまう。
    static func make(
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTop: CGFloat,
        auxiliaryWidths: (left: CGFloat, right: CGFloat)?
    ) -> NotchMetrics {
        // 物理ノッチがある画面
        if safeAreaTop > 0, let auxiliaryWidths {
            return NotchMetrics(
                screenFrame: frame,
                hasNotch: true,
                notchWidth: frame.width - auxiliaryWidths.left - auxiliaryWidths.right,
                topInset: safeAreaTop,
                topY: frame.maxY
            )
        }

        // ノッチ非搭載画面：メニューバーに重ねて擬似ノッチを表示する (設計書 12 フォールバック)
        // 高さは決め打ちにせず実測する（外部モニタは30pt、内蔵は32pt など画面ごとに異なる）
        let measured = frame.maxY - visibleFrame.maxY
        let menuBarHeight = measured > 0 ? measured : fallbackMenuBarHeight

        return NotchMetrics(
            screenFrame: frame,
            hasNotch: false,
            notchWidth: pseudoNotchWidth,
            topInset: menuBarHeight,
            topY: frame.maxY
        )
    }
}

/// 2つのオプショナルな矩形から幅の組を作る補助
private func zip(_ left: NSRect?, _ right: NSRect?) -> (left: CGFloat, right: CGFloat)? {
    guard let left, let right else { return nil }
    return (left.width, right.width)
}

// MARK: - パネル

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// macOSはウインドウをメニューバー下に押し下げようとするため、
    /// ノッチ位置（画面最上端）に重ねるには制約を無効化する必要がある
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - コントローラ

final class NotchPanelController {

    private unowned let coordinator: AppCoordinator
    private let panel: NotchPanel
    private(set) var metrics: NotchMetrics
    /// NSPanelの拡大中にSwiftUIから届いた実測高さ。アニメーション完了後に反映する。
    private var pendingMeasuredHeight: CGFloat?
    private var isAnimatingFrame = false
    private var pendingFrameTransition: DispatchWorkItem?
    private var menuBarTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// パネルを画面に出しているか（メニューバー追従で切り替わる）
    private var isVisible = true

    /// パネルのウインドウレベル。
    /// メニューバー(24)・ステータスバー(25)より上に置き、全画面アプリの上にも出せるようにする。
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// パネルの外観・重なり順・入力の設定。
    ///
    /// **設定順序に依存する処理があるため、テストで固定している。**
    /// `isFloatingPanel = true` は副作用として `level` を `.floating`(3) に上書きする。
    /// 先に `level` を指定すると 3 に潰され、メニューバー(24)や全画面アプリより
    /// 下に潜り込んで「表示されない・クリックが通らない」状態になる。
    static func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // クリックを受け取れるようにする（非アクティブのままでも入力は届く）
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        // makeKeyAndOrderFront でキーウインドウにできるようにする。
        // true のままだと入力欄にフォーカスが渡らないことがある。
        panel.becomesKeyOnlyIfNeeded = false
        // 全画面アプリのスペースにも参加させる
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // level は isFloatingPanel より必ず後に設定する（上のコメント参照）
        panel.level = panelLevel
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.metrics = NotchMetrics.compute()

        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        Self.configure(panel)

        let hostingView = NSHostingView(rootView: NotchView(coordinator: coordinator))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        coordinator.notchMetrics = metrics

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        startOutsideClickMonitoring()
    }

    func show() {
        panel.setFrame(frame(for: coordinator.displayMode), display: true)
        panel.orderFrontRegardless()
        startMenuBarTracking()
    }

    // MARK: - メニューバーへの追従 (追補)

    /// メニューバーの表示状態を見張る間隔（秒）
    private static let menuBarPollInterval: TimeInterval = 0.4

    /// 全画面アプリでメニューバーが隠れている画面では、ノッチUIも隠す。
    /// ただし承認待ちなど操作が必要な場合は、内容に重なってでも表示する。
    private func startMenuBarTracking() {
        menuBarTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.menuBarPollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        // メニュー操作中などでも止まらないようにする
        RunLoop.main.add(timer, forMode: .common)
        menuBarTimer = timer
        updateVisibility()
    }

    private func updateVisibility() {
        refreshMetricsIfNeeded()

        let shouldShow = shouldBeVisible()
        guard shouldShow != isVisible else { return }
        isVisible = shouldShow

        if shouldShow {
            panel.setFrame(frame(for: coordinator.displayMode), display: true)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// 表示先や寸法が変わっていたら取り直す。
    ///
    /// 起動直後は `NSScreen.safeAreaInsets` がまだ確定しておらず0を返すことがある。
    /// その瞬間だけを見て一度きりで決めると「ノッチ無し」と誤判定し、
    /// 画面構成が変わるまで誤った画面に出続けてしまう。
    /// 定期的に計算し直して自己修復する。
    private func refreshMetricsIfNeeded() {
        let fresh = NotchMetrics.compute()
        guard fresh != metrics else { return }
        metrics = fresh
        coordinator.notchMetrics = fresh
        panel.setFrame(frame(for: coordinator.displayMode), display: true)
    }

    private func shouldBeVisible() -> Bool {
        // 応答待ちや入力中は、全画面アプリの上でも見せる必要がある
        guard coordinator.displayMode == .compact else { return true }
        if NotchPreferences.hideWhenNoSessions, coordinator.watcher.sessions.isEmpty {
            return false
        }
        guard NotchPreferences.hideInFullScreen else { return true }
        guard let screen = NSScreen.preferredNotchScreen() else { return false }
        return MenuBarVisibility.shouldShowNotch(on: screen)
    }

    /// 設定変更を、次回の定期監視を待たずに表示へ反映する。
    func preferencesChanged() {
        isVisible = !shouldBeVisible()
        updateVisibility()
        modeChanged()
    }

    // MARK: - 外側クリックで収納

    private func startOutsideClickMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeForOutsideClickIfNeeded()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self, event.windowNumber != self.panel.windowNumber {
                self.closeForOutsideClickIfNeeded()
            }
            return event
        }
    }

    private func closeForOutsideClickIfNeeded() {
        guard coordinator.canCloseOnOutsideClick else { return }
        coordinator.dismissExpandedPanel()
    }

    /// モード変更時のパネルフレーム更新。
    ///
    /// NSPanel自体をアニメーションすると「ノッチとは別のウインドウが現れる」見た目になる。
    /// 展開時は透明な表示領域だけを先に確保し、黒いノッチ形状の変形はSwiftUIへ任せる。
    /// 収納時は形状がノッチへ戻り終えてから、透明な表示領域を小さくする。
    func modeChanged() {
        // 承認待ちなどで展開する場合は、隠れていても即座に出す
        updateVisibility()

        let target = frame(for: coordinator.displayMode)
        let current = panel.frame
        let needsLargerCanvas = target.width * target.height >= current.width * current.height
        let isCollapsingToNotch = coordinator.displayMode == .compact

        pendingFrameTransition?.cancel()
        pendingFrameTransition = nil

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = isCollapsingToNotch
            ? NotchLayout.collapseAnimationDuration
            : NotchPreferences.expansionAnimationDuration

        // setFrameによるホスティングビューの再レイアウトでも高さ通知が来るため、
        // キャンバスを広げる前から実測値を保留する。
        isAnimatingFrame = !reduceMotion

        // 展開先の透明なキャンバスは先に用意する。黒い面はNotchView内で変形する。
        if needsLargerCanvas || reduceMotion {
            panel.setFrame(target, display: true)
        }

        guard !reduceMotion else {
            isAnimatingFrame = false
            applyPendingMeasuredHeightIfNeeded()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 収納時だけ、黒い面が小さくなった後でウインドウ領域を合わせる。
            if !needsLargerCanvas {
                self.panel.setFrame(
                    self.frame(for: self.coordinator.displayMode),
                    display: true
                )
            }
            self.isAnimatingFrame = false
            self.applyPendingMeasuredHeightIfNeeded()
        }
        pendingFrameTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func applyPendingMeasuredHeightIfNeeded() {
        guard let height = pendingMeasuredHeight else { return }
        pendingMeasuredHeight = nil
        applyMeasuredHeight(height)
    }

    // MARK: - キーボードフォーカス (設計書 4.3)

    func focusInput() {
        // 常駐アプリ(LSUIElement)かつ非アクティブ化パネルのため、
        // アプリ自体をアクティブにしないとキーボード入力が前面のアプリへ行ってしまう。
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func resignInput() {
        guard panel.isKeyWindow else { return }
        // 一旦orderOutして直前のアプリへキーボードフォーカスを返す
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        // 入力を終えたら元のアプリへ操作を戻す
        NSApp.deactivate()
    }

    /// SwiftUIのonHoverは、ビュー差し替えやウインドウの拡大中にも一時的な
    /// mouseExitedを送ることがある。実際の画面座標でパネル内かを確認する。
    func containsCurrentMouseLocation() -> Bool {
        guard isVisible, panel.isVisible else { return false }
        // NSPanel.frameをアニメーション中に繰り返し読むと、AppKitの暗黙フレーム
        // アニメーションが現在値へ同期され、拡大が瞬時に完了して見えることがある。
        // 表示モードから算出した「展開後の予定領域」で判定し、描画には触れない。
        let hoverFrame = frame(for: coordinator.displayMode)
        // 境界上の丸め誤差で内外を往復しないよう、わずかな余裕を持たせる。
        return hoverFrame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
    }

    // MARK: - フレーム計算

    private func frame(for mode: NotchMode) -> NSRect {
        let size: NSSize
        switch mode {
        case .compact:
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: metrics.notchWidth + NotchLayout.sideWidth * 2
                ),
                height: metrics.topInset
            )
        case .notification:
            // 応答の行数に応じて高さを変える（長文も読めるように）
            let lines = coordinator.notificationSession?.preview.count ?? 0
            let height = metrics.topInset + 110 + CGFloat(min(lines, 12)) * 17
            size = NSSize(width: NotchLayout.canvasWidth(
                for: max(metrics.notchWidth + 280, 620)),
                          height: min(max(height, 200), 380))
        case .input:
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: max(metrics.notchWidth + 280, 640)
                ),
                height: 340
            )
        case .sessions:
            // 一覧は最大高を超えた分だけ内部スクロールする。
            let listHeight = NotchLayout.sessionsListHeight(
                count: coordinator.watcher.sessions.count
            )
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: max(metrics.notchWidth + 420, 760)
                ),
                height: min(metrics.topInset + 120 + listHeight, 520))
        case .activity:
            let listHeight = min(
                CGFloat(coordinator.activity.entries.count) * 66,
                NotchLayout.sessionsListMaxHeight
            )
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: max(metrics.notchWidth + 420, 760)
                ),
                height: min(metrics.topInset + 90 + max(listHeight, 150), 520)
            )
        case .choice:
            // 選択肢の数と文脈行数で高さが変わるため実データから見積もる
            let choice = coordinator.pendingChoice
            let optionCount = choice?.options.count ?? 2
            let detailCount = choice?.detail.count ?? 0
            let estimated = metrics.topInset + 120
                + CGFloat(detailCount) * 16
                + CGFloat(optionCount) * 38
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: max(metrics.notchWidth + 320, 680)
                ),
                height: min(estimated, 480)
            )
        case .onboarding:
            // 「フック連携」ステップだけ対象CLI数ぶん行が増える。他のステップは短い固定文言。
            let extraRows = coordinator.onboardingStep == .hooks ? HookTarget.allCases.count : 0
            size = NSSize(
                width: NotchLayout.canvasWidth(
                    for: max(metrics.notchWidth + 320, 680)
                ),
                height: metrics.topInset + 150 + CGFloat(extraRows) * 40
            )
        }
        return NSRect(
            x: metrics.screenFrame.midX - size.width / 2,
            y: metrics.topY - size.height,
            width: size.width,
            height: size.height
        )
    }

    @objc private func screensChanged() {
        relayout()
    }

    /// SwiftUIが実際に描画した高さへパネルを合わせる。
    ///
    /// 高さを見積もりで決めると、描画された内容より下に透明な余白ができる。
    /// パネルは透明部分でもマウスイベントを受け取るため、そこが「見えない当たり判定」になり
    /// 下のアプリやメニューバーへのクリックを奪ってしまう。
    func adjustHeight(to contentHeight: CGFloat, for measuredMode: NotchMode) {
        guard contentHeight > 0 else { return }
        // 内容は輪郭より遅れて差し替える。古いモードの高さで
        // 展開先キャンバスを縮めないよう、現在の表示モードと対応する実測値だけ使う。
        guard measuredMode == coordinator.displayMode else { return }
        let target = ceil(contentHeight)
        if isAnimatingFrame {
            if measuredMode == .compact {
                // 収納中は黒い面が縮み終わるまで大きな透明領域を維持する。
                pendingMeasuredHeight = target
            } else {
                // 展開中は内容がフェードインする前に最終高が分かる。
                // ここでキャンバスを合わせ、展開完了後の二段階の縮小を防ぐ。
                pendingMeasuredHeight = nil
                applyMeasuredHeight(target)
            }
            return
        }
        applyMeasuredHeight(target)
    }

    private func applyMeasuredHeight(_ target: CGFloat) {
        // 1pt以内の誤差で作り直すと再測定と往復してしまうため許容する
        guard abs(panel.frame.height - target) > 1 else { return }

        var frame = panel.frame
        frame.size.height = target
        frame.origin.y = metrics.topY - target
        panel.setFrame(frame, display: true)
    }

    /// 表示先の画面や画面構成が変わったときに、寸法と位置を取り直す
    func relayout() {
        metrics = NotchMetrics.compute()
        coordinator.notchMetrics = metrics
        panel.setFrame(frame(for: coordinator.displayMode), display: true)
        // 表示先を変えた直後は、その画面のメニューバー状態で出し入れを決め直す
        isVisible = !shouldBeVisible()
        updateVisibility()
    }

    deinit {
        menuBarTimer?.invalidate()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }
}

/// レイアウト定数（パネルとSwiftUIビューで共有）
enum NotchLayout {
    static let sideWidth: CGFloat = 44      // コンパクト時、ノッチ左右のアイコン領域幅
    static let compactCornerRadius: CGFloat = 12
    static let cornerRadius: CGFloat = 28   // 展開時の緩やかな下角丸
    /// 四分円に近い、側面と底面の接線が連続するベジェ制御係数。
    static let cornerBezierControl: CGFloat = 0.447715
    static let topShoulderWidth: CGFloat = 12 // 画面上端とつなぐ外向きのカーブ
    static let collapseAnimationDuration: TimeInterval = 0.32
    /// セッションが増えてもノッチが画面下まで伸びないよう、一覧部分だけを制限する。
    static let sessionRowEstimatedHeight: CGFloat = 68
    static let sessionsListMaxHeight: CGFloat = 330

    static func sessionsListHeight(count: Int) -> CGFloat {
        min(CGFloat(max(count, 0)) * sessionRowEstimatedHeight, sessionsListMaxHeight)
    }

    static func canvasWidth(for surfaceWidth: CGFloat) -> CGFloat {
        surfaceWidth + topShoulderWidth * 2
    }
}
