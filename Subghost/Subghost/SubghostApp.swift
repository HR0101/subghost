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

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: .shared)
        } label: {
            MenuBarLabel(coordinator: .shared)
        }

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
