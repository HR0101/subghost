//
//  SubghostTests.swift
//  SubghostTests
//
//  状態判定ロジック（設計書 5）のユニットテスト
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Subghost

// MARK: - ノッチ表示設定

struct NotchPreferencesTests {
    @Test func 未保存の設定は指定した既定値を返す() {
        let suiteName = "SubghostTests.NotchPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotchPreferences.bool(
            forKey: "enabled", default: true, defaults: defaults))
        #expect(NotchPreferences.number(
            forKey: "duration", default: 5.0, defaults: defaults) == 5.0)
    }

    @Test func 保存済みの設定は既定値より優先される() {
        let suiteName = "SubghostTests.NotchPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "enabled")
        defaults.set(0.35, forKey: "delay")

        #expect(!NotchPreferences.bool(
            forKey: "enabled", default: true, defaults: defaults))
        #expect(NotchPreferences.number(
            forKey: "delay", default: 0.15, defaults: defaults) == 0.35)
    }

    /// ショートカットは3択のプリセットから任意のキー割り当てへ変わった。
    /// 未設定時に既定へ戻る性質と、不正な保存値を無視する性質は
    /// HotkeyBindingTests（SettingsPreferencesTests.swift）で引き続き担保している。
    @Test func ショートカットの未設定は既定値へ戻る() {
        let suiteName = "SubghostTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HotkeyAction.showSessions.binding(in: defaults)?.displayText == "⌥Space")

        // 壊れた値が入っていても既定へ倒れる（クラッシュしない）
        defaults.set(Data("not a binding".utf8), forKey: HotkeyAction.showSessions.userDefaultsKey)
        #expect(HotkeyAction.showSessions.binding(in: defaults) == nil)
    }

    @Test func 展開アニメーション時間を安全な範囲へ補正する() {
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(0) == 0.15)
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(0.65) == 0.65)
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(3) == 1.20)
    }
}

struct NotchSurfaceShapeTests {
    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 400)
    private let compactWidth: CGFloat = 278
    private let compactHeight: CGFloat = 34

    @Test func 変形開始時は本体の外側に上部ショルダーを持つ() {
        let bounds = makeShape(progress: 0).path(in: canvas).boundingRect

        #expect(abs(bounds.width - NotchLayout.canvasWidth(for: compactWidth)) < 0.01)
        #expect(abs(bounds.height - compactHeight) < 0.01)
        #expect(abs(bounds.midX - canvas.midX) < 0.01)
        #expect(abs(bounds.minY - canvas.minY) < 0.01)
    }

    @Test func 変形完了時は展開領域全体に一致する() {
        let bounds = makeShape(progress: 1).path(in: canvas).boundingRect

        #expect(abs(bounds.width - canvas.width) < 0.01)
        #expect(abs(bounds.height - canvas.height) < 0.01)
    }

    @Test func 変形途中は横方向が下方向より先行する() {
        let bounds = makeShape(progress: 0.5).path(in: canvas).boundingRect
        let initialWidth = NotchLayout.canvasWidth(for: compactWidth)
        let horizontal = (bounds.width - initialWidth) / (canvas.width - initialWidth)
        let vertical = (bounds.height - compactHeight) / (canvas.height - compactHeight)

        #expect(horizontal > vertical)
    }

    private func makeShape(progress: CGFloat) -> NotchSurfaceShape {
        NotchSurfaceShape(
            progress: progress,
            compactWidth: compactWidth,
            compactHeight: compactHeight,
            canvasShoulderInset: NotchLayout.topShoulderWidth
        )
    }
}

struct PixelGhostAnimationTests {
    @Test func ゴーストは生成中だけ動く() {
        #expect(GhostSprite.shouldAnimate(for: .thinking))
        #expect(!GhostSprite.shouldAnimate(for: .idle))
        #expect(!GhostSprite.shouldAnimate(for: .completed))
        #expect(!GhostSprite.shouldAnimate(for: .error))
    }
}

struct SessionsListLayoutTests {
    @Test func 少数のセッションでは行数に合わせた高さになる() {
        #expect(NotchLayout.sessionsListHeight(count: 0) == 0)
        #expect(NotchLayout.sessionsListHeight(count: 2) == 136)
    }

    @Test func 多数のセッションでも一覧の最大高を超えない() {
        #expect(NotchLayout.sessionsListHeight(count: 100) == NotchLayout.sessionsListMaxHeight)
    }
}

struct ActivityStoreTests {
    @Test func 履歴を新しい順に上限件数まで保存して復元する() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "history"
        let store = ActivityStore(defaults: defaults, storageKey: key, maximumCount: 2)

        let first = makeEntry(summary: "1")
        let second = makeEntry(summary: "2")
        let third = makeEntry(summary: "3")
        store.append(first)
        store.append(second)
        store.append(third)

        #expect(store.entries.map(\.summary) == ["3", "2"])
        #expect(store.unreadCount == 2)

        store.markRead(third.id)
        let restored = ActivityStore(defaults: defaults, storageKey: key, maximumCount: 2)
        #expect(restored.entries == store.entries)
        #expect(restored.unreadCount == 1)
    }

    @Test func 履歴をすべて既読にして消去できる() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ActivityStore(defaults: defaults, storageKey: "history")
        store.append(makeEntry(summary: "完了"))

        store.markAllRead()
        #expect(store.unreadCount == 0)

        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test func プライバシー設定時は保存済み本文を復元不能にする() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ActivityStore(defaults: defaults, storageKey: "history")
        store.append(makeEntry(summary: "秘密の本文"))

        store.redactSummaries()

        #expect(store.entries.first?.summary == "（本文は非表示）")
        let restored = ActivityStore(defaults: defaults, storageKey: "history")
        #expect(restored.entries.first?.summary == "（本文は非表示）")
    }

    private func makeEntry(summary: String) -> ActivityEntry {
        ActivityEntry(
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .completed,
            sessionTTY: "/dev/ttys004",
            sessionPID: 100,
            agentID: "codex",
            agentName: "Codex CLI",
            sessionName: "subghost",
            summary: summary
        )
    }
}

// MARK: - 通知のセッション紐付け

struct NotificationRoutingTests {

    private func session(pid: Int32 = 42, tty: String = "/dev/ttys001") -> SessionInfo {
        SessionInfo(agent: DiscoveredAgent(pid: pid, tty: tty, profile: .claude))
    }

    @Test func 通知はPIDとTTYの両方が一致したセッションだけを指す() {
        let original = session()
        let reference = NotificationSessionReference(session: original)
        #expect(reference.matches(original))
        #expect(!reference.matches(session(pid: 99)))
        #expect(!reference.matches(session(tty: "/dev/ttys009")))
    }

    @Test func 通知情報を安全に往復できる() {
        let reference = NotificationSessionReference(session: session())
        #expect(NotificationSessionReference(userInfo: reference.userInfo) == reference)
        #expect(NotificationSessionReference(userInfo: [:]) == nil)
    }
}

struct AgentDiscoveryTests {

    private let profiles = CLIProfile.builtins

    /// `ps -A -o pid=,tty=,comm=` を模した出力
    private let psOutput = """
      934 ??       /Applications/ChatGPT.app/Contents/Resources/codex
     3514 ttys003  claude
    41080 ttys004  claude
    68352 ttys004  /bin/zsh
    77001 ttys005  /opt/homebrew/bin/codex
    """

