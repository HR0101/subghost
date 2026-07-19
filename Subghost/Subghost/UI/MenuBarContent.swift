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
        // 回答待ちは処理が止まっているため、エラーの次に優先して知らせる
        if states.contains(.error) { return "exclamationmark.triangle" }
        if states.contains(.awaitingApproval) { return "hand.raised" }
        if states.contains(.awaitingAnswer) { return "questionmark.circle" }
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
            Text("AI CLI が見つかりません")
        } else {
            ForEach(coordinator.watcher.sessions) { session in
                Button {
                    coordinator.watcher.activeSessionName = session.info.tty
                } label: {
                    let mark = session.info.tty == coordinator.watcher.activeSessionName ? "✓ " : "　"
                    // tmux外のセッションは検出のみで、状態を読めないことを明示する
                    let status = session.info.isMonitorable
                        ? session.state.displayName
                        : "監視不可（tmux外）"
                    Text("\(mark)\(session.info.profile.displayName) \(session.info.displayName) — \(status)")
                }
            }
        }

        Divider()

        Button("クイックプロンプト（⌥Space）") {
            coordinator.expandInput()
        }
        Button("該当タブへ移動") {
            coordinator.jumpToTerminal()
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
