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

    @Test func ショートカットの未設定と不正値は既定値へ戻る() {
        #expect(HotkeyPreset.resolve(storedValue: nil) == .optionSpace)
        #expect(HotkeyPreset.resolve(storedValue: "unknown") == .optionSpace)
        #expect(HotkeyPreset.resolve(storedValue: "controlSpace") == .controlSpace)
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
        #expect(!GhostSprite.shouldAnimate(for: .awaitingApproval))
        #expect(!GhostSprite.shouldAnimate(for: .awaitingAnswer))
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

struct PromptDraftStoreTests {
    @Test func セッションを切り替えても下書きが混ざらない() {
        var drafts = PromptDraftStore()

        drafts.setText("Claudeへの質問", for: "101:/dev/ttys001")
        drafts.setText("Codexへの依頼\n二行目", for: "202:/dev/ttys002")

        #expect(drafts.text(for: "101:/dev/ttys001") == "Claudeへの質問")
        #expect(drafts.text(for: "202:/dev/ttys002") == "Codexへの依頼\n二行目")
    }

    @Test func 送信したセッションの下書きだけを消せる() {
        var drafts = PromptDraftStore()
        drafts.setText("送信する内容", for: "101:/dev/ttys001")
        drafts.setText("残す内容", for: "202:/dev/ttys002")

        drafts.setText("", for: "101:/dev/ttys001")

        #expect(drafts.text(for: "101:/dev/ttys001").isEmpty)
        #expect(drafts.text(for: "202:/dev/ttys002") == "残す内容")
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

    @Test func 通知ペイロードからセッション情報を復元できる() {
        let original = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)

        let restored = NotificationSessionReference(userInfo: original.userInfo)

        #expect(restored == original)
    }

    @Test func 同じTTYでもPIDが違えば別セッションとして管理する() {
        let oldSession = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        let newSession = NotificationSessionReference(tty: "/dev/ttys004", pid: 200)

        #expect(oldSession != newSession)
    }

    @Test func 新しい質問通知を発行すると古いトークンは無効になる() {
        let session = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        var registry = ChoiceNotificationRegistry()

        let oldToken = registry.issue(for: session, token: "old")
        let newToken = registry.issue(for: session, token: "new")

        #expect(!registry.isCurrent(oldToken, for: session))
        #expect(registry.isCurrent(newToken, for: session))
    }

    @Test func 通知トークンは一度だけ使用できる() {
        let session = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        var registry = ChoiceNotificationRegistry()
        let token = registry.issue(for: session, token: "single-use")

        let firstResult = registry.consume(token, for: session)
        let secondResult = registry.consume(token, for: session)

        #expect(firstResult)
        #expect(!secondResult)
    }
}

struct StateDetectorTests {

    private func makeDetector() -> StateDetector {
        var detector = StateDetector(profile: .claude)
        detector.stableInterval = 1.5
        detector.completedHoldInterval = 8.0
        return detector
    }

    @Test func 初回取り込みは基準値でありイベントを出さない() {
        var detector = makeDetector()
        let event = detector.ingest(rawText: "何らかの初期画面", at: Date(timeIntervalSince1970: 0))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }

    @Test func 出力伸長でthinkingへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let event = detector.ingest(rawText: "画面A\n新しい出力", at: t0.addingTimeInterval(0.8))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func 静止しプロンプト記号が現れたらcompletedになる() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        _ = detector.ingest(rawText: "画面A\n応答本文です", at: t0.addingTimeInterval(0.8))
        // まだ静止時間が足りない
        let final = "画面A\n応答本文です\n╭──╮\n│ > │\n╰──╯"
        let early = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        #expect(early == .becameThinking || early == .none)  // テキスト変化→thinking維持
        // 1.5秒静止後
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(3.5))
        guard case .becameCompleted(let preview) = event else {
            Issue.record("completedにならなかった: \(event)")
            return
        }
        #expect(detector.state == .completed)
        #expect(preview.contains { $0.contains("応答本文です") })
    }

    @Test func busy表示が残っている間はthinkingを維持する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let busy = "画面A\n✻ Thinking… (esc to interrupt)\n│ > │"
        _ = detector.ingest(rawText: busy, at: t0.addingTimeInterval(0.8))
        let event = detector.ingest(rawText: busy, at: t0.addingTimeInterval(5.0))
        #expect(event == .none)
        #expect(detector.state == .thinking)
    }

    @Test func エラーパターンでerrorへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        _ = detector.ingest(rawText: "画面A\n出力中", at: t0.addingTimeInterval(0.8))
        let event = detector.ingest(rawText: "画面A\nAPI Error: rate limited", at: t0.addingTimeInterval(1.6))
        guard case .becameError = event else {
            Issue.record("errorにならなかった: \(event)")
            return
        }
        #expect(detector.state == .error)
    }

    @Test func completedは一定時間後にidleへ戻る() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        _ = detector.ingest(rawText: "A\n本文", at: t0.addingTimeInterval(0.8))
        let final = "A\n本文\n│ > │"
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(4.0))
        #expect(detector.state == .completed)
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(13.0))
        #expect(event == .becameIdle)
        #expect(detector.state == .idle)
    }

    @Test func プロンプト送信でthinkingへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        let event = detector.noteUserSentPrompt(at: t0.addingTimeInterval(1.0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func プロンプト記号が検出できなくても長時間静止でidleへ戻る() {
        var detector = makeDetector()
        detector.idleFallbackInterval = 30.0
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let stuck = "画面A\nプロンプト記号のない出力"
        _ = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(0.8))
        #expect(detector.state == .thinking)
        // 30秒未満はthinkingのまま
        let early = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(20.0))
        #expect(early == .none)
        #expect(detector.state == .thinking)
        // 30秒静止でidleへ
        let event = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(31.0))
        #expect(event == .becameIdle)
        #expect(detector.state == .idle)
    }

    @Test func スピナーの変化だけではthinkingにならない() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面 ⠋", at: t0)
        let event = detector.ingest(rawText: "画面 ⠙", at: t0.addingTimeInterval(0.8))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }
}