    @Test func 実行ファイル名からAI_CLIを検出する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(found.count == 3)
        #expect(found.map(\.pid) == [3514, 41080, 77001])
        #expect(found.map(\.profile.id) == ["claude", "claude", "codex"])
    }

    @Test func 制御端末を持たないプロセスは除外する() {
        // ChatGPT.appが同梱するcodex（ttyが ??）を拾ってはいけない
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(!found.contains { $0.pid == 934 })
    }

    @Test func AI_CLI以外のプロセスは無視する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(!found.contains { $0.pid == 68352 })   // /bin/zsh
    }

    @Test func ttyはdev付きの絶対パスに正規化する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(found.first?.tty == "/dev/ttys003")
    }

    @Test func Antigravityは実体名agyで検出する() {
        // "antigravity" というコマンドは存在せず、実体は "agy"（実測）
        let found = AgentDiscovery.parseAgentProcesses(
            "  84323 ttys005  /Users/me/.local/bin/agy", profiles: profiles)
        #expect(found.count == 1)
        #expect(found.first?.profile.id == "antigravity")
        #expect(found.first?.tty == "/dev/ttys005")
    }

    @Test func Codexはnode配下の実体パスでも検出する() {
        // 実測: node_modules配下の長いパスで動いている
        let path = "/Users/me/.nodebrew/node/v22.9.0/lib/node_modules/@openai/codex/"
            + "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        let found = AgentDiscovery.parseAgentProcesses("  39003 ttys010  \(path)", profiles: profiles)
        #expect(found.first?.profile.id == "codex")
    }

    @Test func 実行ファイル名は完全一致で判定する() {
        // "claude-helper" のような別物を拾わない
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude", profiles: profiles)?.id == "claude")
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude-helper", profiles: profiles) == nil)
        #expect(AgentDiscovery.matchProfile(commandPath: "/bin/zsh", profiles: profiles) == nil)
    }

    @Test func カスタムエイリアスを登録すると独自の実行ファイル名でも検出できる() {
        let alias = CustomAlias(name: "codexA", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/codexA", profiles: merged)?.id == "codex")
        // ビルトインの検出は壊れていないこと
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude", profiles: merged)?.id == "claude")
    }

    @Test func カスタムエイリアスは大文字小文字を無視して照合する() {
        // psのcomm列は小文字化して比較するため、登録名も揃える必要がある
        let alias = CustomAlias(name: "CodexA", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/codexa", profiles: merged)?.id == "codex")
    }

    @Test func 存在しないプロファイルIDのカスタムエイリアスは無視する() {
        let alias = CustomAlias(name: "mystery", baseProfileID: "no-such-profile")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(merged.count == CLIProfile.builtins.count)
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/mystery", profiles: merged) == nil)
    }

    @Test func 既存の実行ファイル名と重複するカスタムエイリアスは二重登録しない() {
        let alias = CustomAlias(name: "codex", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        let codexProfile = merged.first { $0.id == "codex" }
        #expect(codexProfile?.executableNames.filter { $0 == "codex" }.count == 1)
    }

    @Test func 英数字とハイフンアンダースコアのエイリアス名は妥当とみなす() {
        #expect(CustomAlias.isValidName("codexA"))
        #expect(CustomAlias.isValidName("my-agent_2"))
        #expect(CustomAlias.isValidName("_underscore"))
    }

    @Test(arguments: [
        "",                     // 空文字
        "2fast",                // 数字始まり
        "-dash",                // ハイフン始まり
        "my agent",             // 空白
        "codex; rm -rf ~",      // コマンド区切り
        "codex`whoami`",        // コマンド置換（バッククォート）
        "$(whoami)",            // コマンド置換（$構文）
        "codex&&ls",            // 論理演算子
        "codex|ls",             // パイプ
        String(repeating: "a", count: 65),   // 長すぎる
    ])
    func シェルへ危険な文字を含むエイリアス名は不正とみなす(_ name: String) {
        // シェルスクリプトへそのまま埋め込まれるため、これらを許すと
        // コマンドインジェクションが成立してしまう（実機レビューで指摘された脆弱性）
        #expect(!CustomAlias.isValidName(name))
    }

    // MARK: - 一覧に出すかどうか

    private func 表示判断入力(
        isActiveTarget: Bool = false,
        isMonitorable: Bool = true,
        activityAt: Date,
        hiddenAtActivity: Date? = nil
    ) -> SessionVisibility.Input {
        SessionVisibility.Input(
            isActiveTarget: isActiveTarget,
            isMonitorable: isMonitorable,
            activityAt: activityAt,
            hiddenAtActivity: hiddenAtActivity
        )
    }

    private var 既定ルール: SessionVisibility.Rules {
        SessionVisibility.Rules(
            revealAll: false,
            hideUnmonitorable: true,
            hideInactive: true,
            inactiveThreshold: 1_800
        )
    }

    @Test func 長時間動きの無いセッションは一覧から外す() {
        let now = Date(timeIntervalSince1970: 100_000)
        // 31分前が最終活動
        let stale = 表示判断入力(activityAt: now.addingTimeInterval(-1_860))
        let fresh = 表示判断入力(activityAt: now.addingTimeInterval(-60))
        #expect(!SessionVisibility.isVisible(stale, rules: 既定ルール, at: now))
        #expect(SessionVisibility.isVisible(fresh, rules: 既定ルール, at: now))
    }

    @Test func 監視できないセッションは一覧から外す() {
        let now = Date(timeIntervalSince1970: 100_000)
        let input = 表示判断入力(isMonitorable: false, activityAt: now)
        #expect(!SessionVisibility.isVisible(input, rules: 既定ルール, at: now))
    }

    @Test func 選択中のセッションは必ず表示する() {
        let now = Date(timeIntervalSince1970: 100_000)
        let input = 表示判断入力(
            isActiveTarget: true,
            activityAt: now.addingTimeInterval(-100_000)
        )
        #expect(SessionVisibility.isVisible(input, rules: 既定ルール, at: now))
    }

    @Test func 手動で隠したセッションは新しい動きがあれば戻る() {
        let now = Date(timeIntervalSince1970: 100_000)
        let hiddenAt = now.addingTimeInterval(-600)

        // 隠した時点から動きが無い → 隠れたまま
        let quiet = 表示判断入力(activityAt: hiddenAt, hiddenAtActivity: hiddenAt)
        #expect(!SessionVisibility.isVisible(quiet, rules: 既定ルール, at: now))

        // 隠した後に動いた → また使い始めたとみなして表示
        let resumed = 表示判断入力(
            activityAt: now.addingTimeInterval(-10), hiddenAtActivity: hiddenAt)
        #expect(SessionVisibility.isVisible(resumed, rules: 既定ルール, at: now))
    }

    @Test func すべて表示中は絞り込みを行わない() {
        let now = Date(timeIntervalSince1970: 100_000)
        var rules = 既定ルール
        rules.revealAll = true
        let input = 表示判断入力(
            isMonitorable: false,
            activityAt: now.addingTimeInterval(-100_000),
            hiddenAtActivity: now
        )
        #expect(SessionVisibility.isVisible(input, rules: rules, at: now))
    }

    @Test func 隠す設定を切れば放置セッションも表示する() {
        let now = Date(timeIntervalSince1970: 100_000)
        var rules = 既定ルール
        rules.hideInactive = false
        rules.hideUnmonitorable = false
        let input = 表示判断入力(
            isMonitorable: false, activityAt: now.addingTimeInterval(-100_000))
        #expect(SessionVisibility.isVisible(input, rules: rules, at: now))
    }

    // MARK: - できることの区分

    private func セッション(hookID: String?) -> SessionInfo {
        var info = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys006", profile: .claude))
        info.hookSessionID = hookID
        return info
    }

    @Test func フック接続なら状態を監視できるが送信はできない() {
        let info = セッション(hookID: "abc")
        #expect(info.capability == .monitorOnly)
        #expect(info.isMonitorable)
    }

    @Test func 同じTTYでもPIDが違えば別セッションとして識別する() {
        let first = SessionInfo(agent: DiscoveredAgent(
            pid: 101, tty: "/dev/ttys006", profile: .claude))
        let second = SessionInfo(agent: DiscoveredAgent(
            pid: 202, tty: "/dev/ttys006", profile: .claude))
        #expect(first.id != second.id)
    }

    @Test func TTYなしのフックセッションも一意に識別する() {
        let info = SessionInfo(
            hookSource: "codex",
            sessionID: "session-123",
            pid: nil,
            tty: nil,
            cwd: "/tmp/work"
        )
        #expect(info.id == "codex:hook:session-123")
        #expect(info.shortName == "バックグラウンド")
        #expect(info.capability == .monitorOnly)
    }

    @Test func フックが無ければ検出のみ() {
        let info = セッション(hookID: nil)
        #expect(info.capability == .detectedOnly)
        #expect(!info.isMonitorable)
    }

    @Test func 検出したセッションは端末に直接対応する() {
        let outside = SessionInfo(agent: DiscoveredAgent(
            pid: 2, tty: "/dev/ttys003", profile: .claude))

        #expect(!outside.isMonitorable)
        #expect(outside.displayName == "ttys003")

        // 作業ディレクトリが分かればフォルダ名を主体にする
        var withFolder = outside
        withFolder.workingDirectory = "/Users/me/Create App/subghost"
        #expect(withFolder.displayName == "subghost")
        #expect(withFolder.folderName == "subghost")
    }
}

struct SessionSelectionTests {

    @Test func 次のセッション名へ循環する() {
        let names = ["ai-claude", "ai-claude2", "ai-codex"]
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-claude") == "ai-claude2")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-claude2") == "ai-codex")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-codex") == "ai-claude")
    }

    @Test func 現在が未設定または消滅していたら先頭を返す() {
        let names = ["ai-claude", "ai-codex"]
        #expect(SessionWatcher.nextSessionName(in: names, after: nil) == "ai-claude")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-gone") == "ai-claude")
    }

    @Test func セッションが空ならnilを返す() {
        #expect(SessionWatcher.nextSessionName(in: [], after: nil) == nil)
    }
}

