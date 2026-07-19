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
            HookSettingsView()
                .tabItem { Label("フック連携", systemImage: "bolt.horizontal") }
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
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundVolume") private var soundVolume = Double(SoundAlerts.defaultVolume)
    @AppStorage("preferredTerminal") private var preferredTerminal = ""
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
                Toggle("応答完了/エラー/承認リクエストを通知する", isOn: $notificationsEnabled)
                Text("承認リクエストの通知からは「承認」「拒否」を直接選べます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("サウンド") {
                Toggle("状態変化を8bit風のアラート音で知らせる", isOn: $soundEnabled)
                VStack(alignment: .leading) {
                    Slider(value: $soundVolume, in: 0.0...1.0, step: 0.05) {
                        Text("音量: \(Int(soundVolume * 100))%")
                    }
                    .disabled(!soundEnabled)
                }
                HStack {
                    ForEach(AlertSound.allCases, id: \.self) { sound in
                        Button(sound.displayName) {
                            SoundAlerts.shared.play(sound)
                        }
                        .disabled(!soundEnabled)
                    }
                }
            }
            Section("ターミナル") {
                Picker("移動先のターミナル", selection: $preferredTerminal) {
                    Text("自動判定").tag("")
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
                Text("「自動判定」はセッションが動いているターミナルを実行中プロセスから特定します。特定できないときのみ、この設定が使われます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ターミナル.appはタブ単位で移動できます（初回に自動化の許可が必要）。GhosttyはAppleScript非対応のため、アプリの前面化までとなります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// フック連携の導入・解除 (追補: フック方式)
private struct HookSettingsView: View {
    @State private var installed: [HookTarget: Bool] = [:]
    @State private var messages: [HookTarget: (text: String, isError: Bool)] = [:]
    @State private var confirming: HookTarget?

    private var serverRunning: Bool { AppCoordinator.shared.watcher.hookServerRunning }

    var body: some View {
        Form {
            Section("受信サーバ") {
                Label(serverRunning ? "動作中" : "停止中",
                      systemImage: serverRunning ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(serverRunning ? Color.green : Color.secondary)
                Text("フックからイベントを直接受け取る方式です。tmuxを使わずに監視・承認ができ、画面の文字解析による誤判定もなくなります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(HookTarget.allCases) { target in
                Section(target.displayName) {
                    let isOn = installed[target] ?? false

                    Label(isOn ? "登録済み" : "未登録",
                          systemImage: isOn ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isOn ? Color.green : Color.secondary)

                    Text(target.settingsURL.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if target.requiresTrustApproval {
                        Text("Codexはフックに信頼の承認を求めます。登録後、Codexを起動した際に表示される確認で許可してください。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !target.isLikelyInstalled {
                        Text("このCLIの設定ディレクトリが見つかりません。未インストールの可能性があります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isOn {
                        Button("解除する", role: .destructive) { uninstall(target) }
                    } else {
                        Button("有効にする") { confirming = target }
                            .disabled(!serverRunning)
                    }

                    if let message = messages[target] {
                        Text(message.text)
                            .font(.caption)
                            .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    }
                }
            }

            Section {
                Text("Subghostが起動していない場合、フックは何もせず即座に終了するため、CLIの動作を妨げません。書き換え前には自動でバックアップを取り、既存の設定は残します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Antigravityはフック機構を確認できていないため、tmux方式で監視してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .confirmationDialog(
            confirming.map { "\($0.settingsURL.lastPathComponent) を書き換えます" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("バックアップを取って続行") {
                if let target = confirming { install(target) }
                confirming = nil
            }
            Button("キャンセル", role: .cancel) { confirming = nil }
        } message: {
            Text("既存の設定は保持し、Subghost用のフックのみを追記します。いつでも解除できます。")
        }
    }

    private func refresh() {
        for target in HookTarget.allCases {
            installed[target] = HookInstaller.isInstalled(target)
        }
    }

    private func install(_ target: HookTarget) {
        do {
            try HookInstaller.install(target)
            var note = "登録しました。実行中の\(target.displayName)は再起動すると反映されます。"
            if target.requiresTrustApproval {
                note += "\n次回起動時にフックの信頼を求められるので許可してください。"
            }
            messages[target] = (note, false)
        } catch {
            messages[target] = ("登録に失敗しました: \(error.localizedDescription)", true)
        }
        refresh()
    }

    private func uninstall(_ target: HookTarget) {
        do {
            try HookInstaller.uninstall(target)
            messages[target] = ("解除しました。", false)
        } catch {
            messages[target] = ("解除に失敗しました: \(error.localizedDescription)", true)
        }
        refresh()
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
            Text("AI CLIをtmuxセッション内で起動すると、Subghostが自動検出して監視を開始します。以下のエイリアスをシェル設定に登録し、GhosttyまたはターミナルAppで実行してください。")
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
