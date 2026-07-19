//
//  MenuBarVisibility.swift
//  Subghost
//
//  設計書 追補: メニューバーが出ている画面にだけノッチUIを表示する
//
//  全画面表示のアプリがある画面ではメニューバーが隠れる。
//  そこにノッチUIを出し続けると、アプリの内容に重なってしまう。
//
//  判定方法:
//  `NSScreen.visibleFrame` は全画面時も変化しない（実測で確認）ため使えない。
//  代わりにウインドウ一覧からメニューバーのウインドウを探し、
//  対象画面の上端にあるかを見る。
//
//  ウインドウ「名前」は画面収録の権限が必要になるため参照しない。
//  レイヤー・大きさ・位置だけで判定する。
//

import AppKit
import CoreGraphics

nonisolated enum MenuBarVisibility {

    /// メニューバーのウインドウレイヤー（kCGMainMenuWindowLevel）
    static let menuBarLayer = 24
    /// メニューバーとみなす高さの範囲。全画面オーバーレイ等を除外する。
    static let heightRange: ClosedRange<CGFloat> = 10...60
    /// 上端が一致しているとみなす許容差
    static let topTolerance: CGFloat = 2

    /// 判定に必要なウインドウ情報だけを抜き出したもの
    nonisolated struct WindowSummary: Sendable, Equatable {
        let layer: Int
        /// CoreGraphics座標（原点はメインディスプレイの左上、y軸は下向き）
        let bounds: CGRect
    }

    // MARK: - 純粋ロジック（テスト対象）

    /// 1つのウインドウが、指定画面のメニューバーかどうか
    static func isMenuBar(_ window: WindowSummary, onScreen screenBounds: CGRect) -> Bool {
        guard window.layer == menuBarLayer else { return false }
        // 全画面のオーバーレイ（画面全体を覆うレイヤー24のウインドウ）を除く
        guard heightRange.contains(window.bounds.height) else { return false }
        // 画面の上端に接していること
        guard abs(window.bounds.minY - screenBounds.minY) <= topTolerance else { return false }
        // 横方向に十分重なっていること（別画面のメニューバーを拾わない）
        let overlap = min(window.bounds.maxX, screenBounds.maxX)
            - max(window.bounds.minX, screenBounds.minX)
        return overlap > screenBounds.width / 2
    }

    /// 指定画面にメニューバーが出ているか
    static func isMenuBarVisible(
        windows: [WindowSummary],
        onScreen screenBounds: CGRect
    ) -> Bool {
        guard !screenBounds.isEmpty else { return false }
        return windows.contains { isMenuBar($0, onScreen: screenBounds) }
    }

    /// 全画面ウインドウとみなす横方向の被覆率
    static let fullScreenCoverageRatio: CGFloat = 0.9

    /// その画面が全画面表示のアプリに覆われているか
    ///
    /// 通常のウインドウはメニューバーより上に配置できないため、
    /// 「画面の上端に接していて幅をほぼ覆う通常ウインドウ」は全画面スペースとみなせる。
    static func isCoveredByFullScreenWindow(
        windows: [WindowSummary],
        onScreen screenBounds: CGRect
    ) -> Bool {
        guard !screenBounds.isEmpty else { return false }
        return windows.contains { window in
            guard window.layer == 0 else { return false }
            guard abs(window.bounds.minY - screenBounds.minY) <= topTolerance else { return false }
            let overlap = min(window.bounds.maxX, screenBounds.maxX)
                - max(window.bounds.minX, screenBounds.minX)
            return overlap >= screenBounds.width * fullScreenCoverageRatio
        }
    }

    /// その画面にノッチUIを出してよいか
    ///
    /// メニューバーが隠れているだけでは隠さない。メニューバーはフォーカスされた画面にしか
    /// 描画されないため、それを条件にすると「別の画面で全画面アプリを使っている間、
    /// 対象画面のノッチまで消える」ことになるため。
    ///
    /// 隠すのは「対象画面自身が全画面アプリに覆われていて、かつメニューバーも出ていない」場合に限る。
    /// 全画面中にマウスを上端へ運んでメニューバーが現れたときは、それに合わせて表示する。
    static func shouldShowNotch(
        windows: [WindowSummary],
        onScreen screenBounds: CGRect
    ) -> Bool {
        if isMenuBarVisible(windows: windows, onScreen: screenBounds) { return true }
        return !isCoveredByFullScreenWindow(windows: windows, onScreen: screenBounds)
    }

    // MARK: - 実際のウインドウ一覧を使う版

    /// 現在表示中のウインドウ一覧を取得する
    static func currentWindows() -> [WindowSummary] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let layer = entry["kCGWindowLayer"] as? Int,
                  let boundsDict = entry["kCGWindowBounds"] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let width = boundsDict["Width"], let height = boundsDict["Height"]
            else { return nil }
            return WindowSummary(
                layer: layer,
                bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// その画面にノッチUIを出してよいか（実データ版）
    @MainActor
    static func shouldShowNotch(on screen: NSScreen) -> Bool {
        // 画面IDが取れない異常系では、消えてしまうより出しておくほうが安全
        guard let displayID = screen.displayID else { return true }
        return shouldShowNotch(
            windows: currentWindows(),
            onScreen: CGDisplayBounds(displayID))
    }
}
