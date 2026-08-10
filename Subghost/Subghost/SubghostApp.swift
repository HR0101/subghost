//
//  SubghostApp.swift
//  Subghost
//
//  Ghostty補助ノッチAIアシスタント
//
//  アプリの入口。@main の App 本体と AppDelegate だけを持つ。
//  ノッチを見失った場合の復旧導線として、最小限のメニューバー項目も提供する。
//

import SwiftUI

@main
struct SubghostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Subghost", systemImage: "ghost.fill") {
            SubghostMenuBarContent()
        }

        Settings {
            SettingsView()
        }
    }
}

private struct SubghostMenuBarContent: View {
    @State private var coordinator = AppCoordinator.shared

    var body: some View {
        Button("セッション一覧を開く") { coordinator.showSessions() }
        Button("アクティビティを開く") { coordinator.showActivity() }

        if !coordinator.watcher.sessions.isEmpty {
            Divider()
            ForEach(coordinator.watcher.sessions) { session in
                Button("\(session.info.displayName) — \(session.state.displayName)") {
                    coordinator.jump(to: session)
                }
                .disabled(session.info.tty.isEmpty)
            }
        }

        Divider()
        Button("設定…") { coordinator.openSettings() }
            .keyboardShortcut(",")
        Button("Subghostを終了") { NSApp.terminate(nil) }
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