struct TextProcessingTests {

    @Test func sanitizeは改行を空白にし制御文字を除去する() {
        let input = "行1\n行2\r\n行3\t終わり\u{1B}[31m"
        let output = TmuxClient.sanitize(input)
        #expect(!output.contains("\n"))
        #expect(!output.contains("\u{1B}"))
        #expect(output.contains("行1"))
        #expect(output.contains("行2"))
    }

    @Test func プレビューは枠線とプロンプト行を除いた本文を返す() {
        let raw = """
        古い出力

        これが応答の本文です。
        二行目の内容。

        ╭────────────╮
        │ >          │
        ╰────────────╯
          ? for shortcuts
        """
        let preview = StateDetector.extractPreview(from: raw, profile: .claude)
        #expect(!preview.isEmpty)
        #expect(preview.contains { $0.contains("これが応答の本文です") })
        #expect(!preview.contains { $0.contains("shortcuts") })
    }

}

// MARK: - ゼロコンフィグ検出

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

    @Test func tmuxのペイン宛先を解析する() {
        let output = """
        /dev/ttys006|work:0.0
        /dev/ttys007|work:0.1
        /dev/ttys008|other:1.0
        """
        let map = TmuxClient.parsePaneTargets(output)
        #expect(map["/dev/ttys006"] == "work:0.0")
        #expect(map["/dev/ttys007"] == "work:0.1")
        #expect(map["/dev/ttys008"] == "other:1.0")
        #expect(map.count == 3)
    }

    @Test func tmux外のセッションは監視不可として扱う() {
        let inTmux = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys006", profile: .claude,
            tmuxTarget: "work:0.0", tmuxSession: "work"))
        let outside = SessionInfo(agent: DiscoveredAgent(
            pid: 2, tty: "/dev/ttys003", profile: .claude,
            tmuxTarget: nil, tmuxSession: nil))

        #expect(inTmux.isMonitorable)
        #expect(!outside.isMonitorable)
        // 作業ディレクトリが未解決なら、tmuxセッション名 → tty の順にフォールバック
        #expect(inTmux.displayName == "work")
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

    @Test func 権限リクエストを解釈する() {
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "abc-123",
            "cwd": "/Users/me/Create App/subghost",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "ビルド成果物を削除"],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.kind == .permissionRequest)
        #expect(event.sessionID == "abc-123")
        #expect(event.projectName == "subghost")
        #expect(event.toolSummary == "rm -rf build")
        #expect(event.title.contains("Bash"))
        #expect(event.kind.isBlocking)
        #expect(event.kind.resultingState == .awaitingApproval)
    }

    @Test func AskUserQuestionの権限リクエストから選択肢を取り出す() {
        // tool_input に questions/options が入っているため、記録を読まずに選択肢を作れる
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "どうしますか?",
                "options": [["label": "続ける"], ["label": "やめる"]],
            ]]],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.toolName == "AskUserQuestion")
        #expect(event.embeddedQuestion?.title == "どうしますか?")
        #expect(event.embeddedQuestion?.options.map(\.label) == ["続ける", "やめる"])
    }

    @Test func AskUserQuestionの複数の問いを全て取り出す() {
        // 1問目だけ取り出すと、2問目以降がノッチに出ないまま終わってしまう
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "1問目", "options": [["label": "A"], ["label": "B"]]],
                ["question": "2問目",
                 "multiSelect": true,
                 "options": [["label": "C"], ["label": "D"]]],
            ]],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.embeddedQuestions.count == 2)
        #expect(event.embeddedQuestions.map(\.title) == ["1問目", "2問目"])
        #expect(event.embeddedQuestions[1].isMultiSelect)
        // 先頭を返す互換プロパティは1問目を指したまま
        #expect(event.embeddedQuestion?.title == "1問目")
    }

    @Test func 各イベントが状態に対応する() {
        #expect(HookEventKind.stop.resultingState == .completed)
        #expect(HookEventKind.stopFailure.resultingState == .error)
        #expect(HookEventKind.notification.resultingState == .awaitingAnswer)
        #expect(HookEventKind.preToolUse.resultingState == .thinking)
        // ブロックするのは権限リクエストだけ
        #expect(!HookEventKind.stop.isBlocking)
        #expect(!HookEventKind.notification.isBlocking)
    }

    @Test func イベント名の表記ゆれを吸収する() {
        // CodexのようにスネークケースでもPascalCaseでも解釈できること
        #expect(HookEventKind(normalizing: "PermissionRequest") == .permissionRequest)
        #expect(HookEventKind(normalizing: "permission_request") == .permissionRequest)
        #expect(HookEventKind(normalizing: "subagent_stop") == .subagentStop)
        #expect(HookEventKind(normalizing: "STOP") == .stop)
    }

    @Test func イベント名のキーが違っても解釈する() {
        let alternative = payload(["hookEventName": "Stop", "session_id": "s"])
        #expect(HookEventDecoder.decode(alternative)?.kind == .stop)
    }

    @Test func サブエージェント終了では完了扱いにしない() {
        // 親エージェントはまだ作業中のため、通知を出してはいけない
        #expect(HookEventKind.subagentStop.resultingState == .thinking)
    }

    @Test func 未知のイベント名は解釈しない() {
        let data = payload(["hook_event_name": "SomethingNew", "session_id": "x"])
        #expect(HookEventDecoder.decode(data) == nil)
    }

    @Test func 壊れたJSONは解釈しない() {
        #expect(HookEventDecoder.decode(Data("これはJSONではない".utf8)) == nil)
        #expect(HookEventDecoder.decode(Data()) == nil)
    }

    @Test func 長すぎる要約は切り詰める() {
        let long = String(repeating: "a", count: 300)
        let summary = HookEventDecoder.summarize(toolInput: ["command": long], maxLength: 50)
        #expect(summary?.count == 51)   // 50文字 + 省略記号
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test func 判定JSONを生成する() {
        #expect(HookDecision.passthrough.json == "{}")
        #expect(HookDecision.allow.json.contains("\"permissionDecision\":\"allow\""))
        #expect(HookDecision.deny(reason: "危険").json.contains("\"permissionDecision\":\"deny\""))
    }
}

