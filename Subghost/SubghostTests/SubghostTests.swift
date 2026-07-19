//
//  SubghostTests.swift
//  SubghostTests
//
//  状態判定ロジック（設計書 5）のユニットテスト
//

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
