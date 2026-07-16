//
//  SettingsView.swift
//  Subghost
//
//  設計書 フェーズ5: 設定画面（判定閾値の調整: 設計書 12）
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            SnippetSettingsView()
                .tabItem { Label("スニペット", systemImage: "text.badge.plus") }
            SetupGuideView()
                .tabItem { Label("セットアップ", systemImage: "questionmark.circle") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("pollInterval") private var pollInterval = 0.8
    @AppStorage("stableInterval") private var stableInterval = 1.5
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("tmuxPath") private var tmuxPath = ""

    var body: some View {
        Form {
            Section("監視") {
                VStack(alignment: .leading) {
                    Slider(value: $pollInterval, in: 0.4...3.0, step: 0.1) {
                        Text("ポーリング間隔: \(pollInterval, specifier: "%.1f")秒")
                    }
                    Text("短いほど反応が速く、長いほど省電力です")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Slider(value: $stableInterval, in: 0.5...5.0, step: 0.5) {
                        Text("完了判定の静止時間: \(stableInterval, specifier: "%.1f")秒")
                    }
                    Text("出力がこの時間止まりプロンプトが現れたら「完了」と判定します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("通知") {
                Toggle("応答完了/エラーを通知する", isOn: $notificationsEnabled)
            }
            Section("tmux") {
                TextField("tmuxのパス（空欄で自動検出）", text: $tmuxPath)
                    .font(.system(.body, design: .monospaced))
                Text(TmuxClient.resolveTmuxPath().map { "検出: \($0)" } ?? "tmuxが見つかりません")
                    .font(.caption)
                    .foregroundStyle(TmuxClient.resolveTmuxPath() == nil ? Color.red : Color.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SnippetSettingsView: View {
    @State private var store = AppCoordinator.shared.snippets
    @State private var newTitle = ""
    @State private var newBody = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.snippets) { snippet in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.title).font(.headline)
                            Text(snippet.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.remove(snippet)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            HStack {
                TextField("タイトル", text: $newTitle)
                    .frame(width: 120)
                TextField("本文", text: $newBody)
                Button("追加") {
                    store.add(title: newTitle, body: newBody)
                    newTitle = ""
                    newBody = ""
                }
                .disabled(newBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}

private struct SetupGuideView: View {
    private let aliases = """
    # ~/.zshrc に追加
    alias aiclaude='tmux new-session -A -s ai-claude claude'
    alias aicodex='tmux new-session -A -s ai-codex codex'
    alias aiantigravity='tmux new-session -A -s ai-antigravity antigravity'
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("セットアップ (設計書 10.1)")
                .font(.headline)
            Text("AI CLIをtmuxセッション内で起動すると、Subghostが自動検出して監視を開始します。以下のエイリアスをシェル設定に登録し、Ghosttyで実行してください。")
                .font(.callout)
            Text(aliases)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            HStack {
                Spacer()
                Button("エイリアスをコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aliases, forType: .string)
                }
            }
            Text("⌥Space：ノッチのプロンプト入力欄を開く／閉じる")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}
