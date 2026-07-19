//
//  NotchPanel.swift
//  Subghost
//
//  設計書 6.1: ノッチオーバーレイ（NSPanel .nonactivatingPanel / .borderless）
//

import AppKit
import SwiftUI

// MARK: - ノッチ位置の算出

struct NotchMetrics {
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchWidth: CGFloat
    let topInset: CGFloat   // ノッチ高さ（非搭載機はメニューバー相当）
    let topY: CGFloat       // パネル上端のy座標

    static func compute() -> NotchMetrics {
        // ノッチ搭載スクリーンを優先 (設計書 6.1: safeAreaInsets / auxiliaryTopArea)
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return NotchMetrics(screenFrame: .zero, hasNotch: false, notchWidth: 190, topInset: 34, topY: 0)
        }

        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(
                screenFrame: screen.frame,
                hasNotch: true,
                notchWidth: screen.frame.width - left.width - right.width,
                topInset: safeTop,
                topY: screen.frame.maxY
            )
        }

        // ノッチ非搭載機：メニューバー直下に擬似ノッチ表示 (設計書 12 フォールバック)
        return NotchMetrics(
            screenFrame: screen.frame,
            hasNotch: false,
            notchWidth: 190,
            topInset: 34,
            topY: screen.visibleFrame.maxY
        )
    }
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

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.metrics = NotchMetrics.compute()

        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

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
    }

    /// モード変更時のパネルフレーム更新。
    /// 拡大は即時、縮小はSwiftUIの折りたたみアニメーション後に行う。
    func modeChanged() {
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
        panel.makeKeyAndOrderFront(nil)
    }

    func resignInput() {
        guard panel.isKeyWindow else { return }
        // 一旦orderOutして直前のアプリへキーボードフォーカスを返す
        panel.orderOut(nil)
        panel.orderFrontRegardless()
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
            size = NSSize(width: max(metrics.notchWidth + 220, 560), height: 230)
        case .input:
            size = NSSize(width: max(metrics.notchWidth + 280, 640), height: 260)
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
        metrics = NotchMetrics.compute()
        coordinator.notchMetrics = metrics
        panel.setFrame(frame(for: coordinator.displayMode), display: true)
    }
}

/// レイアウト定数（パネルとSwiftUIビューで共有）
enum NotchLayout {
    static let sideWidth: CGFloat = 44      // コンパクト時、ノッチ左右のアイコン領域幅
    static let cornerRadius: CGFloat = 18   // 展開時の下角丸
}
