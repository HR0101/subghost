//
//  HookInstaller.swift
//  Subghost
//
//  設計書 追補: フック方式
//
//  ブリッジスクリプトの設置と ~/.claude/settings.json へのフック登録。
//
//  安全設計:
//  - settings.json はユーザーの資産なので、書き換え前に必ずバックアップを取る
//  - Subghostが追加した項目だけを識別できるよう、コマンド文字列に目印を含める
//  - フックは「スクリプトが無ければ何もせず正常終了」する形にする。
//    Subghostを削除・移動してもCLI側が壊れない（これは重要な要件）
//

import Foundation

// MARK: - 対応CLI

/// フックを登録できるCLIと、その差異。
/// JSONの構造（hooks配下にイベント名→matcher配列）は共通だが、
/// 置き場所・イベント集合・信頼の要否が異なる。
nonisolated enum HookTarget: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    /// フック定義を書き込むファイル
    var settingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// そのCLIが実際に発火するイベント
    var events: [String] {
        switch self {
        case .claude:
            return ["SessionStart", "SessionEnd", "UserPromptSubmit",
                    "PreToolUse", "PostToolUse",
                    "Notification", "PermissionRequest", "Stop", "StopFailure"]
        case .codex:
            // Codexが対応するのはこの6種のみ（Notification / PreToolUse は無い）
            return ["SessionStart", "UserPromptSubmit", "PostToolUse",
                    "PermissionRequest", "Stop", "SubagentStop"]
        }
    }

    /// matcherを取るイベント（取らないイベントに付けると弾かれることがある）
    var matcherEvents: Set<String> {
        switch self {
        case .claude: return ["PreToolUse", "PostToolUse", "PermissionRequest", "Notification"]
        case .codex: return ["PostToolUse"]
        }
    }

    /// 設定ファイルがそのCLI専用か（専用なら解除時に空ファイルを残さない）
    var isDedicatedFile: Bool { self == .codex }

    /// 登録後、CLI側でユーザーによる信頼の承認が要るか
    var requiresTrustApproval: Bool { self == .codex }

    /// そのCLIが導入されていそうか（設定ディレクトリの有無で判断）
    var isLikelyInstalled: Bool {
        let directory = settingsURL.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: directory.path)
    }
}