struct HookInstallerTests {

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
        // CodexにはNotification / PreToolUse / SessionEnd が無い
        #expect(hooks?["Notification"] == nil)
        #expect(hooks?["PreToolUse"] == nil)
        #expect(hooks?["SessionEnd"] == nil)
        #expect(hooks?.count == HookTarget.codex.events.count)
    }

    @Test func CLIごとにsourceを渡し分ける() {
        // ブリッジは第1引数でどのCLI由来かを判別するため、渡し分けが必須
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "claude").hasSuffix(
            "[ -x \"/tmp/b\" ] && \"/tmp/b\" claude; exit 0' # subghost-bridge"))
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "codex").hasSuffix(
            "[ -x \"/tmp/b\" ] && \"/tmp/b\" codex; exit 0' # subghost-bridge"))

        // 実際に登録されるコマンドにも反映されていること
        let codex = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = codex["hooks"] as? [String: Any]
        let inner = (hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect((inner?.first?["command"] as? String)?.contains("\" codex;") == true)
    }

    @Test func 承認だけ長いタイムアウトを設定する() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]

        func timeout(_ event: String) -> Int? {
            let matchers = hooks?[event] as? [[String: Any]]
            let inner = matchers?.first?["hooks"] as? [[String: Any]]
            return inner?.first?["timeout"] as? Int
        }
        // 承認は応答があるまで接続を保持するため長く、他は短く
        #expect(timeout("PermissionRequest") == HookInstaller.permissionTimeoutSeconds)
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

struct KeystrokeSenderTests {

    @Test func 長い文字列を送信可能な単位に分割する() {
        let text = String(repeating: "a", count: 40)
        let chunks = KeystrokeSender.chunked(text, size: 16)
        #expect(chunks.count == 3)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 16 })
    }

    @Test func 空文字は分割しない() {
        #expect(KeystrokeSender.chunked("").isEmpty)
    }

    @Test func 絵文字を含んでも文字を壊さずに分割する() {
        // サロゲートペアの途中で切ると文字化けするため、文字単位で区切る
        let text = "あ🎉い🎉う🎉え🎉お🎉か🎉"
        let chunks = KeystrokeSender.chunked(text, size: 8)
        #expect(chunks.joined() == text)
    }