// MARK: - ノッチパネルの重なり順・入力設定

@MainActor
struct NotchPanelConfigTests {

    private func makePanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
    }

    @Test func パネルはメニューバーより上のレベルに置かれる() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        // メニューバー(24)・ステータスバー(25)より上でないと、
        // 全画面アプリの上に出せずクリックも通らない
        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
        #expect(panel.level == NotchPanelController.panelLevel)
    }

    @Test func isFloatingPanelにレベルを上書きされていない() {
        // 不具合の再発防止:
        // isFloatingPanel = true は level を .floating(3) に上書きするため、
        // 設定順序を誤ると 26 が 3 に潰れる。実際にこれで表示もクリックも壊れた。
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(panel.isFloatingPanel)
        #expect(panel.level.rawValue != NSWindow.Level.floating.rawValue)
        #expect(panel.level.rawValue == 26)
    }

    @Test func 全画面スペースにも参加する設定になっている() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func マウス入力を受け取る設定になっている() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(!panel.ignoresMouseEvents)
    }

    @Test func キーウインドウになれる設定になっている() {
        // becomesKeyOnlyIfNeeded が true だと makeKeyAndOrderFront しても
        // 入力欄にフォーカスが渡らず、プロンプトを打てなくなる
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(!panel.becomesKeyOnlyIfNeeded)
    }
}

// MARK: - メニューバーの表示状態

struct MenuBarVisibilityTests {

    /// 実測のCG座標（原点はメインディスプレイ左上、y軸は下向き）
    private let dell = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let builtin = CGRect(x: 207, y: 1440, width: 1512, height: 982)

    private func window(layer: Int, _ rect: CGRect) -> MenuBarVisibility.WindowSummary {
        MenuBarVisibility.WindowSummary(layer: layer, bounds: rect)
    }

    @Test func 全画面アプリのある画面ではメニューバー無しと判定する() {
        // 実測: 全画面時、メニューバーのウインドウは内蔵側にしか存在しなかった
        let windows = [
            window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33)),   // 内蔵のメニューバー
            window(layer: 0, CGRect(x: 0, y: 38, width: 2560, height: 1402)),      // DELLの全画面アプリ
        ]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
        #expect(MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: builtin))
    }

    @Test func メニューバーが出ている画面では表示と判定する() {
        let windows = [window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 30))]
        #expect(MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 画面全体を覆うレイヤー24のオーバーレイは誤検出しない() {
        // 実測でスクリーンショットUIがレイヤー24・画面全体で存在していた
        let windows = [window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 別画面のメニューバーを拾わない() {
        // 内蔵のメニューバーだけがある状態でDELLを問い合わせる
        let windows = [window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 上端から離れた細長いウインドウは誤検出しない() {
        let windows = [window(layer: 24, CGRect(x: 0, y: 700, width: 2560, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func レイヤーが違えばメニューバーとみなさない() {
        let windows = [window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 横方向の重なりが半分以下なら別画面とみなす() {
        // DELLの左端にわずかにかかるだけのウインドウ
        let windows = [window(layer: 24, CGRect(x: -2000, y: 0, width: 2100, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    // MARK: - ノッチを出すかどうかの総合判定

    /// 実測: DELLで全画面、メニューバーは内蔵側にのみ存在
    private var fullScreenOnDell: [MenuBarVisibility.WindowSummary] {
        [
            window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33)),
            window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 38)),
            window(layer: 0, CGRect(x: 0, y: 38, width: 2560, height: 1402)),
        ]
    }

    @Test func 全画面に覆われた画面では隠す() {
        #expect(!MenuBarVisibility.shouldShowNotch(windows: fullScreenOnDell, onScreen: dell))
    }

    @Test func 別の画面が全画面でも対象画面のノッチは消さない() {
        // 不具合の再発防止:
        // メニューバーはフォーカスされた画面にしか描画されないため、
        // 「メニューバーが無い」だけを条件にすると対象画面のノッチまで消えていた。
        let windows = [
            // DELLが全画面。メニューバーはどこにも描画されていない状況
            window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 1440)),
        ]
        // 内蔵は覆われていないので表示し続ける
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: builtin))
    }

    @Test func 全画面中でもメニューバーが現れたら表示する() {
        // 全画面でマウスを上端に運びメニューバーが出た状態
        let windows = fullScreenOnDell + [
            window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 30)),
        ]
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: dell))
    }

    @Test func 通常のウインドウでは隠さない() {
        // メニューバーの下に配置された最大化ウインドウ
        let windows = [
            window(layer: 0, CGRect(x: 0, y: 30, width: 2560, height: 1410)),
        ]
        #expect(!MenuBarVisibility.isCoveredByFullScreenWindow(windows: windows, onScreen: dell))
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: dell))
    }

    @Test func 幅の狭いウインドウが上端にあっても全画面とみなさない() {
        let windows = [
            window(layer: 0, CGRect(x: 0, y: 0, width: 800, height: 1440)),
        ]
        #expect(!MenuBarVisibility.isCoveredByFullScreenWindow(windows: windows, onScreen: dell))
    }

    @Test func ウインドウが1つも取れない場合は表示する() {
        // 権限や異常系で一覧が空でも、消えてしまうより出しておく
        #expect(MenuBarVisibility.shouldShowNotch(windows: [], onScreen: dell))
    }
}

// MARK: - ノッチの寸法・配置

struct NotchMetricsTests {

