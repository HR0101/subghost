//
//  SettingsView.swift
//  Subghost
//
//  設計書 フェーズ5: 設定画面（判定閾値の調整: 設計書 12）
//
//  設定ウインドウの全体。外観・履歴とデータ・通知とサウンド・ショートカット
//  などのタブを持ち、各 *Preferences（UserDefaults）への読み書き口になる。
//
//  ウインドウは SwiftUI の Settings シーン任せにせず、SettingsWindowController が
//  自前で開く。メニューバーに常駐しないアプリなので、標準の導線が使えないため。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 設定ウインドウを自前で持つ。
///
/// SwiftUIの `Settings` シーンは `SettingsLink`（Sceneの環境が要る）か
/// AppKitの非公開セレクタ `showSettingsWindow:` からしか開けない。
/// ノッチは手動で作った NSPanel なので Scene の環境が届かず、
/// 非公開セレクタもmacOSの版によって応答しないため「押しても何も起きない」になる。
/// 表示経路を自分で握って、どちらにも依存せずに開けるようにする。
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // LSUIElementのため、明示的に前面へ出さないと背面で開いたままになる
        NSApp.activate()
        makeWindowIfNeeded().makeKeyAndOrderFront(nil)
    }

    /// 一度作ったウインドウは閉じても使い回す（選択中のページと位置を保つため）
    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }

        let created = NSWindow(
            contentViewController: NSHostingController(rootView: SettingsView())
        )
        created.title = "Subghost 設定"
        // 閉じたときに解放されると、上で保持している参照が無効になる
        created.isReleasedWhenClosed = false
        created.center()
        created.setFrameAutosaveName("SubghostSettingsWindow")
        window = created
        return created
    }
}

struct SettingsView: View {
    @State private var selection: SettingsPage = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    settingsLink(.general, "一般", "gearshape.fill")
                    settingsLink(.alerts, "通知とサウンド", "bell.badge.fill")
                    settingsLink(.appearance, "外観", "paintbrush.fill")
                    settingsLink(.integration, "統合", "puzzlepiece.extension.fill")
                    settingsLink(.snippets, "スニペット", "text.badge.plus")
                }
                Section("詳細設定") {
                    settingsLink(.shortcuts, "ショートカット", "keyboard.fill")
                    settingsLink(.data, "履歴とデータ", "clock.arrow.circlepath")
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
                case .alerts: AlertSettingsView()
                case .appearance: AppearanceSettingsView()
                case .integration: HookSettingsView()
                case .snippets: SnippetSettingsView()
                case .shortcuts: ShortcutSettingsView()
                case .data: DataSettingsView()
                case .diagnostics: SetupDiagnosticsView()
                case .setup: SetupGuideView()
                case .information: InformationSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 固定サイズだと、システムの文字サイズを大きくした環境で内容が見切れる。
        // 既定の大きさは保ちつつ、ユーザーがリサイズできるようにする。
        .frame(
            minWidth: 640, idealWidth: 860, maxWidth: .infinity,
            minHeight: 480, idealHeight: 680, maxHeight: .infinity
        )
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
    case alerts
    case appearance
    case integration
    case snippets
    case shortcuts
    case data
    case diagnostics
    case setup
    case information
}

private struct GeneralSettingsView: View {
    @AppStorage("pollInterval") private var pollInterval = 0.8
    @AppStorage("stableInterval") private var stableInterval = 1.5
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
    @AppStorage(NotchPreferences.choiceAutoCloseIntervalKey) private var choiceAutoCloseInterval = 0.0
    @AppStorage(NotchPreferences.focusChoiceOnAppearKey) private var focusChoiceOnAppear = true
    @AppStorage(NotchPreferences.hideUnmonitorableSessionsKey)
    private var hideUnmonitorableSessions = true
    @AppStorage(NotchPreferences.hideInactiveSessionsKey) private var hideInactiveSessions = true
    @AppStorage(NotchPreferences.inactiveSessionThresholdKey)
    private var inactiveSessionThreshold = 1_800.0
    @AppStorage(NotchPreferences.suggestsTmuxSetupKey) private var suggestsTmuxSetup = true
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