nonisolated enum HookInstaller {

    /// Subghostが追加したフックを見分けるための目印
    static let marker = "subghost-bridge"

    /// 承認待ちでCLIを待たせる上限（秒）。これを超えるとCLI本来の確認画面に戻る。
    static let permissionTimeoutSeconds = 1800

    /// 承認以外のイベントは即座に返るため、短い上限で十分
    static let normalTimeoutSeconds = 5

    // MARK: - パス

    /// 実行時ディレクトリ。
    /// Unixドメインソケットのパスは sockaddr_un.sun_path（macOSでは104バイト）に収める必要があるため、
    /// "Application Support" のような長いパスは使わずホーム直下の短い名前にする。
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".subghost", isDirectory: true)
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent("run/subghost.sock").path
    }

    static var bridgeScriptPath: String {
        supportDirectory.appendingPathComponent("bin/subghost-bridge").path
    }


    // MARK: - ブリッジスクリプト

    /// フックから呼ばれるシェルスクリプトの中身を作る
    static func bridgeScript(socketPath: String) -> String {
        """
        #!/bin/sh
        # Subghost bridge (\(marker))
        # Claude Codeのフックから呼ばれ、イベントをSubghostへ中継する。
        # Subghostが動いていなければ即座に正常終了し、CLI側の動作を妨げない。
        SOCK="\(socketPath)"
        [ -S "$SOCK" ] || exit 0

        # どのセッションのイベントかを特定するため、CLI本体のpidとttyを探す。
        #
        # フックはCLIから "/bin/sh -c ..." 経由で起動され、この中間シェルは
        # 制御端末を持たない（tty が "??" になる）。そのため親を1段見るだけでは
        # 特定できず、祖先をたどって最初に制御端末を持つプロセス＝CLI本体を探す。
        AGENT_TTY=""
        AGENT_PID=""
        cur=$PPID
        depth=0
        while [ "$cur" -gt 1 ] && [ "$depth" -lt 10 ]; do
            line=$(ps -o ppid=,tty= -p "$cur" 2>/dev/null) || break
            [ -z "$line" ] && break
            parent=$(echo $line | awk '{print $1}')
            term=$(echo $line | awk '{print $2}')
            if [ -n "$term" ] && [ "$term" != "??" ]; then
                AGENT_TTY="/dev/$term"
                AGENT_PID="$cur"
                break
            fi
            cur=$parent
            depth=$((depth + 1))
        done

        curl -s -m \(permissionTimeoutSeconds) --unix-socket "$SOCK" \\
             -H 'Content-Type: application/json' \\
             -H "X-Subghost-Tty: ${AGENT_TTY:-unknown}" \\
             -H "X-Subghost-Pid: ${AGENT_PID:-0}" \\
             --data-binary @- \\
             "http://localhost/hook?source=$1" 2>/dev/null || exit 0
        exit 0
        """
    }

    /// スクリプトを設置し、実行権限を与える
    static func installBridgeScript() throws {
        let binDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let script = bridgeScript(socketPath: socketPath)
        try script.write(toFile: bridgeScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: bridgeScriptPath)
    }

    // MARK: - settings.json への登録

    /// フックのコマンド文字列。スクリプトが無い場合は何もせず成功で抜ける。
    ///
    /// 末尾のシェルコメントは、設置先のパスに関わらずSubghostの項目を identify するための目印。
    /// パス文字列に目印が含まれることに依存すると、設置先を変えた際に解除できなくなる。
    static func hookCommand(scriptPath: String, source: String = "claude") -> String {
        "/bin/sh -c '[ -x \"\(scriptPath)\" ] && \"\(scriptPath)\" \(source); exit 0' # \(marker)"
    }

    /// 現在フックが登録されているか
    static func isInstalled(_ target: HookTarget) -> Bool {
        guard let data = try? Data(contentsOf: target.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return containsMarker(in: root)
    }

    static func containsMarker(in root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        let text = String(describing: hooks)
        return text.contains(marker)
    }

    /// フックを登録する。既存の設定は保持し、Subghostの項目だけを足す。
    static func install(_ target: HookTarget) throws {
        try installBridgeScript()

        var root = try loadSettings(target)
        try backupSettings(target)
        root = addHooks(to: root, scriptPath: bridgeScriptPath, target: target)
        try writeSettings(root, target: target)
    }

    /// Subghostが追加したフックだけを取り除く
    static func uninstall(_ target: HookTarget) throws {
        var root = try loadSettings(target)
        guard containsMarker(in: root) else { return }
        try backupSettings(target)
        root = removeHooks(from: root)
        try writeSettings(root, target: target)

        // ブリッジは全CLIで共有しているため、どれか残っていれば消さない
        if !HookTarget.allCases.contains(where: { isInstalled($0) }) {
            try? FileManager.default.removeItem(atPath: bridgeScriptPath)
        }
    }

    // MARK: - JSON操作（テスト対象の純粋ロジック）

    /// hooks配下にSubghostのエントリを追加した設定を返す
    static func addHooks(
        to root: [String: Any],
        scriptPath: String,
        target: HookTarget = .claude
    ) -> [String: Any] {
        var result = root
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for event in target.events {
            var matchers = (hooks[event] as? [[String: Any]]) ?? []
            // 同じ目印を持つ既存エントリは入れ替える（重複登録の防止）
            matchers.removeAll { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }

            let isPermission = event == "PermissionRequest"
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": hookCommand(scriptPath: scriptPath, source: target.rawValue),
                // 承認待ちは応答があるまで接続を保持するため、長めの上限を指定する
                "timeout": isPermission ? permissionTimeoutSeconds : normalTimeoutSeconds,
            ]

            var matcherEntry: [String: Any] = ["hooks": [hookEntry]]
            if target.matcherEvents.contains(event) {
                // Codexは空文字を全一致として扱う
                matcherEntry["matcher"] = target == .codex ? "" : "*"
            }

            matchers.append(matcherEntry)
            hooks[event] = matchers
        }

        result["hooks"] = hooks
        return result
    }

    /// 目印を持つエントリだけを取り除いた設定を返す
    static func removeHooks(from root: [String: Any]) -> [String: Any] {
        var result = root
        guard var hooks = root["hooks"] as? [String: Any] else { return result }

        for (event, value) in hooks {
            guard var matchers = value as? [[String: Any]] else { continue }
            matchers.removeAll { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            // 空になったイベントはキーごと消す（元が無かった状態に戻す）
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    // MARK: - ファイル入出力

    private static func loadSettings(_ target: HookTarget) throws -> [String: Any] {
        let url = target.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.settingsNotAnObject(url.lastPathComponent)
        }
        return root
    }

    /// 書き換え前に日時付きのバックアップを残す
    private static func backupSettings(_ target: HookTarget) throws {
        let url = target.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).subghost-backup-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private static func writeSettings(_ root: [String: Any], target: HookTarget) throws {
        let url = target.settingsURL
        // 専用ファイルで中身が空になったらファイルごと消す（元が無かった状態に戻す）
        if target.isDedicatedFile, root.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum HookInstallError: Error, LocalizedError {
    case settingsNotAnObject(String)

    var errorDescription: String? {
        switch self {
        case .settingsNotAnObject(let fileName):
            return "\(fileName) の形式を認識できませんでした。手動で確認してください。"
        }
    }
}