    /// 実測値: DELL S2725DC（外部モニタ、ノッチなし）
    @Test func 外部モニタでは画面の絶対上端に配置する() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1410),
            safeAreaTop: 0,
            auxiliaryWidths: nil
        )
        #expect(!metrics.hasNotch)
        // visibleFrame.maxY(1410)ではなくframe.maxY(1440)に置く。
        // 1410だとメニューバーのぶん下にずれてしまう。
        #expect(metrics.topY == 1440)
        // 高さは決め打ちではなく実測（1440 - 1410 = 30）
        #expect(metrics.topInset == 30)
    }

    /// 実測値: Built-in Retina Display（ノッチあり）
    @Test func ノッチ搭載画面ではノッチ幅と高さを使う() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: -982, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: -982, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryWidths: (left: 663.5, right: 663.5)
        )
        #expect(metrics.hasNotch)
        #expect(metrics.topY == 0)          // frame.maxY
        #expect(metrics.topInset == 32)     // safeAreaInsets.top
        #expect(metrics.notchWidth == 185)  // 1512 - 663.5 * 2
    }

    @Test func ノッチの有無によらず上端は同じ基準で決まる() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let withNotch = NotchMetrics.make(
            frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1048),
            safeAreaTop: 32, auxiliaryWidths: (left: 800, right: 800))
        let withoutNotch = NotchMetrics.make(
            frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050),
            safeAreaTop: 0, auxiliaryWidths: nil)

        #expect(withNotch.topY == withoutNotch.topY)
        #expect(withNotch.topY == frame.maxY)
    }

    @Test func メニューバーを測れない場合は既定値を使う() {
        // メニューバー自動非表示や、副画面にメニューバーが無い構成
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            auxiliaryWidths: nil
        )
        #expect(metrics.topInset == NotchMetrics.fallbackMenuBarHeight)
        #expect(metrics.topY == 1080)
    }

    @Test func safeAreaがあってもaux情報が無ければ擬似ノッチに倒す() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryWidths: nil
        )
        #expect(!metrics.hasNotch)
        #expect(metrics.notchWidth == NotchMetrics.pseudoNotchWidth)
        #expect(metrics.topY == 982)
    }
}

// MARK: - 表示先ディスプレイの選択

struct DisplaySelectorTests {

    private let builtin = ScreenDescriptor(
        id: "uuid-builtin", name: "内蔵ディスプレイ", hasNotch: true,
        isPrimary: false, isActive: false)
    private let external = ScreenDescriptor(
        id: "uuid-studio", name: "Studio Display", hasNotch: false,
        isPrimary: true, isActive: false)
    private let third = ScreenDescriptor(
        id: "uuid-third", name: "サブモニタ", hasNotch: false,
        isPrimary: false, isActive: true)

    private var all: [ScreenDescriptor] { [builtin, external, third] }

    @Test func 自動ではノッチ搭載画面を優先する() {
        #expect(DisplaySelector.select(from: all, preference: .automatic) == builtin)
    }

    @Test func 自動でノッチ搭載画面が無ければ主ディスプレイを使う() {
        let noNotch = [external, third]
        #expect(DisplaySelector.select(from: noNotch, preference: .automatic) == external)
    }

    @Test func 主ディスプレイ指定はノッチ搭載画面より優先される() {
        #expect(DisplaySelector.select(from: all, preference: .primary) == external)
    }

    @Test func 追従指定では作業中の画面を選ぶ() {
        // 主ディスプレイでもノッチ搭載でもない画面が、フォーカスされていれば選ばれる
        #expect(DisplaySelector.select(from: all, preference: .followActive) == third)
    }

    @Test func 追従先が不明なら自動に倒す() {
        let noneActive = [builtin, external]
        #expect(DisplaySelector.select(from: noneActive, preference: .followActive) == builtin)
    }

    @Test func 特定のディスプレイを指定できる() {
        #expect(DisplaySelector.select(from: all, preference: .specific(id: "uuid-third")) == third)
    }

    @Test func 指定した画面を外すと自動にフォールバックする() {
        // 外部モニタを取り外した状況
        let remaining = [builtin]
        let selected = DisplaySelector.select(from: remaining, preference: .specific(id: "uuid-studio"))
        #expect(selected == builtin)
    }

    @Test func 画面が1枚も無ければnilを返す() {
        #expect(DisplaySelector.select(from: [], preference: .automatic) == nil)
        #expect(DisplaySelector.select(from: [], preference: .primary) == nil)
        #expect(DisplaySelector.select(from: [], preference: .followActive) == nil)
    }

    @Test func 設定値の保存と復元が往復する() {
        #expect(DisplayPreference(storedValue: "") == .automatic)
        #expect(DisplayPreference(storedValue: "main") == .primary)
        #expect(DisplayPreference(storedValue: "active") == .followActive)
        #expect(DisplayPreference(storedValue: "uuid-x") == .specific(id: "uuid-x"))

        #expect(DisplayPreference.automatic.storedValue == "")
        #expect(DisplayPreference.primary.storedValue == "main")
        #expect(DisplayPreference.followActive.storedValue == "active")
        #expect(DisplayPreference.specific(id: "uuid-x").storedValue == "uuid-x")
    }

    @Test func 主ディスプレイが見つからなければ自動に倒す() {
        let none = [builtin, third]
        #expect(DisplaySelector.select(from: none, preference: .primary) == builtin)
    }
}

// MARK: - フック方式

struct HookEventTests {

    private func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func フック本文は状態監視に必要な最小情報だけを解釈する() {
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "abc-123",
            "cwd": "/Users/me/Create App/subghost",
            "tool_name": "Bash",
            "tool_input": ["command": "secret command"],
            "transcript_path": "/tmp/transcript.jsonl",
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった")
            return
        }
        #expect(event.kind == .permissionRequest)
        #expect(event.sessionID == "abc-123")
        #expect(event.projectName == "subghost")
        #expect(event.transcriptPath == "/tmp/transcript.jsonl")
        #expect(event.kind.resultingState == .thinking)
    }

    @Test func 完了と失敗を別の状態として扱う() {
        #expect(HookEventKind.stop.resultingState == .completed)
        #expect(HookEventKind.stopFailure.resultingState == .error)
        #expect(HookEventKind.preToolUse.resultingState == .thinking)
        #expect(HookEventKind.subagentStop.resultingState == .thinking)
        #expect(HookEventKind.preCompact.resultingState == nil)
    }

    @Test func 現行Codexイベントを正規化できる() {
        #expect(HookEventKind(normalizing: "permission_request") == .permissionRequest)
        #expect(HookEventKind(normalizing: "post_compact") == .postCompact)
        #expect(HookEventKind(normalizing: "subagent_start") == .subagentStart)
        #expect(HookEventKind(normalizing: "STOP") == .stop)
    }

    @Test func イベント名のキーが違っても解釈する() {
        let alternative = payload(["hookEventName": "Stop", "session_id": "s"])
        #expect(HookEventDecoder.decode(alternative)?.kind == .stop)
    }

    @Test func 未知または壊れたイベントは解釈しない() {
        #expect(HookEventDecoder.decode(payload([
            "hook_event_name": "SomethingNew", "session_id": "x"
        ])) == nil)
        #expect(HookEventDecoder.decode(Data("not json".utf8)) == nil)
        #expect(HookEventDecoder.decode(Data()) == nil)
    }

    @Test func 監視フックはCLIの判断をブロックしない() {
        #expect(HookEventKind.allCases.allSatisfy { !$0.isBlocking })
    }
}

struct HookInstallerTests {

    @Test func ブリッジはtmuxも入力送信も起動しない() {
        let script = HookInstaller.bridgeScript(socketPath: "/tmp/subghost.sock")
        #expect(!script.contains("tmux"))
        #expect(!script.contains("send-keys"))
        #expect(!script.contains(".zshrc"))
        #expect(script.contains("curl"))
        #expect(script.contains("${2:-\(HookInstaller.normalTimeoutSeconds)}"))
    }

