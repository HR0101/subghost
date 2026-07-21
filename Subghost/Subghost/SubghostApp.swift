//
//  SubghostApp.swift
//  Subghost
//
//  Ghostty補助ノッチAIアシスタント
//
//  アプリの入口。@main の App 本体と AppDelegate だけを持つ。
//  メニューバーには常駐せず、Scene は SwiftUI が最低1つ要求するための
//  Settings のみ。実際の起動処理・終了処理はすべて AppCoordinator へ委ねる。
//

import SwiftUI

@main
struct SubghostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // メニューバーには何も置かない。操作の入口はノッチUIに集約する。
    // App は最低1つ Scene を要求するため Settings を置いているが、
    // 設定ウインドウは SettingsWindowController が自前で開く（このシーン経由ではない）。
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
