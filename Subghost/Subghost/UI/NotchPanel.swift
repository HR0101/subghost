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
            isMain: self == NSScreen.main
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
    private var pendingShrink: DispatchWorkItem?
    private var menuBarTimer: Timer?
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
        guard let screen = NSScreen.preferredNotchScreen() else { return false }
        return MenuBarVisibility.shouldShowNotch(on: screen)
    }

    /// モード変更時のパネルフレーム更新。
    /// 拡大は即時、縮小はSwiftUIの折りたたみアニメーション後に行う。
    func modeChanged() {
        // 承認待ちなどで展開する場合は、隠れていても即座に出す
        updateVisibility()

        let target = frame(for: coordinator.displayMode)
        pendingShrink?.cancel()
        pendingShrink = nil

        let current = panel.frame
        if target.width >= current.width && target.height >= current.height {
            panel.setFrame(target, display: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.panel.setFrame(self.frame(for: self.coordinator.displayMode), display: true)
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
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

    // MARK: - フレーム計算

    private func frame(for mode: NotchMode) -> NSRect {
        let size: NSSize
        switch mode {
        case .compact:
            size = NSSize(
                width: metrics.notchWidth + NotchLayout.sideWidth * 2,
                height: metrics.topInset
            )
        case .notification:
            // 応答の行数に応じて高さを変える（長文も読めるように）
            let lines = coordinator.notificationSession?.preview.count ?? 0
            let height = metrics.topInset + 110 + CGFloat(min(lines, 12)) * 17
            size = NSSize(width: max(metrics.notchWidth + 280, 620),
                          height: min(max(height, 200), 380))
        case .input:
            size = NSSize(width: max(metrics.notchWidth + 280, 640), height: 260)
        case .sessions:
            // 行数に応じて高さを変える
            let count = max(coordinator.watcher.sessions.count, 1)
            size = NSSize(
                width: max(metrics.notchWidth + 320, 660),
                height: min(metrics.topInset + 70 + CGFloat(count) * 38, 460))
        case .choice:
            // 選択肢の数と文脈行数で高さが変わるため実データから見積もる
            let choice = coordinator.pendingChoice
            let optionCount = choice?.options.count ?? 2
            let detailCount = choice?.detail.count ?? 0
            let estimated = metrics.topInset + 120
                + CGFloat(detailCount) * 16
                + CGFloat(optionCount) * 38
            size = NSSize(
                width: max(metrics.notchWidth + 320, 680),
                height: min(estimated, 480)
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
    }
}

/// レイアウト定数（パネルとSwiftUIビューで共有）
enum NotchLayout {
    static let sideWidth: CGFloat = 44      // コンパクト時、ノッチ左右のアイコン領域幅
    static let cornerRadius: CGFloat = 18   // 展開時の下角丸
}
