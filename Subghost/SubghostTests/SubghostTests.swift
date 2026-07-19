//
//  SubghostTests.swift
//  SubghostTests
//
//  状態判定ロジック（設計書 5）のユニットテスト
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Subghost

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

    @Test func 実行ファイル名は完全一致で判定する() {
        // "claude-helper" のような別物を拾わない
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude", profiles: profiles)?.id == "claude")
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude-helper", profiles: profiles) == nil)
        #expect(AgentDiscovery.matchProfile(commandPath: "/bin/zsh", profiles: profiles) == nil)
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
        #expect(inTmux.displayName == "work (ttys006)")
        #expect(outside.displayName == "ttys003")
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
        id: "uuid-builtin", name: "内蔵ディスプレイ", hasNotch: true, isMain: false)
    private let external = ScreenDescriptor(
        id: "uuid-studio", name: "Studio Display", hasNotch: false, isMain: true)
    private let third = ScreenDescriptor(
        id: "uuid-third", name: "サブモニタ", hasNotch: false, isMain: false)

    private var all: [ScreenDescriptor] { [builtin, external, third] }

    @Test func 自動ではノッチ搭載画面を優先する() {
        #expect(DisplaySelector.select(from: all, preference: .automatic) == builtin)
    }

    @Test func 自動でノッチ搭載画面が無ければメインを使う() {
        let noNotch = [external, third]
        #expect(DisplaySelector.select(from: noNotch, preference: .automatic) == external)
    }

    @Test func メイン指定はノッチ搭載画面より優先される() {
        #expect(DisplaySelector.select(from: all, preference: .main) == external)
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
        #expect(DisplaySelector.select(from: [], preference: .main) == nil)
    }

    @Test func 設定値の保存と復元が往復する() {
        #expect(DisplayPreference(storedValue: "") == .automatic)
        #expect(DisplayPreference(storedValue: "main") == .main)
        #expect(DisplayPreference(storedValue: "uuid-x") == .specific(id: "uuid-x"))

        #expect(DisplayPreference.automatic.storedValue == "")
        #expect(DisplayPreference.main.storedValue == "main")
        #expect(DisplayPreference.specific(id: "uuid-x").storedValue == "uuid-x")
    }

    @Test func メイン指定でメインが見つからなければ自動に倒す() {
        // 異常系: どの画面もメインでない
        let none = [builtin, third]
        #expect(DisplaySelector.select(from: none, preference: .main) == builtin)
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
}

// MARK: - 起動時に既存セッションの状態を引き継ぐ

struct InitialAdoptionTests {

    @Test func 起動前から承認待ちで止まっているセッションを拾う() {
        var detector = StateDetector(profile: .claude)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        // 初回の取り込みでいきなり承認待ちを検出できること
        let event = detector.adoptCurrentState(rawText: screen, at: Date(timeIntervalSince1970: 0))
        guard case .becameAwaitingChoice(let choice) = event else {
            Issue.record("承認待ちを拾えなかった: \(event)")
            return
        }
        #expect(detector.state == .awaitingApproval)
        #expect(choice.options.count == 2)
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
        let repeated = detector.ingest(rawText: screen, at: t0.addingTimeInterval(1))
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
