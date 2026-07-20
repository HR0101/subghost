//
//  SettingsView.swift
//  Subghost
//
//  設計書 フェーズ5: 設定画面（判定閾値の調整: 設計書 12）
//

import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var selection: SettingsPage = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    settingsLink(.general, "一般", "gearshape.fill")
                    settingsLink(.integration, "統合", "puzzlepiece.extension.fill")
                    settingsLink(.snippets, "スニペット", "text.badge.plus")
                }
                Section("詳細設定") {
                    settingsLink(.shortcuts, "ショートカット", "keyboard.fill")
                    settingsLink(.diagnostics, "診断", "stethoscope")
                    settingsLink(.setup, "セットアップ", "wrench.and.screwdriver.fill")
                }
                Section {
                    settingsLink(.information, "情報", "info.circle.fill")
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            Group {
                switch selection {
                case .general: GeneralSettingsView()
                case .integration: HookSettingsView()
                case .snippets: SnippetSettingsView()
                case .shortcuts: ShortcutSettingsView()
                case .diagnostics: SetupDiagnosticsView()
                case .setup: SetupGuideView()
                case .information: InformationSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 680)
    }

    private func settingsLink(
        _ page: SettingsPage,
        _ title: String,
        _ systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .tag(page)
    }
}

private enum SettingsPage: Hashable {
    case general
    case integration
    case snippets
    case shortcuts
    case diagnostics
    case setup
    case information
}