    @Test func 改行は空白にし制御文字を落とす() {
        let cleaned = KeystrokeSender.sanitize("一行目\n二行目\tタブ\u{1B}[31m")
        #expect(!cleaned.contains("\n"))
        #expect(!cleaned.contains("\u{1B}"))
        #expect(cleaned.contains("一行目"))
        #expect(cleaned.contains("二行目"))
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

    @Test func 作業ディレクトリをClaudeのプロジェクト名へ変換する() {
        // スラッシュと空白を "-" に置換する（実測の命名規則）
        #expect(ConversationLocator.claudeProjectDirName(cwd: "/Users/Rhara/Create App/subghost")
                == "-Users-Rhara-Create-App-subghost")
        #expect(ConversationLocator.claudeProjectDirName(cwd: "/tmp/x")
                == "-tmp-x")
    }
}

struct TranscriptReaderTests {

    /// 実際のセッション記録と同じ形
    private let jsonl = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"やって"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"どれから手をつけますか?","header":"次の作業","options":[{"label":"コミットする","description":"未コミットの変更を区切る"},{"label":"不具合を直す","description":"表示先の問題"},{"label":"検証する","description":"Codexで確認"}]}]}}]}}
    """

    @Test func 記録から質問と選択肢を復元する() {
        guard let choice = TranscriptReader.latestQuestion(inJSONLines: jsonl) else {
            Issue.record("復元できなかった"); return
        }
        #expect(choice.kind == .question)
        #expect(choice.title == "どれから手をつけますか?")
        #expect(choice.options.map(\.label) == ["コミットする", "不具合を直す", "検証する"])
        #expect(choice.options.map(\.keystroke) == ["1", "2", "3"])
    }

    @Test func 記録から応答本文を取り出す() {
        let text = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"やって"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"修正しました。\\n\\n\\nテストも通っています。"}]}}
        """
        let answer = TranscriptReader.latestAssistantText(inJSONLines: text)
        // ツール実行だけのレコードは飛ばし、本文を持つものを拾う
        #expect(answer.first == "修正しました。")
        #expect(answer.contains("テストも通っています。"))
        // 空行の連続は1行にまとめる
        #expect(answer.filter(\.isEmpty).count <= 1)
    }

    @Test func 本文が無ければ空を返す() {
        let toolOnly = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        """
        #expect(TranscriptReader.latestAssistantText(inJSONLines: toolOnly).isEmpty)
    }

    @Test func 長すぎる応答は行数を制限する() {
        let long = (1...200).map { "行\($0)" }.joined(separator: "\\n")
        let record = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"\(long)\"}]}}"
        let answer = TranscriptReader.latestAssistantText(inJSONLines: record)
        #expect(answer.count <= TranscriptReader.maxAnswerLines)
    }

    @Test func 回答済みの質問は復元しない() {
        // tool_use の後に、同じ tool_use_id の tool_result があれば回答済み
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"古い質問","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"回答しました"}]}}
        """
        #expect(TranscriptReader.latestQuestion(inJSONLines: jsonl) == nil)
    }

    @Test func 未回答の質問だけを返す() {
        // 古い質問は回答済み、新しい質問は未回答
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"古い質問","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"回答済み"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q2","name":"AskUserQuestion","input":{"questions":[{"question":"新しい質問","options":[{"label":"はい"},{"label":"いいえ"}]}]}}]}}
        """
        let choice = TranscriptReader.latestQuestion(inJSONLines: jsonl)
        #expect(choice?.title == "新しい質問")
    }

    @Test func 質問が無ければnilを返す() {
        let plain = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"完了しました"}]}}
        """
        #expect(TranscriptReader.latestQuestion(inJSONLines: plain) == nil)
    }

    @Test func 選択肢が1つ以下なら質問とみなさない() {
        let input: [String: Any] = ["questions": [["question": "？", "options": [["label": "はい"]]]]]
        #expect(TranscriptReader.parseQuestion(input: input) == nil)
    }

    @Test func 壊れた行があっても他の行から復元する() {
        let broken = "これはJSONではない\n" + jsonl
        #expect(TranscriptReader.latestQuestion(inJSONLines: broken)?.options.count == 3)
    }

    @Test func 複数の問いを順番どおり全件取り出す() {
        // AskUserQuestion は複数の問いを1回にまとめる。1問目で打ち切らないこと。
        let input: [String: Any] = ["questions": [
            ["question": "1問目", "options": [["label": "A"], ["label": "B"]]],
            ["question": "2問目", "options": [["label": "C"], ["label": "D"]]],
            ["question": "3問目", "options": [["label": "E"], ["label": "F"]]],
        ]]
        let questions = TranscriptReader.parseQuestions(input: input)

        #expect(questions.map(\.title) == ["1問目", "2問目", "3問目"])
        #expect(questions.map(\.questionIndex) == [1, 2, 3])
        #expect(questions.allSatisfy { $0.questionCount == 3 })
        #expect(questions[1].progressLabel == "2 / 3")
    }

    @Test func 単一の問いには進捗表示を付けない() {
        let input: [String: Any] = ["questions": [
            ["question": "1問だけ", "options": [["label": "A"], ["label": "B"]]],
        ]]
        #expect(TranscriptReader.parseQuestions(input: input).first?.progressLabel == nil)
    }

    @Test func 複数選択の問いを見分けて確定キーを分ける() {
        let input: [String: Any] = ["questions": [
            ["question": "複数選べます",
             "multiSelect": true,
             "options": [["label": "A"], ["label": "B"], ["label": "C"]]],
        ]]
        guard let choice = TranscriptReader.parseQuestions(input: input).first else {
            Issue.record("解釈できなかった"); return
        }
        #expect(choice.isMultiSelect)
        // 複数選択では番号キーはトグルなので、選択肢ごとにEnterを送ってはいけない
        #expect(choice.options.allSatisfy { !$0.needsEnter })
    }

    @Test func 単一選択は番号のあとにEnterを送る() {
        let input: [String: Any] = ["questions": [
            ["question": "1つ選んでください", "options": [["label": "A"], ["label": "B"]]],
        ]]
        guard let choice = TranscriptReader.parseQuestions(input: input).first else {
            Issue.record("解釈できなかった"); return
        }
        #expect(!choice.isMultiSelect)
        #expect(choice.options.allSatisfy { $0.needsEnter })
    }

    @Test func 選択肢が1つ以下の問いだけ除いて残りを返す() {
        let input: [String: Any] = ["questions": [
            ["question": "不正", "options": [["label": "はい"]]],
            ["question": "正しい", "options": [["label": "A"], ["label": "B"]]],
        ]]
        // 除外しても、元の並びに基づく問番号は保つ
        let questions = TranscriptReader.parseQuestions(input: input)
        #expect(questions.map(\.title) == ["正しい"])
        #expect(questions.first?.questionIndex == 2)
    }
}