    @Test func Codexには現行の監視イベントだけを登録する() {
        #expect(HookTarget.codex.events.contains("SessionStart"))
        #expect(HookTarget.codex.events.contains("SessionEnd"))
        #expect(HookTarget.codex.events.contains("Stop"))
        #expect(HookTarget.codex.events.contains("PermissionRequest"))
        #expect(HookTarget.codex.events.contains("UserPromptSubmit"))
    }

    @Test func フックを追記しても既存設定を壊さない() {
        let original: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/other-tool"]]]]],
        ]
        let patched = HookInstaller.addHooks(to: original, scriptPath: "/tmp/subghost-bridge")

        #expect(patched["model"] as? String == "opus")
        // 他ツールのフックが残っている
        let stop = patched["hooks"] as? [String: Any]
        let stopEntries = stop?["Stop"] as? [[String: Any]]
        #expect(stopEntries?.count == 2)
        #expect(String(describing: patched).contains("other-tool"))
        #expect(HookInstaller.containsMarker(in: patched))
    }

    @Test func 二重登録しない() {
        var root: [String: Any] = [:]
        root = HookInstaller.addHooks(to: root, scriptPath: "/tmp/subghost-bridge")
        root = HookInstaller.addHooks(to: root, scriptPath: "/tmp/subghost-bridge")

        let hooks = root["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
    }

    @Test func 解除すると自分の項目だけ消える() {
        let original: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/other-tool"]]]]],
        ]
        let patched = HookInstaller.addHooks(to: original, scriptPath: "/tmp/subghost-bridge")
        let cleaned = HookInstaller.removeHooks(from: patched)

        #expect(!HookInstaller.containsMarker(in: cleaned))
        #expect(String(describing: cleaned).contains("other-tool"))
        // Subghostだけが使っていたイベントはキーごと消える
        let hooks = cleaned["hooks"] as? [String: Any]
        #expect(hooks?["PermissionRequest"] == nil)
        #expect((hooks?["Stop"] as? [[String: Any]])?.count == 1)
    }

    @Test func CodexはCodex固有のイベントだけを登録する() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]

        #expect(hooks?["PermissionRequest"] != nil)
        #expect(hooks?["SubagentStop"] != nil)
        // NotificationはCodexの設定イベントではない
        #expect(hooks?["Notification"] == nil)
        #expect(hooks?["PreToolUse"] != nil)
        #expect(hooks?["SessionEnd"] != nil)
        #expect(hooks?.count == HookTarget.codex.events.count)
    }

    @Test func CLIごとにsourceを渡し分ける() {
        // ブリッジは第1引数でどのCLI由来かを判別するため、渡し分けが必須
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "claude")
            .hasSuffix("subghost '/tmp/b' 'claude' '\(HookInstaller.normalTimeoutSeconds)' # subghost-bridge"))
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "codex")
            .hasSuffix("subghost '/tmp/b' 'codex' '\(HookInstaller.normalTimeoutSeconds)' # subghost-bridge"))

        // 実際に登録されるコマンドにも反映されていること
        let codex = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = codex["hooks"] as? [String: Any]
        let inner = (hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect((inner?.first?["command"] as? String)?.contains("'codex'") == true)
    }

    @Test func パスに引用符が含まれてもコマンドが壊れない() {
        // ホームディレクトリ名にアポストロフィが入りうる。埋め込むと構文が壊れ、
        // 毎イベントでCLIがフックエラーを出すことになる。
        let command = HookInstaller.hookCommand(scriptPath: "/Users/o'brien/b", source: "claude")
        #expect(command.contains("'/Users/o'\\''brien/b'"))
        // 本文へは埋め込まず、引数として渡していること
        #expect(command.contains("[ -x \"$1\" ]"))
        #expect(!command.contains("[ -x \"/Users/"))
    }

    @Test func ブリッジへ渡す待ち時間は全イベントで短い() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .claude)
        let hooks = root["hooks"] as? [String: Any]

        func command(_ event: String) -> String? {
            let matchers = hooks?[event] as? [[String: Any]]
            let inner = matchers?.first?["hooks"] as? [[String: Any]]
            return inner?.first?["command"] as? String
        }
        #expect(command("PermissionRequest") == nil)
        #expect(command("SessionStart")?
            .contains("'\(HookInstaller.normalTimeoutSeconds)'") == true)
    }

    @Test func 形が違う既存フックは書き換えず残す() {
        // 想定外の形を空配列で置き換えると、ユーザーが自分で書いたフックを消してしまう
        let root: [String: Any] = ["hooks": ["SessionStart": "ユーザーが書いた想定外の値"]]
        let patched = HookInstaller.addHooks(to: root, scriptPath: "/tmp/b", target: .claude)
        let hooks = patched["hooks"] as? [String: Any]
        #expect(hooks?["SessionStart"] as? String == "ユーザーが書いた想定外の値")
        // 他のイベントには通常どおり追加されること
        #expect(hooks?["Stop"] != nil)
    }

    @Test func 既存のフックを残したまま追加する() {
        let root: [String: Any] = ["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "echo ユーザーのフック"]]]],
        ]]
        let patched = HookInstaller.addHooks(to: root, scriptPath: "/tmp/b", target: .claude)
        let matchers = (patched["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        #expect(matchers?.count == 2)

        // 解除するとユーザーのフックだけが残る
        let cleaned = HookInstaller.removeHooks(from: patched)
        let remaining = (cleaned["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        let inner = remaining?.first?["hooks"] as? [[String: Any]]
        #expect(remaining?.count == 1)
        #expect(inner?.first?["command"] as? String == "echo ユーザーのフック")
    }

    @Test func 監視イベントは短いタイムアウトを設定する() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]

        func timeout(_ event: String) -> Int? {
            let matchers = hooks?[event] as? [[String: Any]]
            let inner = matchers?.first?["hooks"] as? [[String: Any]]
            return inner?.first?["timeout"] as? Int
        }
        #expect(timeout("PermissionRequest") == HookInstaller.normalTimeoutSeconds)
        #expect(timeout("Stop") == HookInstaller.normalTimeoutSeconds)
    }

    @Test func Codexのmatcherは空文字にする() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]
        let postToolUse = (hooks?["PostToolUse"] as? [[String: Any]])?.first
        // Codexは空文字を全一致として扱う
        #expect(postToolUse?["matcher"] as? String == "")
        // matcherを取らないイベントには付けない
        let stop = (hooks?["Stop"] as? [[String: Any]])?.first
        #expect(stop?["matcher"] == nil)
    }

    @Test func 元がhooks無しなら解除後もhooks無しに戻る() {
        let patched = HookInstaller.addHooks(to: ["model": "opus"], scriptPath: "/tmp/b")
        let cleaned = HookInstaller.removeHooks(from: patched)
        #expect(cleaned["hooks"] == nil)
        #expect(cleaned["model"] as? String == "opus")
    }

    @Test func フックコマンドはスクリプトが無くても正常終了する形になっている() {
        let command = HookInstaller.hookCommand(scriptPath: "/tmp/subghost-bridge")
        // 存在確認と exit 0 が入っていること（CLIを壊さないための必須条件）
        #expect(command.contains("[ -x"))
        #expect(command.contains("exit 0"))
    }

    @Test func ブリッジスクリプトはソケットが無ければ即終了する() {
        let script = HookInstaller.bridgeScript(socketPath: "/tmp/x.sock")
        #expect(script.contains("[ -S \"$SOCK\" ] || exit 0"))
        #expect(script.contains("--unix-socket"))
    }
}

struct ConversationLocatorTests {

    @Test func lsofの出力から作業ディレクトリを取り出す() {
        let output = """
        p3514
        fcwd
        n/Users/Rhara/Create App/subghost
        """
        #expect(ConversationLocator.parseWorkingDirectory(output)
                == "/Users/Rhara/Create App/subghost")
    }

    @Test func パスでない行は無視する() {
        #expect(ConversationLocator.parseWorkingDirectory("p3514\nfcwd\n") == nil)
    }

}