private struct GeneralSettingsView: View {
    @AppStorage("pollInterval") private var pollInterval = 0.8
    @AppStorage("stableInterval") private var stableInterval = 1.5
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundVolume") private var soundVolume = Double(SoundAlerts.defaultVolume)
    @AppStorage(DisplayPreference.userDefaultsKey) private var notchDisplay = ""
    @AppStorage("preferredTerminal") private var preferredTerminal = ""
    @AppStorage("tmuxPath") private var tmuxPath = ""
    @AppStorage(NotchPreferences.hoverExpansionEnabledKey) private var hoverExpansionEnabled = true
    @AppStorage(NotchPreferences.hoverDelayKey) private var hoverDelay = 0.15
    @AppStorage(NotchPreferences.expansionAnimationDurationKey)
    private var expansionAnimationDuration = NotchPreferences.defaultExpansionAnimationDuration
    @AppStorage(NotchPreferences.smartNotificationSuppressionKey) private var smartNotificationSuppression = true
    @AppStorage(NotchPreferences.hideInFullScreenKey) private var hideInFullScreen = true
    @AppStorage(NotchPreferences.hideWhenNoSessionsKey) private var hideWhenNoSessions = false
    @AppStorage(NotchPreferences.notificationDisplayDurationKey) private var notificationDisplayDuration = 5.0
    @AppStorage(NotchPreferences.collapseOnMouseExitKey) private var collapseOnMouseExit = true
    @AppStorage(NotchPreferences.closeOnOutsideClickKey) private var closeOnOutsideClick = true
    @State private var launchAtLogin = false
    @State private var isChangingLoginItem = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("システム") {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { launchAtLogin },
                    set: { updateLaunchAtLogin($0) }
                ))
                .disabled(isChangingLoginItem)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("展開") {
                Toggle("ホバーでノッチを展開", isOn: $hoverExpansionEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("展開までの待ち時間")
                        Spacer()
                        Text("\(hoverDelay, specifier: "%.2f")秒")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $hoverDelay, in: 0...1.0, step: 0.05)
                        .disabled(!hoverExpansionEnabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("展開アニメーション時間")
                        Spacer()
                        Text("\(expansionAnimationDuration, specifier: "%.2f")秒")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $expansionAnimationDuration,
                        in: NotchPreferences.expansionAnimationDurationRange,
                        step: 0.05
                    )
                }
                Toggle("スマート抑制", isOn: $smartNotificationSuppression)
                Text("対象のAIセッションをターミナルで見ている間は、完了パネルを自動展開しません。通知とサウンドは通常どおり届きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("表示") {
                Toggle("フルスクリーン時に非表示", isOn: $hideInFullScreen)
                Toggle("アクティブなセッションがない時に自動非表示", isOn: $hideWhenNoSessions)
                Text("承認待ち・質問・入力中は、見逃しを防ぐため設定に関係なく表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("収納") {
                Toggle("マウス離脱時に自動折りたたみ", isOn: $collapseOnMouseExit)
                Stepper(value: $notificationDisplayDuration, in: 2...30, step: 1) {
                    LabeledContent("自動表示の表示時間") {
                        Text("\(notificationDisplayDuration, specifier: "%.0f")秒")
                            .monospacedDigit()
                    }
                }
                Text("完了通知と警告通知でパネルを表示しておく時間です。Escキーでも早めに閉じられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("外側のクリックで自動表示を閉じる", isOn: $closeOnOutsideClick)
            }

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
                Toggle("サウンドエフェクトを有効にする", isOn: $soundEnabled)
                VStack(alignment: .leading) {
                    Slider(value: $soundVolume, in: 0.0...1.0, step: 0.05) {
                        Text("音量: \(Int(soundVolume * 100))%")
                    }
                    .disabled(!soundEnabled)
                }
                Text("すべてコードで合成した8bit風の音です。音源ファイルは含んでいません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 参考にしたアプリと同じ粒度で、イベントごとに鳴らし分ける
            ForEach(SoundSettingsSection.all, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.sounds, id: \.self) { sound in
                        SoundRow(sound: sound)
                            .disabled(!soundEnabled)
                    }
                }
            }

            Section("表示先ディスプレイ") {
                Picker("ノッチを表示する画面", selection: $notchDisplay) {
                    Text("自動（ノッチ搭載画面を優先）").tag("")
                    Text("使用中のモニターに追従").tag("active")
                    Text("システムの主ディスプレイ").tag("main")
                    Divider()
                    ForEach(NSScreen.screens.map(\.descriptor)) { screen in
                        Text(screen.hasNotch ? "\(screen.name)（ノッチあり）" : screen.name)
                            .tag(screen.id)
                    }
                }
                .onChange(of: notchDisplay) { _, _ in
                    AppCoordinator.shared.reloadDisplayPlacement()
                }
                Text("「使用中のモニターに追従」は、作業しているウインドウのある画面へノッチが移動します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ノッチの無い画面を選んだ場合は、メニューバーに重ねて同じ形のバーを表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("指定した画面を取り外すと、自動選択に戻ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("キー入力の送信") {
                LabeledContent("アクセシビリティ") {
                    Label(KeystrokeSender.isTrusted ? "許可済み" : "未許可",
                          systemImage: KeystrokeSender.isTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(KeystrokeSender.isTrusted ? Color.green : Color.orange)
                }
                Text("tmuxを介さないセッションへプロンプトや回答を送るには、キー入力を合成する必要があります。対象タブを前面に出してから入力するため、許可が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !KeystrokeSender.isTrusted {
                    Button("アクセシビリティを許可する") { KeystrokeSender.requestTrust() }
                }
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
        .onAppear {
            launchAtLogin = LoginItemManager.isEnabled
        }
        .onChange(of: hoverExpansionEnabled) { _, _ in preferencesChanged() }
        .onChange(of: hoverDelay) { _, _ in preferencesChanged() }
        .onChange(of: expansionAnimationDuration) { _, _ in preferencesChanged() }
        .onChange(of: hideInFullScreen) { _, _ in preferencesChanged() }
        .onChange(of: hideWhenNoSessions) { _, _ in preferencesChanged() }
        .onChange(of: collapseOnMouseExit) { _, _ in preferencesChanged() }
        .onChange(of: closeOnOutsideClick) { _, _ in preferencesChanged() }
    }

    private func preferencesChanged() {
        AppCoordinator.shared.preferencesChanged()
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        loginItemError = nil
        isChangingLoginItem = true
        Task {
            do {
                try await LoginItemManager.setEnabled(enabled)
            } catch {
                loginItemError = "ログイン項目を変更できませんでした: \(error.localizedDescription)"
            }
            launchAtLogin = LoginItemManager.isEnabled
            isChangingLoginItem = false
        }
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
    @State private var statuslineMessage: String?
    @State private var shellMessage: String?

    /// 失敗したらその内容を文字列で返す（成功時は nil）
    private func run(_ work: () throws -> Void) -> String? {
        do { try work(); return nil } catch { return "失敗しました: \(error.localizedDescription)" }
    }

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

            Section("使用量の取得") {
                let installed = HookInstaller.isStatuslineInstalled()
                Label(installed ? "有効" : "無効",
                      systemImage: installed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(installed ? Color.green : Color.secondary)

                Text("5時間枠・7日枠の消費率は statusline へ渡されるJSONにしか含まれないため、"
                     + "既存の statusline コマンドを包んで内容を読み取ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("元のコマンドは保存し、解除時に必ず戻します。出力はそのまま通すため、"
                     + "statusline の見た目は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if installed {
                    Button("解除して元に戻す", role: .destructive) {
                        statuslineMessage = run { try HookInstaller.uninstallStatusline() }
                            ?? "元の statusline に戻しました。"
                    }
                } else {
                    Button("使用量の取得を有効にする") {
                        statuslineMessage = run { try HookInstaller.installStatusline() }
                            ?? "有効にしました。次回の statusline 更新から取得します。"
                    }
                }
                if let statuslineMessage {
                    Text(statuslineMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section("自動でtmux内起動") {
                let on = ShellIntegration.isInstalled()
                Label(on ? "有効" : "無効",
                      systemImage: on ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(on ? Color.green : Color.secondary)
                Text("有効にすると、ターミナルで claude / codexA / codexB / agyy を起動したとき自動的にtmux内で立ち上がります。各エイリアスのオプションはそのまま保持されます。tmuxを介すと、他の画面を見ながらでもノッチから質問の選択肢に回答できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("~/.zshrc に読み込み行を1行追加します（書き換え前にバックアップを取ります）。--version などの非対話実行や、すでにtmux内のときは何もしません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if TmuxClient.resolveTmuxPath() == nil {
                    Text("tmuxが見つかりません。先に brew install tmux でインストールしてください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if on {
                    Button("解除する", role: .destructive) {
                        shellMessage = run { try ShellIntegration.uninstall() } ?? "解除しました。"
                    }
                } else {
                    Button("有効にする") {
                        shellMessage = run { try ShellIntegration.install() }
                            ?? "有効にしました。新しいターミナルタブから反映されます（既存タブは source ~/.zshrc）。"
                    }
                    .disabled(TmuxClient.resolveTmuxPath() == nil)
                }
                if let shellMessage {
                    Text(shellMessage).font(.caption).foregroundStyle(.secondary)
                }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("セットアップ")
                .font(.headline)

            Text("特別な設定は不要です。ターミナルで claude / codexA / codexB / agyy を普通に起動すれば、Subghostが自動的に検出します。セッション名の命名規則は要りません。")
                .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("フック連携（Claude Code / Codex）", systemImage: "bolt.horizontal")
                        .font(.callout).fontWeight(.medium)
                    Text("「フック連携」タブから有効にすると、tmuxなしで状態監視・承認・質問への回答ができます。誤判定もなくなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("tmuxを挟み忘れないようにする", systemImage: "terminal")
                        .font(.callout).fontWeight(.medium)
                    Text("「統合」タブの「自動でtmux内起動」を有効にすると、claude / codexA / codexB / agyy を普通に起動するだけで、自動的にtmux内で立ち上がります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("tmux\ncodexA   # codexB / agyyも既存オプションを保持")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                }
            }

            Text("\(HotkeyPreset.current.displayName)：ノッチのプロンプト入力欄を開く／閉じる")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

private struct ShortcutSettingsView: View {
    @AppStorage(HotkeyPreset.userDefaultsKey) private var preset = HotkeyPreset.optionSpace.rawValue

    var body: some View {
        Form {
            Section("グローバルショートカット") {
                Picker("プロンプト入力を開く／閉じる", selection: $preset) {
                    ForEach(HotkeyPreset.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                Text("他のアプリを操作中でも使えます。Carbonのホットキーを使うため、アクセシビリティ権限は不要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ノッチ内の操作") {
                LabeledContent("送信", value: "Return")
                LabeledContent("閉じる", value: "Esc")
                LabeledContent("送信履歴", value: "↑")
                LabeledContent("送信先を切り替える", value: "Tab")
                LabeledContent("質問の選択肢", value: "1〜9")
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset) { _, _ in
            AppCoordinator.shared.hotkey.reload()
        }
    }
}

private enum DiagnosticHealth {
    case checking
    case ready
    case attention
    case information

    var iconName: String {
        switch self {
        case .checking: return "clock"
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .information: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking, .information: return .secondary
        case .ready: return .green
        case .attention: return .orange
        }
    }
}

private struct SetupDiagnosticsView: View {
    @State private var notificationHealth: DiagnosticHealth = .checking
    @State private var notificationDetail = "確認中…"
    @State private var refreshedAt = Date()

    private var watcher: SessionWatcher { AppCoordinator.shared.watcher }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("セットアップ診断")
                            .font(.title2.bold())
                        Text("権限と監視経路をまとめて確認します")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("再確認", systemImage: "arrow.clockwise") {
                        refreshedAt = Date()
                        Task { await refreshNotificationStatus() }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("macOSの権限") {
                DiagnosticRow(
                    title: "通知",
                    detail: notificationDetail,
                    health: notificationHealth
                ) {
                    Button("通知設定を開く") {
                        openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                    }
                }

                DiagnosticRow(
                    title: "アクセシビリティ",
                    detail: KeystrokeSender.isTrusted
                        ? "tmux外のセッションにもキー入力を送れます"
                        : "tmux外へのプロンプト送信には許可が必要です",
                    health: KeystrokeSender.isTrusted ? .ready : .attention
                ) {
                    if !KeystrokeSender.isTrusted {
                        Button("許可する") { KeystrokeSender.requestTrust() }
                    }
                    Button("設定を開く") {
                        openSystemSettings(
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )
                    }
                }

                DiagnosticRow(
                    title: "ターミナル操作",
                    detail: "ターミナル.appのタブ選択は、初回テスト時に自動化の許可を確認します",
                    health: .information
                ) {
                    Button("移動をテスト") {
                        guard let session = watcher.activeSession else {
                            TerminalActivator.activate()
                            return
                        }
                        Task { await TerminalActivator.jump(to: session.info) }
                    }
                }
            }

            Section("Hook") {
                DiagnosticRow(
                    title: "受信サーバー",
                    detail: watcher.hookServerRunning
                        ? "Unixソケットでイベントを待ち受けています"
                        : "受信サーバーが停止しています",
                    health: watcher.hookServerRunning ? .ready : .attention
                )

                ForEach(HookTarget.allCases) { target in
                    let installed = HookInstaller.isInstalled(target)
                    DiagnosticRow(
                        title: "\(target.displayName)のHook",
                        detail: installed ? "設定ファイルへ登録済み" : "未登録です。統合画面から有効にできます",
                        health: installed ? .ready : .attention
                    )
                }

                DiagnosticRow(
                    title: "Hookの実受信",
                    detail: hookReceiptDetail,
                    health: watcher.lastHookEventAt == nil ? .information : .ready
                )
            }

            Section("tmux") {
                let tmuxPath = TmuxClient.resolveTmuxPath()
                DiagnosticRow(
                    title: "tmux本体",
                    detail: tmuxPath ?? "tmuxが見つかりません",
                    health: tmuxPath == nil ? .attention : .ready
                )
                DiagnosticRow(
                    title: "自動tmux起動",
                    detail: ShellIntegration.isInstalled()
                        ? "claude / codexA / codexB / agyy を自動的にtmux内で起動します"
                        : "未設定です。統合画面から有効にできます",
                    health: ShellIntegration.isInstalled() ? .ready : .information
                )
            }

            Section("検出中のセッション") {
                if watcher.sessions.isEmpty {
                    Text("AI CLIはまだ検出されていません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watcher.sessions) { session in
                        DiagnosticRow(
                            title: "\(session.info.profile.displayName) — \(session.info.displayName)",
                            detail: sessionDetail(session),
                            health: session.info.isMonitorable ? .ready : .attention
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(refreshedAt)
        .task { await refreshNotificationStatus() }
    }

    private var hookReceiptDetail: String {
        guard let date = watcher.lastHookEventAt else {
            return "まだ受信していません。Hook登録後にCLIでプロンプトを送ると確認できます"
        }
        return "最終受信: \(date.formatted(date: .abbreviated, time: .standard))"
    }

    private func sessionDetail(_ session: MonitoredSession) -> String {
        var parts = ["監視: \(session.info.monitoringSource)", "TTY: \(session.info.shortName)"]
        if let target = session.info.tmuxTarget { parts.append("tmux: \(target)") }
        if session.info.isHookConnected { parts.append("Hook接続済み") }
        if !session.info.isMonitorable { parts.append("状態取得不可") }
        return parts.joined(separator: " ／ ")
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationHealth = .ready
            notificationDetail = "通知の表示が許可されています"
        case .denied:
            notificationHealth = .attention
            notificationDetail = "通知が拒否されています。完了や承認要求を見逃す可能性があります"
        case .notDetermined:
            notificationHealth = .attention
            notificationDetail = "通知の許可がまだ選択されていません"
        @unknown default:
            notificationHealth = .information
            notificationDetail = "通知状態を判定できませんでした"
        }
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DiagnosticRow<Actions: View>: View {
    let title: String
    let detail: String
    let health: DiagnosticHealth
    @ViewBuilder let actions: () -> Actions

    init(
        title: String,
        detail: String,
        health: DiagnosticHealth,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.health = health
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: health.iconName)
                .foregroundStyle(health.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 6) { actions() }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private extension DiagnosticRow where Actions == EmptyView {
    init(title: String, detail: String, health: DiagnosticHealth) {
        self.init(title: title, detail: detail, health: health) { EmptyView() }
    }
}

private struct InformationSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PixelGhostView(state: .idle, pixelSize: 4)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Subghost")
                            .font(.title2.bold())
                        Text("バージョン \(version)（\(build)）")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("対応") {
                LabeledContent("AI CLI", value: "Claude Code / Codex / Antigravity")
                LabeledContent("ターミナル", value: "Ghostty / ターミナル.app")
                LabeledContent("監視方式", value: "フック / tmux")
            }

            Section("プライバシー") {
                Text("セッション情報と設定はMac内だけで処理します。Subghost自身が外部サーバーへ会話内容を送信することはありません。")
                    .foregroundStyle(.secondary)
                Text("ターミナルへの移動とキー入力には、必要な場合だけmacOSの自動化・アクセシビリティ権限を使用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - サウンド設定の行

/// 設定画面での分類（参考にしたアプリの並びに合わせている）
private struct SoundSettingsSection {
    let name: String
    let sounds: [AlertSound]

    static let all: [SoundSettingsSection] = {
        // カテゴリ順を保ったままグループ化する
        var order: [String] = []
        var grouped: [String: [AlertSound]] = [:]
        for sound in AlertSound.allCases {
            if grouped[sound.category] == nil { order.append(sound.category) }
            grouped[sound.category, default: []].append(sound)
        }
        return order.map { SoundSettingsSection(name: $0, sounds: grouped[$0] ?? []) }
    }()
}

/// イベント1件ぶんの設定行（オン/オフ と 試聴）
private struct SoundRow: View {
    let sound: AlertSound
    @State private var isEnabled: Bool

    init(sound: AlertSound) {
        self.sound = sound
        _isEnabled = State(initialValue: sound.isEnabled)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sound.displayName)
                Text(sound.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: sound.enabledKey)
                }

            Button {
                SoundAlerts.shared.play(sound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("試聴する")
        }
    }
}