/// 複数選択UIの確定ボタンまでの距離を測るロジック
/// 画面テキストは実際の tmux capture-pane の出力から起こしている
struct SubmitNavigationTests {

    /// 先頭の選択肢にカーソルがある状態
    private let atFirstOption = """
    ←  ☒ 送信検証  ✔ Submit  →

    【複数選択の検証】

    ❯ 1. [ ] 項目A
      1番目の項目です.
      2. [✔] 項目B
      2番目の項目です.
      3. [✔] 項目C
      3番目の項目です.
      4. [✔] 項目D
      4番目の項目です.
      5. [ ] Type something
         Submit

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    @Test func 説明文を飛ばして選択肢の数だけ数える() {
        // 項目B・C・D・Type something・Submit の5回で届く（説明文は数えない）
        #expect(TmuxClient.stepsToSubmit(inPaneText: atFirstOption) == 5)
    }

    @Test func カーソルが自由記述欄にあれば1回で届く() {
        let atTypeSomething = atFirstOption
            .replacingOccurrences(of: "❯ 1. [ ] 項目A", with: "  1. [ ] 項目A")
            .replacingOccurrences(of: "  5. [ ] Type something", with: "❯ 5. [ ] Type something")
        #expect(TmuxClient.stepsToSubmit(inPaneText: atTypeSomething) == 1)
    }

    @Test func 上部のタブ表示をSubmitと取り違えない() {
        // "✔ Submit" を含むタブ行が上にあるが、確定ボタンは一覧の末尾だけ
        #expect(TmuxClient.stepsToSubmit(inPaneText: atFirstOption) != 0)
    }

    @Test func 確定ボタンが無ければnilを返す() {
        let withoutSubmit = """
        ❯ 1. [ ] 項目A
          2. [ ] 項目B
        """
        #expect(TmuxClient.stepsToSubmit(inPaneText: withoutSubmit) == nil)
    }

    @Test func カーソルが見つからなければnilを返す() {
        let withoutCursor = """
          1. [ ] 項目A
             Submit
        """
        #expect(TmuxClient.stepsToSubmit(inPaneText: withoutCursor) == nil)
    }

    /// 複数の問いが1画面にタブでまとまっている場合の実際の画面
    /// (実機テストで再現した不具合: 最終問以外は確定ボタンが "Next" と表示される)
    private let atFirstOptionOfTabbedQuestion = """
    ←  ☒ 複数選択  ☐ 4択  ☐ 長文ラベル  ✔ Submit  →

    【テスト1・複数選択】有効にしたい機能をすべて選んでください.

