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
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.hotkey.unregister()
        AppCoordinator.shared.watcher.stop()
        // 待たせているフック接続を解放してから終了する（CLIを止めたままにしない）
        AppCoordinator.shared.watcher.stopHookServer()
    }
}
