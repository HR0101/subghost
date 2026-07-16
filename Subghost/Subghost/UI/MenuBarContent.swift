//
//  MenuBarContent.swift
//  Subghost
//
//  設計書 7: MenuBarExtra常駐。ノッチ非搭載機・権限拒否時の代替操作手段 (設計書 12)
//

import SwiftUI

struct MenuBarLabel: View {
    var coordinator: AppCoordinator

    private var symbol: String {
        let states = coordinator.watcher.sessions.map(\.state)
        if states.contains(.error) { return "exclamationmark.triangle" }
        if states.contains(.thinking) { return "ellipsis.circle" }
        if states.contains(.completed) { return "checkmark.circle" }
        return "circle.dotted"
    }

    var body: some View {
        Image(systemName: symbol)
    }
}

struct MenuBarContent: View {
    var coordinator: AppCoordinator

    var body: some View {
        if coordinator.watcher.sessions.isEmpty {
            Text(coordinator.watcher.tmuxAvailable
                 ? "ai-* セッション未検出"
                 : "tmuxが見つかりません")
        } else {
            ForEach(coordinator.watcher.sessions) { session in
                Button {
                    coordinator.watcher.activeSessionName = session.info.tmuxName
                } label: {
                    let mark = session.info.tmuxName == coordinator.watcher.activeSessionName ? "✓ " : "　"
                    Text("\(mark)\(session.info.tmuxName) — \(session.state.displayName)")
                }
            }
        }

        Divider()

        Button("クイックプロンプト（⌥Space）") {
            coordinator.expandInput()
        }
        Button("Ghosttyを開く") {
            GhosttyActivator.activate()
        }

        Divider()

        SettingsLink {
            Text("設定…")
        }
        Button("Subghostを終了") {
            NSApp.terminate(nil)
        }
    }
}