    ❯ 1. [✔] ノッチ表示
      ノッチ領域にパネルを表示します.
      2. [✔] 効果音
      イベント発生時にサウンドを鳴らします.
      3. [✔] 自動監視
      送信時に自動でセッション監視を開始します.
      4. [ ] 使用量表示
      トークン使用量をパネルに表示します.
      5. [ ] Type something
         Next

    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    @Test func 最終問以外の確定ボタンNextも認識する() {
        // 4項目中3つしか選ばなくても、総数4を基準にした5回で正しくNextへ届く
        #expect(TmuxClient.stepsToSubmit(inPaneText: atFirstOptionOfTabbedQuestion) == 5)
    }

    @Test func 選んだ数ではなく総数を基準にしないと自由記述欄で止まる() {
        // 実際に起きた不具合の再現: 選択済み3件を基準にすると4回しか↓を送らず、
        // Next の1つ手前「Type something」で止まってしまう
        let wrongStepsBasedOnSelectedCount = 3 + 1
        #expect(wrongStepsBasedOnSelectedCount != TmuxClient.stepsToSubmit(inPaneText: atFirstOptionOfTabbedQuestion))
    }

    /// 最終問でSubmitを押した直後に実際に現れた確認画面
    /// (実機テストで再現した不具合: ここでもう一段 "1" を送らないと確定しないまま止まる)
    private let reviewScreenAfterSubmit = """
    ←  ☒ 提出検証2  ✔ Submit  →

    Review your answers

     ● 【提出検証、2回目】複数の項目にチェックを入れてから「決定」を押してください.
       → 項目B, 項目D

    Ready to submit your answers?

    ❯ 1. Submit answers
      2. Cancel
    """

    @Test func Submit直後の確認画面を検知する() {
        #expect(TmuxClient.isReviewScreen(reviewScreenAfterSubmit))
    }

    @Test func 通常の選択肢画面は確認画面と誤認しない() {
        #expect(!TmuxClient.isReviewScreen(atFirstOptionOfTabbedQuestion))
    }
}

struct ShellIntegrationTests {

    @Test func 対象コマンドを包む関数を生成する() {
        let body = ShellIntegration.scriptBody()
        #expect(body.contains("claude() { _subghost_run claude"))
        #expect(body.contains("codex() { _subghost_run codex"))
        #expect(body.contains("agy() { _subghost_run agy"))
        // codexA/codexBは既存エイリアスのまま残し、展開先のcodexを包む。
        #expect(!body.contains("codexA()"))
        #expect(!body.contains("codexB()"))
        // agyy="agy --dangerously-skip-permissions" は既存のまま残し、
        // 展開先のagyだけを包むことでオプションを失わない。
        #expect(!body.contains("agyy()"))
        // 非対話・tmux内・tmux未導入では素通しする条件が入っていること
        #expect(body.contains("[ -n \"$TMUX\" ]"))
        #expect(body.contains("[ ! -t 1 ]"))
    }

    @Test func カスタムエイリアス名も対象コマンドとして包む() {
        // 設定画面で登録した独自の実行ファイル名（例: 独自のラッパースクリプト）
        let body = ShellIntegration.scriptBody(extraCommands: ["codexA", "codexB"])
        #expect(body.contains("codexA() { _subghost_run codexA"))
        #expect(body.contains("codexB() { _subghost_run codexB"))
    }

    @Test func ビルトインと重複するカスタムエイリアス名は二重に包まない() {
        let body = ShellIntegration.scriptBody(extraCommands: ["codex", "Codex"])
        #expect(body.components(separatedBy: "codex() {").count - 1 == 1)
    }

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
}

// MARK: - ターミナルへの移動 (Jump)

struct TerminalJumpTests {

    @Test func Ghosttyのタイトルでセッションを照合する() {
        var info = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys003", profile: .claude, tmuxTarget: nil, tmuxSession: nil))
        info.hookSessionID = "dd7867b0-0cbc-4857-8ae6-e36e2fc2e292"
        info.workingDirectory = "/Users/me/Create App/subghost"

        // セッションIDの先頭が含まれれば一致
        #expect(TerminalActivator.titleMatches("チャット · dd7867b0-0cbc-48", session: info))
        // フォルダ名が含まれれば一致
        #expect(TerminalActivator.titleMatches("subghost — zsh", session: info))
        // どちらも含まれなければ不一致（別タブへの誤送信を防ぐ）
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
}

// MARK: - 承認/質問の検出 (Approve / Ask)

struct ChoicePromptTests {

    /// Claude Codeの権限リクエストを模したcapture-pane出力
    private let approvalScreen = """
    ● foo.swift を編集します

    ╭──────────────────────────────────────────────╮
    │ Edit file                                    │
    │                                              │
    │ Do you want to make this edit to foo.swift?  │
    │ ❯ 1. Yes                                     │
    │   2. Yes, allow all edits this session       │
    │   3. No, and tell Claude what to do (esc)    │
    ╰──────────────────────────────────────────────╯
      ? for shortcuts
    """