struct TranscriptReaderTests {

    @Test func 最新のAI応答をJSONLから読む() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"古い応答"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"最新の応答\\n2行目"}]}}
        """
        #expect(TranscriptReader.latestAssistantText(inJSONLines: text) == ["最新の応答", "2行目"])
    }

    @Test func ツール呼び出しだけの記録は本文として扱わない() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
        """
        #expect(TranscriptReader.latestAssistantText(inJSONLines: text).isEmpty)
    }

    @Test func 最新のユーザー本文を読む() {
        let text = """
        {"type":"user","message":{"content":"最初"}}
        {"type":"user","message":{"content":[{"type":"text","text":"最後"}]}}
        """
        #expect(TranscriptReader.latestUserText(inJSONLines: text) == "最後")
    }

    @Test func 壊れた行を含んでも読める() {
        let text = """
        broken
        {"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]}}
        """
        #expect(TranscriptReader.latestAssistantText(inJSONLines: text) == ["OK"])
    }
}

struct ShellIntegrationTests {

    @Test func 目印で囲んだブロックだけを取り除く() {
        let zshrc = """
        export PATH=/usr/bin
        \(ShellIntegration.beginMarker)
        [ -f "x" ] && . "x"
        \(ShellIntegration.endMarker)
        alias ll='ls -la'
        """
        let cleaned = ShellIntegration.removeBlock(from: zshrc)
        #expect(cleaned.contains("export PATH=/usr/bin"))
        #expect(cleaned.contains("alias ll='ls -la'"))
        // Subghostのブロックは消える
        #expect(!cleaned.contains("subghost"))
        #expect(!cleaned.contains("_subghost"))
    }

    @Test func 既存の内容を壊さない() {
        let original = "line1\nline2"
        let cleaned = ShellIntegration.removeBlock(from: original)
        #expect(cleaned.contains("line1"))
        #expect(cleaned.contains("line2"))
    }
}

struct UsageParserTests {

