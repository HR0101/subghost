//
//  SubghostApp.swift
//  Subghost
//
//  Ghostty補助ノッチAIアシスタント
//

import SwiftUI

@main
struct SubghostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // メニューバーには何も置かない。操作の入口はノッチUIに集約する。
    // Settings シーンだけを持つことで、SettingsLink から設定を開ける。
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()

        // DockやFinderから「ダブルクリックで起動できる普通のアプリ」として扱わせつつ、
        // 起動が終わったらDockアイコン（実行中インジケータ含む）を消し、
        // 常駐中は従来どおりノッチUIだけを操作の入口にする。
        // (Info.plistのLSUIElementをNOにして常時 .regular 起動させ、ここで .accessory へ落とす)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.hotkey.unregister()
        AppCoordinator.shared.watcher.stop()
        // 待たせているフック接続を解放してから終了する（CLIを止めたままにしない）
        AppCoordinator.shared.watcher.stopHookServer()
    }
}