    @Test func 権限リクエストを承認リクエストとして検出する() {
        guard let choice = ChoicePrompt.detect(in: approvalScreen, profile: .claude) else {
            Issue.record("選択肢を検出できなかった")
            return
        }
        #expect(choice.kind == .approval)
        #expect(choice.title == "Do you want to make this edit to foo.swift?")
        #expect(choice.options.count == 3)
        #expect(choice.options[0].keystroke == "1")
        #expect(choice.options[0].isAffirmative)
        #expect(choice.options[2].isNegative)
        #expect(choice.options.allSatisfy { !$0.needsEnter })
    }

    @Test func 承認以外の問いかけは質問として分類する() {
        let screen = """
        どの方針で進めますか?
        ❯ 1. 既存の実装を拡張する
          2. 新しく書き直す
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .claude) else {
            Issue.record("選択肢を検出できなかった")
            return
        }
        #expect(choice.kind == .question)
        #expect(choice.options.count == 2)
    }

    @Test func yn形式のプロンプトを検出する() {
        let screen = """
        既存のファイルを上書きします
        Do you want to continue? (y/n)
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .codex) else {
            Issue.record("y/n形式を検出できなかった")
            return
        }
        #expect(choice.kind == .approval)
        #expect(choice.options.map(\.keystroke) == ["y", "n"])
        // y/n形式は入力確定にEnterが必要
        #expect(choice.options.allSatisfy { $0.needsEnter })
    }

    @Test func 通常の応答画面では選択肢を検出しない() {
        let screen = """
        処理が完了しました。変更点は以下です。
        - foo.swift を修正
        - bar.swift を追加
        ╭────────────╮
        │ >          │
        ╰────────────╯
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    @Test func 番号が1から始まらない列挙は選択肢とみなさない() {
        let screen = """
        参考:
        2. 二番目の項目
        3. 三番目の項目
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    /// 実際に起きた不具合の再現: 説明文中の番号付き箇条書き（項目ごとの説明行を挟まない
    /// 単純な連番）が、会話が先へ進んだ後も画面に残っていると選択待ちと誤検出されていた。
    /// (Subghost起動直後、フックがまだ繋がっていない一瞬に画面解析が走ると
    /// この文面を拾ってしまい、選んだつもりが数字だけ誤送信される不具合につながっていた)
    @Test func 説明文中の番号付き箇条書きを選択待ちと誤認しない() {
        let screen = """
        状況をまとめます.

        1. 複数選択のトグルは正しく動作しています
        2. Submit直後に確認画面が挟まることが分かりました
        3. 確認画面では改めて1を送る必要があります

        修正を実装します.
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    @Test func ヒント行だけで終わる生きたメニューは引き続き検出する() {
        // 選択肢の後に操作ヒントだけがあり、それ以降に何も続かない（＝画面の最後）なら生きている
        let screen = """
        【複数選択の検証】

        ❯ 1. [ ] 項目A
          2. [ ] 項目B
             Submit

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .claude) else {
            Issue.record("生きたメニューを検出できなかった")
            return
        }
        #expect(choice.options.count == 2)
    }