    private func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func statuslineのJSONから使用量を取り出す() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = payload([
            "rate_limits": [
                "five_hour": ["used_percentage": 68, "resets_at": 1_000_000 + 48 * 60],
                "seven_day": ["used_percentage": 40.5,
                              "resets_at": 1_000_000 + 6 * 3600 + 48 * 60],
            ],
            "context_window": ["used_percentage": 40],
        ])
        guard let usage = UsageParser.parse(data, now: now) else {
            Issue.record("解析できなかった"); return
        }
        #expect(usage.fiveHour?.usedPercent == 68)
        #expect(usage.fiveHour?.remainingText(now: now) == "48m")
        #expect(usage.sevenDay?.remainingText(now: now) == "6h48m")
        #expect(usage.contextUsedPercent == 40)
    }

    @Test func ミリ秒のリセット時刻も解釈する() {
        // 秒とミリ秒は桁数で見分けるため、現実的な値（2026年相当）で確認する
        let base = 1_770_000_000.0
        let now = Date(timeIntervalSince1970: base)
        let data = payload(["rate_limits": [
            "five_hour": ["used_percentage": 10, "resets_at": (base + 600) * 1000],
        ]])
        #expect(UsageParser.parse(data, now: now)?.fiveHour?.remainingText(now: now) == "10m")
    }

    @Test func 秒のリセット時刻も解釈する() {
        let base = 1_770_000_000.0
        let now = Date(timeIntervalSince1970: base)
        let data = payload(["rate_limits": [
            "five_hour": ["used_percentage": 10, "resets_at": base + 600],
        ]])
        #expect(UsageParser.parse(data, now: now)?.fiveHour?.remainingText(now: now) == "10m")
    }

    @Test func Codexの記録からレート制限を取り出す() {
        // 実測の形式: event_msg の token_count に rate_limits が入る。
        // キーは used_percent、枠は window_minutes で判別する。
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1785069709},\
        "secondary":{"used_percent":42.0,"window_minutes":300,"resets_at":1785000000}}}}
        """
        guard let usage = UsageParser.parseCodexRateLimits(inJSONLines: jsonl) else {
            Issue.record("解析できなかった"); return
        }
        #expect(usage.agentID == "codex")
        // window_minutes で振り分ける（300分=5時間枠、10080分=7日枠）
        #expect(usage.fiveHour?.usedPercent == 42.0)
        #expect(usage.sevenDay?.usedPercent == 6.0)
    }

    @Test func Codexで片方の枠しか無くても取り出す() {
        // 実測データは primary のみで secondary が null だった
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1785069709},\
        "secondary":null}}}
        """
        let usage = UsageParser.parseCodexRateLimits(inJSONLines: jsonl)
        #expect(usage?.sevenDay?.usedPercent == 6.0)
        #expect(usage?.fiveHour == nil)
    }

    @Test func Codexのレート制限が無い記録では何も返さない() {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"agent_message","message":"やあ"}}
        """
        #expect(UsageParser.parseCodexRateLimits(inJSONLines: jsonl) == nil)
    }

    @Test func 使用量が無ければnilを返す() {
        #expect(UsageParser.parse(payload(["foo": "bar"])) == nil)
        #expect(UsageParser.parse(Data("壊れている".utf8)) == nil)
    }

    @Test func 一日以上残っていれば日で表す() {
        // 7日枠は「150h」のような表示になりやすく、日に直さないと読み取れない
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            usedPercent: 6,
            resetsAt: now.addingTimeInterval(TimeInterval(6 * 86_400 + 6 * 3600 + 30 * 60)))
        #expect(window.remainingText(now: now) == "6d6h")
    }

    @Test func 一日未満なら時分のまま表す() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            usedPercent: 6, resetsAt: now.addingTimeInterval(TimeInterval(23 * 3600 + 59 * 60)))
        #expect(window.remainingText(now: now) == "23h59m")
    }

    @Test func リセット済みなら残り時間を出さない() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 999_000))
        #expect(window.remainingText(now: now) == nil)
    }

    @Test func 消費率に応じて警戒度が変わる() {
        #expect(UsageWindow(usedPercent: 95, resetsAt: nil).isCritical)
        #expect(UsageWindow(usedPercent: 75, resetsAt: nil).isWarning)
        #expect(!UsageWindow(usedPercent: 30, resetsAt: nil).isWarning)
    }

    @Test func statuslineの包みは元のコマンドへ渡し直す() {
        let script = HookInstaller.statuslineScript(
            socketPath: "/tmp/s.sock", next: "bash /Users/me/.claude/statusline-command.sh")
        // 標準入力は一度しか読めないため、読み切ってから元のコマンドへ渡す
        #expect(script.contains("PAY=$(cat)"))
        #expect(script.contains("statusline-command.sh"))
        #expect(script.contains("/usage"))
    }

    @Test func 元のstatuslineが無ければ何も呼ばない() {
        let script = HookInstaller.statuslineScript(socketPath: "/tmp/s.sock", next: nil)
        #expect(!script.contains("NEXT="))
    }

    @Test func 元コマンドの引用符を安全に埋め込む() {
        // シングルクォートを含むコマンドでスクリプトが壊れないこと
        let script = HookInstaller.statuslineScript(
            socketPath: "/tmp/s.sock", next: "echo 'hello world'")
        #expect(script.contains("'\\''"))
    }

    @Test func statuslineは包みが消えても元のコマンドへ落ちる() {
        // ~/.subghost を手で消されても、settings.json だけで元へ戻れること。
        // パスをそのまま書くと、存在しないコマンドが残りstatuslineが死んだままになる。
        let command = HookInstaller.statuslineCommand(
            scriptPath: "/tmp/subghost-statusline", previous: "bash ~/.claude/statusline.sh")
        #expect(command.contains("[ -x \"$1\" ] && exec \"$1\""))
        #expect(command.contains("[ -n \"$2\" ] && exec /bin/sh -c \"$2\""))
        #expect(command.contains("exit 0"))
        #expect(command.hasSuffix("# \(HookInstaller.marker)"))
    }

    @Test func 元のstatuslineが無ければフォールバックも何もしない() {
        let command = HookInstaller.statuslineCommand(
            scriptPath: "/tmp/subghost-statusline", previous: nil)
        // 空文字なので [ -n "$2" ] が偽になり、そのまま exit 0 する
        #expect(command.contains("subghost '/tmp/subghost-statusline' ''"))
    }

    @Test func 埋め込んだ元コマンドを読み戻せる() {
        // 解除時に保存ファイルが失われていても、これがあれば元へ戻せる
        for original in ["bash ~/.claude/statusline.sh", "echo 'hello world'", "a\"b$c"] {
            let command = HookInstaller.statuslineCommand(
                scriptPath: "/tmp/s", previous: original)
            #expect(HookInstaller.embeddedPreviousStatusline(in: command) == original)
        }
    }

    @Test func 元コマンドが無い場合は読み戻しもnilになる() {
        let command = HookInstaller.statuslineCommand(scriptPath: "/tmp/s", previous: nil)
        #expect(HookInstaller.embeddedPreviousStatusline(in: command) == nil)
        // 目印の無い（ユーザー自身の）コマンドは対象外
        #expect(HookInstaller.embeddedPreviousStatusline(in: "bash statusline.sh") == nil)
    }

    @Test func 読み返せない設定は書き込まずに弾く() {
        // 壊れた settings.json はCLIの起動そのものを妨げる。書く前に必ず確かめる。
        // JSONSerialization.data はこの入力に対して Swift の error ではなく NSException を
        // 投げるため、事前に isValidJSONObject で弾かないとアプリごと落ちる。
        #expect(throws: HookInstallError.self) {
            // JSONにできない値（Date）が混じった設定
            try HookInstaller.encodedSettings(["statusLine": Date()], fileName: "settings.json")
        }
        // 正常な設定はそのまま読み返せること
        let data = try? HookInstaller.encodedSettings(
            HookInstaller.addHooks(to: ["model": "opus"], scriptPath: "/tmp/b"),
            fileName: "settings.json")
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        #expect(root?["model"] as? String == "opus")
        #expect(root?["hooks"] != nil)
    }

    @Test func 引用符を含む引数列を読み戻せる() {
        let quoted = ["a", "o'brien", "", "空白 と \"引用符\""]
            .map(HookInstaller.shellQuoted).joined(separator: " ")
        #expect(HookInstaller.singleQuotedArguments(in: quoted) == ["a", "o'brien", "", "空白 と \"引用符\""])
    }
}

struct HookRequestTests {

    @Test func ttyの表記ゆれを吸収する() {
        // ブリッジは "ttys003" 形式、セッション側は "/dev/ttys003" 形式で保持している。
        // 正規化しないと永久に一致せず、イベントが捨てられ続ける。
        #expect(HookRequest.normalizeTTY("ttys003") == "/dev/ttys003")
        #expect(HookRequest.normalizeTTY("/dev/ttys003") == "/dev/ttys003")
    }

    @Test func ttyが取れなかった場合はnilにする() {
        #expect(HookRequest.normalizeTTY("??") == nil)
        #expect(HookRequest.normalizeTTY("unknown") == nil)
        #expect(HookRequest.normalizeTTY("") == nil)
        #expect(HookRequest.normalizeTTY(nil) == nil)
    }

    @Test func 不正なttyヘッダを受け入れない() {
        #expect(HookRequest.normalizeTTY("/dev/../console") == nil)
        #expect(HookRequest.normalizeTTY("ttys001\r\nX-Fake: yes") == nil)
        #expect(HookRequest.normalizeTTY(String(repeating: "a", count: 33)) == nil)
    }

    @Test func ブリッジは祖先をたどってCLI本体を探す() {
        let script = HookInstaller.bridgeScript(socketPath: "/tmp/x.sock")
        // フックの親シェルは制御端末を持たないため、$PPIDだけでは特定できない
        #expect(script.contains("while"))
        #expect(script.contains("X-Subghost-Pid"))
        // ttyは/dev/付きで送る
        #expect(script.contains("/dev/$term"))
    }
}

struct HTTPParserTests {

    @Test func リクエストを解析する() {
        let raw = Data("""
        POST /hook?source=claude HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        X-Subghost-Tty: /dev/ttys004\r
        Content-Length: 13\r
        \r
        {"hello":"a"}
        """.utf8)

        guard let parsed = HTTPRequestParser.parse(raw) else {
            Issue.record("解析できなかった"); return
        }
        #expect(parsed.path == "/hook")
        #expect(parsed.query["source"] == "claude")
        #expect(parsed.headers["x-subghost-tty"] == "/dev/ttys004")
        #expect(String(decoding: parsed.body, as: UTF8.self) == "{\"hello\":\"a\"}")
    }

    @Test func ヘッダ終端が無ければ解析しない() {
        #expect(HTTPRequestParser.parse(Data("POST /hook HTTP/1.1".utf8)) == nil)
    }

    @Test func POST以外の要求は解析しない() {
        let raw = Data("GET /hook HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        #expect(HTTPRequestParser.parse(raw) == nil)
    }
}

// MARK: - ターミナルへの移動 (Jump)

struct TerminalJumpTests {

    @Test func Ghosttyのタイトルでセッションを照合する() {
        var info = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys003", profile: .claude))
        info.hookSessionID = "dd7867b0-0cbc-4857-8ae6-e36e2fc2e292"
        info.workingDirectory = "/Users/me/Create App/subghost"

        // セッションIDの先頭が含まれれば一致
        #expect(TerminalActivator.titleMatches("チャット · dd7867b0-0cbc-48", session: info))
        // フォルダ名が含まれれば一致
        #expect(TerminalActivator.titleMatches("subghost — zsh", session: info))
        // どちらも含まれなければ不一致（別タブの通知抑制を防ぐ）
        #expect(!TerminalActivator.titleMatches("別のプロジェクト — vim", session: info))
    }

    @Test func 正常なttyパスを受け入れる() {
        #expect(TerminalActivator.isValidTTY("/dev/ttys004"))
        #expect(TerminalActivator.isValidTTY("/dev/ttys000"))
    }

    @Test func 不正なttyパスを弾く() {
        // AppleScriptへ埋め込むため、引用符やスペースを含むものは通さない
        #expect(!TerminalActivator.isValidTTY("/dev/ttys004\" & do shell script \"echo"))
        #expect(!TerminalActivator.isValidTTY("/dev/tty s004"))
        #expect(!TerminalActivator.isValidTTY("ttys004"))
        #expect(!TerminalActivator.isValidTTY(""))
        #expect(!TerminalActivator.isValidTTY("/dev/" + String(repeating: "a", count: 40)))
    }

    @Test func psの出力から親子関係を読む() {
        let output = """
          501     1
          610   501
          742   610
        """
        let parents = ProcessTree.parseParentMap(output)
        #expect(parents[501] == 1)
        #expect(parents[610] == 501)
        #expect(parents[742] == 610)
    }

    @Test func psの出力からpidを読む() {
        #expect(ProcessTree.parsePIDs("  610\n  742\n") == [610, 742])
        #expect(ProcessTree.parsePIDs("") == [])
    }

    @Test func 祖先をたどってターミナルを特定する() {
        // 742(tmuxクライアント) → 610(シェル) → 501(ターミナル.app)
        let parents: [Int32: Int32] = [742: 610, 610: 501, 501: 1]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 742, in: terminals, parents: parents) == .terminal)
    }

    @Test func 祖先にターミナルがなければnilを返す() {
        let parents: [Int32: Int32] = [742: 610, 610: 1]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 742, in: terminals, parents: parents) == nil)
    }

    @Test func 親子関係が循環していても停止する() {
        // 異常系: 相互に親を指し合っていても無限ループにしない
        let parents: [Int32: Int32] = [10: 11, 11: 10]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 10, in: terminals, parents: parents) == nil)
    }

    @Test func タブ単位で移動できるのはターミナルappのみ() {
        #expect(TerminalApp.terminal.supportsTabJump)
        #expect(!TerminalApp.ghostty.supportsTabJump)
    }

    @Test func エディタの内蔵ターミナルもヘルパー経由で特定できる() {
        // 実測値: 36186(tmux) → 34224(zsh) → 16536(Code Helper) → 16270(VS Code)
        // 内蔵ターミナルのシェルはヘルパープロセスの子であり、本体は祖先にしか現れない
        let parents: [Int32: Int32] = [36186: 34224, 34224: 16536, 16536: 16270, 16270: 1]
        let terminals: [Int32: TerminalApp] = [16270: .vscode]

        #expect(ProcessTree.findAncestor(of: 36186, in: terminals, parents: parents) == .vscode)
    }

    @Test func エディタは移動先ターミナルとして起動しない() {
        // 内蔵ターミナルは「セッションの所在」を示すだけで、単独の移動先にはならない
        #expect(TerminalApp.terminal.isLaunchable)
        #expect(TerminalApp.ghostty.isLaunchable)
        #expect(!TerminalApp.vscode.isLaunchable)
        #expect(!TerminalApp.cursor.isLaunchable)
        #expect(!TerminalApp.windsurf.isLaunchable)
    }
}

// MARK: - 承認/質問の検出 (Approve / Ask)

struct SleepConditionTests {

    private func session(
        tty: String = "/dev/ttys001",
        pid: Int32 = 100,
        profileID: String = "claude",
        state: AIState
    ) -> SleepSessionSnapshot {
        SleepSessionSnapshot(tty: tty, pid: pid, profileID: profileID, state: state)
    }

    @Test func 予約したCLIの完了でスリープへ進む() {
        let finished = session(state: .completed)
        #expect(SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: finished,
            sessions: [finished],
            includesError: true
        ))
    }

    @Test func 同じ対象に作業中セッションがあれば進まない() {
        let finished = session(state: .completed)
        let working = session(tty: "/dev/ttys002", pid: 200, state: .thinking)
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")],
            sessions: [finished, working]
        ) == .targetBusy)
    }

    @Test func エラーを終了に含めるか選べる() {
        #expect(SleepCondition.isFinished(.error, includesError: true))
        #expect(!SleepCondition.isFinished(.error, includesError: false))
        #expect(!SleepCondition.isFinished(.idle, includesError: true))
        #expect(!SleepCondition.isFinished(.thinking, includesError: true))
        #expect(SleepCondition.isFinished(.completed, includesError: false))
    }

    @Test func 対象が無ければ進まない() {
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")],
            sessions: []
        ) == .targetMissing)
    }

    @Test func セッション指定はPIDまで一致させる() {
        let value = session(state: .completed)
        #expect(SleepCondition.covers(.session(tty: "/dev/ttys001", pid: 100), value))
        #expect(!SleepCondition.covers(.session(tty: "/dev/ttys001", pid: 999), value))
    }

    @Test func 猶予秒数を安全な範囲へ補正する() {
        #expect(SleepPreferences.normalizedCountdown(0) == 5)
        #expect(SleepPreferences.normalizedCountdown(30) == 30)
        #expect(SleepPreferences.normalizedCountdown(10_000) == 300)
    }
}

/// 猶予の消化とスリープの実行。
/// 実際に寝かせるわけにはいかないので、実行は差し替え、時間は tick() で手動に進める。
@MainActor
final class SleepTestProbe {
    /// スリープを実行した回数
    var sleepCount = 0
    /// 判定へ渡すセッション一覧（テストの途中で差し替える）
    var sessions: [SleepSessionSnapshot] = []
}

@MainActor
struct SleepSchedulerTests {

    private func セッション(
        tty: String = "/dev/ttys001",
        pid: Int32 = 100,
        profileID: String = "claude",
        state: AIState
    ) -> SleepSessionSnapshot {
        SleepSessionSnapshot(tty: tty, pid: pid, profileID: profileID, state: state)
    }

    private func 用意する(_ sessions: [SleepSessionSnapshot]) -> (SleepScheduler, SleepTestProbe) {
        let probe = SleepTestProbe()
        probe.sessions = sessions
        let scheduler = SleepScheduler()
        scheduler.automaticTicking = false
        scheduler.sessionsProvider = { probe.sessions }
        scheduler.sleepAction = { probe.sleepCount += 1 }
        return (scheduler, probe)
    }

    /// 猶予ぶん進めるのに要する回数（設定値に追随させる）
    private var 猶予の秒数: Int { Int(SleepPreferences.countdown) }

    @Test func 猶予を数え終えたらスリープする() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown != nil)

        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
        #expect(scheduler.countdown == nil)
        // 既定では1回で予約を解除する
        #expect(!scheduler.isReserved)
    }

    @Test func 予約していなければ完了しても何も起きない() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown == nil)
        #expect(probe.sleepCount == 0)
    }

    /// 取り消しても予約は残す。次に完了したときは改めて確認する。
    @Test func 猶予の取り消しでは予約が残る() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)
        scheduler.cancelCountdown(message: nil)

        #expect(scheduler.countdown == nil)
        #expect(scheduler.isReserved)
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 0)

        // 次の完了で改めて猶予に入る
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown != nil)
    }

    /// 複数のCLIを予約したときは、最後の1つが終わってから寝る
    @Test func 複数予約は最後の1つが終わるまでスリープしない() async {
        let claudeDone = セッション(state: .completed)
        let codexWorking = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .thinking)
        let (scheduler, probe) = 用意する([claudeDone, codexWorking])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.reserve(.agent(profileID: "codex"), label: "Codex CLI")

        // Claudeが終わってもCodexが動いている間は猶予にすら入らない
        scheduler.noteFinished(claudeDone)
        #expect(scheduler.countdown == nil)

        let codexDone = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .completed)
        probe.sessions = [claudeDone, codexDone]
        scheduler.noteFinished(codexDone)
        #expect(scheduler.countdown?.targetCount == 2)

        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
    }

    /// 予約の途中で片方のCLIが終了しても、残りを待ち続ける
    @Test func 片方のセッションが終了しても残りの予約は待ち続ける() async {
        let claude = セッション(state: .completed)
        let codex = セッション(tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .thinking)
        let (scheduler, probe) = 用意する([claude, codex])
        scheduler.reserve(.session(tty: "/dev/ttys001", pid: 100), label: "Claude Code（a）")
        scheduler.reserve(.session(tty: "/dev/ttys002", pid: 200), label: "Codex CLI（b）")

        probe.sessions = [codex]   // Claude側のCLIが終了した
        await scheduler.tick()

        #expect(scheduler.reservations.count == 1)
        #expect(scheduler.isReservedSession(tty: "/dev/ttys002", pid: 200))
        #expect(probe.sleepCount == 0)
    }

    /// 対象のCLIが終了してしまったら、狙う相手がいない。黙って残さず解除する。
    @Test func セッション指定の対象が消えたら予約を解除する() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.session(tty: "/dev/ttys001", pid: 100), label: "Claude Code")

        probe.sessions = []
        await scheduler.tick()
        #expect(!scheduler.isReserved)
        #expect(scheduler.statusMessage != nil)
        #expect(probe.sleepCount == 0)
    }
}