            Section("セッション一覧") {
                Toggle("監視できないセッションを隠す", isOn: $hideUnmonitorableSessions)
                Text("tmux にもフックにも繋がっていないセッションです。"
                     + "状態を読むことも、プロンプトを送ることもできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("しばらく動きの無いセッションを隠す", isOn: $hideInactiveSessions)
                Stepper(
                    value: $inactiveSessionThreshold,
                    in: NotchPreferences.inactiveSessionThresholdRange,
                    step: 300
                ) {
                    Text("動きが無いとみなすまで: \(Int(inactiveSessionThreshold / 60)) 分")
                }
                .disabled(!hideInactiveSessions)
                Text("tmux が記録しているペインの最終出力時刻で判断します。"
                     + "Subghost を再起動しても引き継がれます。"
                     + "隠したセッションも監視は続けており、回答が必要になれば必ず表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("tmux の導入を案内する", isOn: $suggestsTmuxSetup)
                Text("tmux を使わず「監視のみ」で使う場合は切ってください。"
                     + "監視・通知・承認への回答は tmux が無くても動きます。"
                     + "プロンプトの送信だけが tmux を必要とします。")
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

            Section("選択肢（承認/質問）") {
                Toggle("回答するまで自動で閉じない（既定）", isOn: Binding(
                    get: { choiceAutoCloseInterval <= 0 },
                    set: { choiceAutoCloseInterval = $0 ? 0 : max(choiceAutoCloseInterval, 10) }
                ))
                if choiceAutoCloseInterval > 0 {
                    Stepper(value: $choiceAutoCloseInterval, in: 10...120, step: 5) {
                        LabeledContent("自動で閉じるまでの時間") {
                            Text("\(choiceAutoCloseInterval, specifier: "%.0f")秒")
                                .monospacedDigit()
                        }
                    }
                }
                Text("ノッチから消えてもCLI側は引き続き回答を待っています。ターミナルで直接答えるか、"
                     + "ノッチにカーソルを合わせると一覧からいつでも選び直せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("回答待ちのときキーボードを受け取る", isOn: $focusChoiceOnAppear)
                Text("有効だと数字キーだけですぐ回答できますが、他のアプリで入力中に割り込むと"
                     + "打鍵がノッチへ移ってしまいます。無効にすると、パネルを表示するだけに留め、"
                     + "ノッチをクリックしてから回答します。対象のターミナルを前面で見ている間は"
                     + "設定に関係なくキーボードを奪いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    ForEach(TerminalApp.allCases.filter(\.isLaunchable)) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
                Text("「自動判定」はセッションが動いているターミナルを実行中プロセスから特定します。特定できないときのみ、この設定が使われます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ターミナル.appはタブ単位で移動できます（初回に自動化の許可が必要）。GhosttyはAppleScript非対応のため、アプリの前面化までとなります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("VS Code・Cursor・Windsurfの内蔵ターミナルは自動判定の対象です。タブの特定はできないため、そのウインドウの前面化までとなります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("できること") {
                ForEach(SessionCapability.allCases, id: \.self) { capability in
                    LabeledContent(capability.label) {
                        Text(capability.requirement)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("プロンプトの送信だけが tmux を必要とします。"
                     + "監視・完了通知・承認への回答はフックだけで動くため、"
                     + "tmux を使わない簡易的な構成でも利用できます。")
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

// MARK: - 外観

private struct AppearanceSettingsView: View {
    @AppStorage(AppearancePreferences.panelOpacityKey)
    private var panelOpacity = AppearancePreferences.defaultPanelOpacity
    @AppStorage(AppearancePreferences.expandedCornerRadiusKey)
    private var cornerRadius = AppearancePreferences.defaultExpandedCornerRadius
    @AppStorage(AppearancePreferences.sessionListMaxRowsKey)
    private var listRows = Double(AppearancePreferences.defaultSessionListMaxRows)
    @AppStorage(AppearancePreferences.ghostAnimationEnabledKey)
    private var ghostAnimation = true
    @AppStorage(AppearancePreferences.hidePreviewTextKey)
    private var hidePreview = false

    /// Slider は Double の範囲を要求するので、Int の設定範囲を変換して持っておく
    private static let listRowsRange: ClosedRange<Double> = {
        let range = AppearancePreferences.sessionListMaxRowsRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }()

    var body: some View {
        Form {
            Section("パネル") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("背景の不透明度")
                        Spacer()
                        Text("\(Int(panelOpacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $panelOpacity, in: AppearancePreferences.panelOpacityRange, step: 0.05)
                }
                Text("下げると展開部分から背後のウインドウが透けます。コンパクト時の見た目は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("展開時の角丸")
                        Spacer()
                        Text("\(Int(cornerRadius))pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $cornerRadius,
                        in: AppearancePreferences.expandedCornerRadiusRange,
                        step: 1
                    )
                }
            }

            Section("セッション一覧") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("一度に表示する件数")
                        Spacer()
                        Text("\(Int(listRows))件")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $listRows, in: Self.listRowsRange, step: 1)
                }
                Text("これを超えたぶんはスクロールで見ます。増やすとノッチが画面下へ長く伸びます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("キャラクター") {
                Toggle("ゴーストをアニメーションさせる", isOn: $ghostAnimation)
                Text("生成中の裾揺れ、待機中のまばたき、完了時の弾みとエラー時の震えを再生します。"
                     + "画面の動きを減らしたいときはオフにしてください。状態ごとの色と表情は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("プライバシー") {
                Toggle("応答の本文を表示しない", isOn: $hidePreview)
                Text("ノッチのプレビュー・通知の本文・アクティビティ履歴から、会話の中身を伏せます。"
                     + "画面共有や録画のときに使ってください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("既に記録済みの履歴には遡って適用されません。消すには「履歴とデータ」から削除してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: panelOpacity) { _, _ in preferencesChanged() }
        .onChange(of: cornerRadius) { _, _ in preferencesChanged() }
        .onChange(of: listRows) { _, _ in preferencesChanged() }
    }

    private func preferencesChanged() {
        AppCoordinator.shared.preferencesChanged()
    }
}

// MARK: - 履歴とデータ

private struct DataSettingsView: View {
    @AppStorage(ActivityPreferences.recordingEnabledKey) private var activityEnabled = true
    @AppStorage(ActivityPreferences.limitKey)
    private var activityLimit = Double(ActivityPreferences.defaultLimit)
    @AppStorage(PromptHistoryPreferences.enabledKey) private var historyEnabled = true
    @AppStorage(PromptHistoryPreferences.limitKey)
    private var historyLimit = Double(PromptHistoryPreferences.defaultLimit)

    @State private var activityKindRevision = 0
    @State private var message: String?
    @State private var isError = false
    @State private var confirmingReset = false

    private var activity: ActivityStore { AppCoordinator.shared.activity }
    private var snippets: SnippetStore { AppCoordinator.shared.snippets }

    /// Stepper は Double の範囲を要求するので、Int の設定範囲を変換して持っておく
    private static let activityLimitRange: ClosedRange<Double> = {
        let range = ActivityPreferences.limitRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }()

    private static let historyLimitRange: ClosedRange<Double> = {
        let range = PromptHistoryPreferences.limitRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }()

    var body: some View {
        Form {
            Section("アクティビティ履歴") {
                Toggle("履歴を記録する", isOn: $activityEnabled)
                Stepper(value: $activityLimit, in: Self.activityLimitRange, step: 10) {
                    LabeledContent("保持する件数") {
                        Text("\(Int(activityLimit))件")
                            .monospacedDigit()
                    }
                }
                .disabled(!activityEnabled)
                .onChange(of: activityLimit) { _, _ in activity.applyRetentionLimit() }

                LabeledContent("現在の保存件数") {
                    Text("\(activity.entries.count)件").monospacedDigit()
                }

                Button("履歴を消去", role: .destructive) {
                    activity.clear()
                    message = "アクティビティ履歴を消去しました。"
                    isError = false
                }
                .disabled(activity.entries.isEmpty)
            }

            Section("記録するイベント") {
                ForEach(ActivityKind.allCases, id: \.self) { kind in
                    ActivityKindRow(kind: kind)
                        .disabled(!activityEnabled)
                }
                .id(activityKindRevision)
            }

            Section("送信履歴") {
                Toggle("送信したプロンプトを保存する", isOn: $historyEnabled)
                Stepper(value: $historyLimit, in: Self.historyLimitRange, step: 5) {
                    LabeledContent("保持する件数") {
                        Text("\(Int(historyLimit))件")
                            .monospacedDigit()
                    }
                }
                .disabled(!historyEnabled)
                .onChange(of: historyLimit) { _, _ in snippets.applyHistoryLimit() }

                LabeledContent("現在の保存件数") {
                    Text("\(snippets.history.count)件").monospacedDigit()
                }

                Button("送信履歴を消去", role: .destructive) {
                    snippets.clearHistory()
                    message = "送信履歴を消去しました。"
                    isError = false
                }
                .disabled(snippets.history.isEmpty)

                Text("ノッチの入力欄で ⌥↑ / ⌥↓ を押すと呼び出せる履歴です。"
                     + "アプリケーションサポート内に平文で保存されるため、残したくない場合はオフにしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("設定の書き出しと読み込み") {
                HStack {
                    Button("書き出す…") { exportSettings() }
                    Button("読み込む…") { importSettings() }
                }
                Text("別のMacへ移すときや、不具合の報告に設定を添えたいときに使います。"
                     + "初回案内の完了状態とアクティビティ履歴は含みません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("設定の初期化") {
                Button("すべての設定を初期状態に戻す", role: .destructive) {
                    confirmingReset = true
                }
                Text("フック連携の登録や ~/.zshrc の変更といったアプリ外への変更はそのまま残ります。"
                     + "必要なら「統合」画面から個別に解除してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "すべての設定を初期状態に戻します",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("初期化する", role: .destructive) { resetSettings() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ショートカット、通知、外観、スニペットの設定がすべて既定へ戻ります。この操作は取り消せません。")
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SettingsStore.suggestedFileName
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsStore.export(to: url)
            message = "設定を書き出しました: \(url.lastPathComponent)"
            isError = false
        } catch {
            message = "書き出しに失敗しました: \(error.localizedDescription)"
            isError = true
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try SettingsStore.importSettings(from: url)
            AppCoordinator.shared.hotkey.reload()
            AppCoordinator.shared.preferencesChanged()
            AppCoordinator.shared.reloadDisplayPlacement()
            message = "\(count)件の設定を読み込みました。"
            isError = false
        } catch {
            message = "読み込みに失敗しました: \(error.localizedDescription)"
            isError = true
        }
    }

    private func resetSettings() {
        do {
            try SettingsStore.resetAll()
            AppCoordinator.shared.hotkey.reload()
            AppCoordinator.shared.preferencesChanged()
            AppCoordinator.shared.reloadDisplayPlacement()
            message = "設定を初期化しました。表示に反映されない項目は、アプリを再起動すると揃います。"
            isError = false
        } catch {
            message = "初期化に失敗しました: \(error.localizedDescription)"
            isError = true
        }
    }
}

/// アクティビティの種類ごとの記録トグル
private struct ActivityKindRow: View {
    let kind: ActivityKind
    @State private var isEnabled: Bool

    init(kind: ActivityKind) {
        self.kind = kind
        _isEnabled = State(initialValue: ActivityPreferences.records(kind))
    }

    var body: some View {
        Toggle(kind.displayName, isOn: $isEnabled)
            .onChange(of: isEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: ActivityPreferences.kindKey(kind))
            }
    }
}

// MARK: - 通知とサウンド

private struct AlertSettingsView: View {
    @AppStorage(NotificationPreferences.masterKey) private var notificationsEnabled = true
    @AppStorage(NotificationPreferences.timeSensitiveKey) private var timeSensitive = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundVolume") private var soundVolume = Double(SoundAlerts.defaultVolume)

    @AppStorage(QuietHours.enabledKey) private var quietEnabled = false
    @AppStorage(QuietHours.startKey) private var quietStart = Double(QuietHours.defaultStartMinutes)
    @AppStorage(QuietHours.endKey) private var quietEnd = Double(QuietHours.defaultEndMinutes)
    @AppStorage(QuietHours.allowBlockingKey) private var quietAllowsBlocking = true

    @AppStorage(UsagePreferences.warningKey) private var usageWarning = UsagePreferences.defaultWarning
    @AppStorage(UsagePreferences.criticalKey) private var usageCritical = UsagePreferences.defaultCritical

    /// エージェント別ミュートは動的なキーなので @AppStorage を使えない。
    /// トグルするたびにこの値を進めて、行を作り直させる。
    @State private var agentMuteRevision = 0

    var body: some View {
        Form {
            Section("通知") {
                Toggle("通知を表示する", isOn: $notificationsEnabled)
                Text("ここをオフにすると、下のイベント別の設定に関係なくすべての通知を止めます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知するイベント") {
                ForEach(NotificationEvent.allCases, id: \.self) { event in
                    NotificationEventRow(event: event)
                        .disabled(!notificationsEnabled)
                }
                Text("承認リクエストの通知からは「承認」「拒否」を直接選べます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("集中モード") {
                Toggle("承認・質問は集中モード中でも割り込む", isOn: $timeSensitive)
                    .disabled(!notificationsEnabled)
                Text("回答しないとCLIが止まってしまうため、既定では割り込みます。"
                     + "オフにすると、macOSの集中モードの設定に従って抑制されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("静穏時間") {
                Toggle("指定した時間帯は知らせない", isOn: $quietEnabled)
                if quietEnabled {
                    MinutePicker(title: "開始", minutes: $quietStart)
                    MinutePicker(title: "終了", minutes: $quietEnd)
                    Toggle("承認・質問だけは通す", isOn: $quietAllowsBlocking)
                    Text(quietSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("通知・サウンド・ノッチの自動展開をまとめて控えます。回答待ちは消えず、一覧には残ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("エージェント別") {
                ForEach(CLIProfile.builtins) { profile in
                    Toggle(profile.displayName, isOn: Binding(
                        get: { !AgentMutePreferences.isMuted(profileID: profile.id) },
                        set: {
                            AgentMutePreferences.setMuted(!$0, profileID: profile.id)
                            agentMuteRevision += 1
                        }
                    ))
                }
                .id(agentMuteRevision)
                Text("オフにしたCLIは、通知もサウンドもノッチの自動展開も行いません。"
                     + "常に画面で見ているCLIを静かにさせたいときに使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("個別のセッションだけを黙らせたいときは、ノッチの一覧にあるスピーカーボタンを使ってください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("使用量の警告") {
                VStack(alignment: .leading) {
                    Slider(value: $usageWarning, in: UsagePreferences.thresholdRange, step: 1) {
                        Text("注意を促す使用率: \(Int(usageWarning))%")
                    }
                }
                VStack(alignment: .leading) {
                    Slider(value: $usageCritical, in: UsagePreferences.thresholdRange, step: 1) {
                        Text("強く警告する使用率: \(Int(usageCritical))%")
                    }
                }
                if usageCritical < usageWarning {
                    Text("強く警告する値が注意より低いため、注意の値（\(Int(usageWarning))%）まで引き上げて扱います。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("5時間枠・7日枠の消費率がこの割合を超えると、ノッチの表示色が変わります。")
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
        }
        .formStyle(.grouped)
    }

    private var quietSummary: String {
        let start = QuietHours.text(forMinutes: Int(quietStart))
        let end = QuietHours.text(forMinutes: Int(quietEnd))
        if Int(quietStart) == Int(quietEnd) {
            return "開始と終了が同じため、静穏時間は適用されません。"
        }
        let crossesMidnight = Int(quietStart) > Int(quietEnd)
        return crossesMidnight
            ? "毎日 \(start) から翌 \(end) まで控えます。"
            : "毎日 \(start) から \(end) まで控えます。"
    }
}

/// 通知イベント1件ぶんの行
private struct NotificationEventRow: View {
    let event: NotificationEvent
    @State private var isEnabled: Bool

    init(event: NotificationEvent) {
        self.event = event
        _isEnabled = State(initialValue: event.isEnabled)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.displayName)
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: event.enabledKey)
                }
        }
    }
}

/// 0時からの分数を時刻として選ばせる
private struct MinutePicker: View {
    let title: String
    @Binding var minutes: Double

    private static let choices: [Int] = stride(from: 0, to: 24 * 60, by: 30).map { $0 }

    var body: some View {
        Picker(title, selection: Binding(
            get: { nearestChoice(Int(minutes)) },
            set: { minutes = Double($0) }
        )) {
            ForEach(Self.choices, id: \.self) { value in
                Text(QuietHours.text(forMinutes: value)).tag(value)
            }
        }
    }

    /// 30分刻みの選択肢に無い値が保存されていても、最も近いものを選んで表示する
    private func nearestChoice(_ value: Int) -> Int {
        Self.choices.min { abs($0 - value) < abs($1 - value) } ?? 0
    }
}

private struct SnippetSettingsView: View {
    @State private var store = AppCoordinator.shared.snippets
    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var editing: Snippet?
    @State private var confirmingDefaults = false

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
                        Button {
                            editing = snippet
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("編集する")

                        Button(role: .destructive) {
                            store.remove(snippet)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }

            Divider()

            VStack(spacing: 8) {
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
                HStack {
                    Text("ドラッグで並べ替えられます。上にあるものほどノッチで早く選べます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("既定に戻す") { confirmingDefaults = true }
                        .buttonStyle(.borderless)
                }
            }
            .padding(10)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { updated in
                store.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog(
            "スニペットを既定の内容に戻します",
            isPresented: $confirmingDefaults,
            titleVisibility: .visible
        ) {
            Button("戻す", role: .destructive) { store.restoreDefaults() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("追加・編集したスニペットはすべて失われます。")
        }
    }
}

/// スニペット1件の編集シート
private struct SnippetEditor: View {
    let snippet: Snippet
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    @State private var title: String
    /// SwiftUI の body と名前がぶつからないよう text で持つ
    @State private var text: String

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        self.snippet = snippet
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: snippet.title)
        _text = State(initialValue: snippet.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スニペットを編集")
                .font(.headline)
            TextField("タイトル", text: $title)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { onCancel() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        var updated = snippet
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // タイトルを空のまま保存したら、本文の先頭を見出しに使う
        if updated.title.isEmpty {
            updated.title = String(updated.body.prefix(10))
        }
        onSave(updated)
    }
}

/// フック連携の導入・解除 (追補: フック方式)
private struct HookSettingsView: View {
    @State private var installed: [HookTarget: Bool] = [:]
    @State private var messages: [HookTarget: (text: String, isError: Bool)] = [:]
    @State private var confirming: HookTarget?
    @State private var statuslineMessage: String?
    @State private var shellMessage: String?
    @State private var newAliasName = ""
    @State private var newAliasBaseProfileID = CLIProfile.codex.id
    @State private var aliasMessage: String?
    @State private var customAliasStore = AppCoordinator.shared.customAliasStore

    /// 失敗したらその内容を文字列で返す（成功時は nil）
    private func run(_ work: () throws -> Void) -> String? {
        do { try work(); return nil } catch { return "失敗しました: \(error.localizedDescription)" }
    }

    private func displayName(for profileID: String) -> String {
        CLIProfile.builtins.first { $0.id == profileID }?.displayName ?? profileID
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
                Text("有効にすると、ターミナルで claude / codex / agy（カスタムエイリアス含む）を起動したとき自動的にtmux内で立ち上がります。既存のシェルエイリアスのオプションもそのまま保持されます。tmuxを介すと、他の画面を見ながらでもノッチから質問の選択肢に回答できます。")
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
                        let extra = AppCoordinator.shared.customAliasStore.aliases.map(\.name)
                        shellMessage = run { try ShellIntegration.install(extraCommands: extra) }
                            ?? "有効にしました。新しいターミナルタブから反映されます（既存タブは source ~/.zshrc）。"
                    }
                    .disabled(TmuxClient.resolveTmuxPath() == nil)
                }
                if let shellMessage {
                    Text(shellMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("カスタムエイリアス") {
                Text("独自の名前（ラッパースクリプトやシンボリックリンクなど）でCLIを起動している場合、"
                     + "ここに登録するとそのCLIとして検出されます。単純なシェルエイリアス（alias付き）は"
                     + "登録しなくても自動的に検出されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(customAliasStore.aliases) { alias in
                    HStack {
                        Text(alias.name)
                            .font(.system(.body, design: .monospaced))
                        Text(displayName(for: alias.baseProfileID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("削除", role: .destructive) {
                            AppCoordinator.shared.removeCustomAlias(alias)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }

                HStack {
                    TextField("エイリアス名（例: codexA）", text: $newAliasName)
                    Picker("", selection: $newAliasBaseProfileID) {
                        ForEach(CLIProfile.builtins) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("追加") {
                        let added = AppCoordinator.shared.addCustomAlias(
                            name: newAliasName, baseProfileID: newAliasBaseProfileID)
                        if added { newAliasName = "" }
                        aliasMessage = added ? nil
                            : "使えるのは英数字・ハイフン・アンダースコアのみで、先頭は英字か"
                            + "アンダースコアにしてください（既に登録済みの場合もあります）。"
                    }
                    .disabled(newAliasName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let aliasMessage {
                    Text(aliasMessage).font(.caption).foregroundStyle(.orange)
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

            Text("特別な設定は不要です。ターミナルで claude / codex / agy を普通に起動すれば、Subghostが自動的に検出します。セッション名の命名規則は要りません。独自の名前で起動している場合は「カスタムエイリアス」から登録してください。")
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
                    Text("「統合」タブの「自動でtmux内起動」を有効にすると、claude / codex / agy を普通に起動するだけで、自動的にtmux内で立ち上がります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("tmux\ncodex   # 既存のシェルエイリアスのオプションも保持されます")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                }
            }

            Text("\(HotkeyAction.toggleInput.shortcutOrName)：ノッチのプロンプト入力欄を開く／閉じる")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

private struct ShortcutSettingsView: View {
    /// 記録し直すたびに各行を作り直して、表示を保存内容へ追従させる
    @State private var revision = 0

    private var categories: [(name: String, actions: [HotkeyAction])] {
        var order: [String] = []
        var grouped: [String: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases {
            if grouped[action.category] == nil { order.append(action.category) }
            grouped[action.category, default: []].append(action)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            Section {
                Text("どのアプリを操作中でも使えます。Carbonのホットキーを使うため、アクセシビリティ権限は不要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("「記録」を押してから、割り当てたいキーの組み合わせを押してください。"
                     + "修飾キー（⌘⌥⌃⇧）を1つ以上含める必要があります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(categories, id: \.name) { category in
                Section(category.name) {
                    ForEach(category.actions) { action in
                        HotkeyRow(action: action, revision: $revision)
                    }
                }
            }

            Section {
                Button("すべて既定に戻す") {
                    for action in HotkeyAction.allCases { action.resetBinding() }
                    AppCoordinator.shared.hotkey.reload()
                    revision += 1
                }
            }

            Section("ノッチ内の操作") {
                LabeledContent("プロンプトを送信", value: "⌘Return")
                LabeledContent("閉じる", value: "Esc")
                LabeledContent("送信履歴をたどる", value: "⌥↑ / ⌥↓")
                LabeledContent("送信先を切り替える", value: "Tab")
                LabeledContent("質問の選択肢を選ぶ", value: "1〜9")
                LabeledContent("質問の先頭を選ぶ", value: "Return")
                Text("承認リクエストではReturnに既定を割り当てていません。"
                     + "誤ってキーを叩いても許可が送られないよう、番号キーかクリックでの明示的な選択だけを受け付けます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ショートカット1件ぶんの行

private struct HotkeyRow: View {
    let action: HotkeyAction
    @Binding var revision: Int

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.displayName)
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let conflict {
                    Text(conflict)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()

            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(buttonTitle)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 92)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            Button {
                assign(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(action.binding == nil)
            .help("割り当てを解除する")
        }
        .padding(.vertical, 2)
        .id(revision)
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return "キーを押す…" }
        return action.binding?.displayText ?? "未割り当て"
    }

    private func startRecording() {
        isRecording = true
        conflict = nil
        // 記録中は設定ウインドウ内のキー入力を横取りする。
        // nil を返してイベントを消費し、押したキーが他の操作へ流れないようにする。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escは「取り消し」に割り当てる。記録欄から抜けられなくならないように。
            if event.keyCode == HotkeyBinding.escapeKeyCode {
                stopRecording()
                return nil
            }
            guard let binding = HotkeyBinding.from(event: event) else { return nil }
            guard binding.hasModifier else {
                conflict = "⌘⌥⌃⇧ のいずれかと組み合わせてください。"
                return nil
            }
            assign(binding)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func assign(_ binding: HotkeyBinding?) {
        if let binding, let owner = conflictingAction(for: binding) {
            conflict = "\(owner.displayName) と重複しています。"
            return
        }
        conflict = nil
        action.setBinding(binding)
        AppCoordinator.shared.hotkey.reload()
        revision += 1
    }

    /// 同じ組み合わせを既に使っている別の操作を探す
    private func conflictingAction(for binding: HotkeyBinding) -> HotkeyAction? {
        HotkeyAction.allCases.first {
            $0 != action
                && $0.binding?.keyCode == binding.keyCode
                && $0.binding?.carbonModifiers == binding.carbonModifiers
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
    @AppStorage(DiagnosticsPreferences.writeStateDumpKey) private var writeStateDump = false
    @AppStorage(DiagnosticsPreferences.logDisplaySelectionKey) private var logDisplaySelection = false

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
                    title: "プロンプトの送信",
                    detail: TmuxClient.resolveTmuxPath() != nil
                        ? "tmux があるため、tmux内のセッションへ送信できます"
                        : "tmux が無いため、監視のみの構成です（送信は行えません）",
                    health: TmuxClient.resolveTmuxPath() != nil ? .ready : .attention
                ) {
                    EmptyView()
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
                        ? "claude / codex / agy（カスタムエイリアス含む）を自動的にtmux内で起動します"
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

            Section("記録") {
                Toggle("画面解析の内容をファイルへ書き出す", isOn: $writeStateDump)
                Text("状態の誤判定を調べるための記録です。取り込んだ画面の文字と判定結果を保存します。"
                     + "会話の内容がそのまま含まれるため、普段はオフのままにしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存先をFinderで開く") {
                    NSWorkspace.shared.open(DiagnosticsPreferences.stateDumpDirectory)
                }
                .disabled(!writeStateDump)

                Toggle("表示先ディスプレイの判断をコンソールへ記録", isOn: $logDisplaySelection)
                Text("ノッチが意図しない画面に出るときの調査に使います。Console.appで「Subghost」を検索してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        var parts = [
            session.info.capabilityLabel,
            "監視: \(session.info.monitoringSource)",
            "TTY: \(session.info.shortName)",
        ]
        if let target = session.info.tmuxTarget { parts.append("tmux: \(target)") }
        if session.info.isHookConnected { parts.append("Hook接続済み") }
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
                .accessibilityLabel("\(sound.displayName) のサウンド")

            Button {
                SoundAlerts.shared.preview(sound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("試聴する")
            .accessibilityLabel("\(sound.displayName) を試聴する")
        }
    }
}