    @Test func 選択肢の直後で画面が終わっていれば生きていると判定する() {
        // ヒント行すら無く、選択肢の直後で画面がそのまま終わる（＝末尾）なら生きている
        let screen = """
        どちらにしますか?
        ❯ 1. こちら
          2. あちら
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) != nil)
    }

    // MARK: - 送信直前の再照合（フールプルーフ）

    @Test func 選択肢のラベルが画面に残っていれば送信前照合を通す() {
        let paneText = """
        ❯ 1. [ ] 項目A
          2. [✔] 項目B
             Submit
        """
        #expect(ChoicePrompt.matchesCurrentScreen(optionLabels: ["項目A", "項目B"], in: paneText))
    }

    @Test func 画面が先へ進んでいれば送信前照合を弾く() {
        // 表示から回答までの間に会話が進み、選択肢のラベルがもう画面に無い場合
        let paneText = """
        修正を実装しました. 次の作業に移ります.
        """
        #expect(!ChoicePrompt.matchesCurrentScreen(optionLabels: ["項目A", "項目B"], in: paneText))
    }

    @Test func 選択肢が空なら送信前照合を通さない() {
        #expect(!ChoicePrompt.matchesCurrentScreen(optionLabels: [], in: "何かの画面"))
    }
}

// MARK: - 起動時に既存セッションの状態を引き継ぐ

struct InitialAdoptionTests {

    @Test func 起動前から承認待ちで止まっているセッションを拾う() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        // 初回の取り込みは候補として保持するだけで、まだ確定しない
        // (フールプルーフ: 起動直後の一瞬は誤検出のリスクが最も高いため、
        // 1回見ただけでは確定させず、次のポーリングでの再確認を待つ)
        let first = detector.adoptCurrentState(rawText: screen, at: t0)
        #expect(first == .none)

        // 次のポーリングでも同じ内容が見えて初めて確定する
        let event = detector.ingest(rawText: screen, at: t0.addingTimeInterval(1))
        guard case .becameAwaitingChoice(let choice) = event else {
            Issue.record("承認待ちを拾えなかった: \(event)")
            return
        }
        #expect(detector.state == .awaitingApproval)
        #expect(choice.options.count == 2)
    }

    @Test func 起動直後の候補が次のポーリングで消えていれば確定しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        _ = detector.adoptCurrentState(rawText: screen, at: t0)

        // 次のポーリングで別の画面（選択メニューではない）に変わっていれば、
        // 一過性の誤検出だったとみなして確定しない
        _ = detector.ingest(rawText: "通常の会話が続いています", at: t0.addingTimeInterval(1))
        #expect(detector.state != .awaitingApproval)
        #expect(detector.state != .awaitingAnswer)
        #expect(detector.pendingChoice == nil)
    }

    @Test func 起動時に生成中なら生成中として引き継ぐ() {
        var detector = StateDetector(profile: .claude)
        let screen = "✻ Thinking… (esc to interrupt)"
        let event = detector.adoptCurrentState(rawText: screen, at: Date(timeIntervalSince1970: 0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func 起動前に完了していた応答で完了通知を出さない() {
        var detector = StateDetector(profile: .claude)
        let screen = """
        処理が完了しました。
        ╭────────────╮
        │ >          │
        ╰────────────╯
        """
        // 起動前に終わっていた作業を「今完了した」と誤報してはいけない
        let event = detector.adoptCurrentState(rawText: screen, at: Date(timeIntervalSince1970: 0))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }

    @Test func 引き継ぎ後は通常の差分判定に戻る() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(detector.needsInitialAdoption)

        _ = detector.adoptCurrentState(rawText: "待機中の画面", at: t0)
        #expect(!detector.needsInitialAdoption)

        // 以降は出力の伸長で生成中になる
        let event = detector.ingest(rawText: "待機中の画面\n新しい出力", at: t0.addingTimeInterval(1))
        #expect(event == .becameThinking)
    }

    @Test func 引き継ぎ直後に同じ承認画面でも二重通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        _ = detector.adoptCurrentState(rawText: screen, at: t0)
        // 次のポーリングで候補が確定する
        _ = detector.ingest(rawText: screen, at: t0.addingTimeInterval(1))
        #expect(detector.state == .awaitingApproval)

        // 確定後、同じ画面が続いても二重通知しない
        let repeated = detector.ingest(rawText: screen, at: t0.addingTimeInterval(2))
        #expect(repeated == .none)
        #expect(detector.state == .awaitingApproval)
    }
}

struct ChoiceStateTests {

    private let approvalScreen = """
    Do you want to run this command?
    ❯ 1. Yes
      2. No
    """

    @Test func 選択待ちを検出したらawaitingApprovalへ遷移する() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)

        let event = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))
        guard case .becameAwaitingChoice(let choice) = event else {
            Issue.record("承認待ちにならなかった: \(event)")
            return
        }
        #expect(detector.state == .awaitingApproval)
        #expect(choice.options.count == 2)
    }

    @Test func 同じ選択肢が出続けても再通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        let repeated = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(2))
        #expect(repeated == .none)
        #expect(detector.state == .awaitingApproval)
    }

    @Test func 選択待ちの間はcompletedと判定しない() {
        var detector = StateDetector(profile: .claude)
        detector.stableInterval = 1.5
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        // 静止時間が十分経過してもcompletedにはしない
        let later = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(30))
        #expect(later == .none)
        #expect(detector.state == .awaitingApproval)
    }

    @Test func ターミナル側で回答されたら選択待ちが解消する() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        let resolved = detector.ingest(rawText: "コマンドを実行しています…", at: t0.addingTimeInterval(2))
        #expect(resolved == .choiceResolved)
        #expect(detector.state == .thinking)
        #expect(detector.pendingChoice == nil)
    }

    @Test func ノッチから回答した直後は同じ選択肢を再通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        // 回答を送信（画面はまだ更新されていない）
        _ = detector.noteUserAnsweredChoice(at: t0.addingTimeInterval(2))
        let afterAnswer = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(2.5))
        #expect(afterAnswer == .none)
        #expect(detector.state == .thinking)

        // 抑制時間を過ぎてもまだ同じ画面なら、答えが届いていないので再通知する
        let renotified = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(10))
        guard case .becameAwaitingChoice = renotified else {
            Issue.record("抑制時間経過後に再通知されなかった: \(renotified)")
            return
        }
    }
}
