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
                    "Notification", "PermissionRequest", "Stop", "StopFailure", "PreCompact"]
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

        # 待ち時間の上限はフック側から渡される（承認だけ長い）。
        # ここで必ず上限を設けることで、Subghostが応答不能でもCLIを止め続けない。
        TIMEOUT="${2:-\(normalTimeoutSeconds)}"
        case "$TIMEOUT" in *[!0-9]* | "") TIMEOUT=\(normalTimeoutSeconds) ;; esac

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

        curl -s -m "$TIMEOUT" --unix-socket "$SOCK" \\
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

    // MARK: - statusline の連鎖（使用量の取得）

    static var statuslineScriptPath: String {
        supportDirectory.appendingPathComponent("bin/subghost-statusline").path
    }

    /// 元々設定されていたstatuslineコマンドの保存先
    static var previousStatuslinePath: URL {
        supportDirectory.appendingPathComponent("previous-statusline")
    }

    /// 使用量（5時間枠・7日枠）はstatuslineへ渡されるJSONにしか含まれないため、
    /// 既存のstatuslineコマンドを包んで内容を横取りする。
    ///
    /// 安全設計:
    /// - 元のコマンドは保存し、解除時に必ず戻す
    /// - 標準入力は読み切ってから元のコマンドへ渡し直す（出力はそのまま通す）
    /// - Subghostが動いていなくても、元のstatuslineは変わらず動作する
    static func statuslineScript(socketPath: String, next: String?) -> String {
        let forward = next.map {
            """
            NEXT='\($0.replacingOccurrences(of: "'", with: "'\\''"))'
            printf '%s' "$PAY" | /bin/sh -c "$NEXT"
            """
        } ?? ""

        return """
        #!/bin/sh
        # Subghost statusline chain (\(marker))
        # statuslineのJSONを横取りしつつ、元のコマンドへそのまま渡す。
        PAY=$(cat)

        SOCK="\(socketPath)"
        if [ -S "$SOCK" ]; then
            printf '%s' "$PAY" | curl -s -m 2 --unix-socket "$SOCK" \\
                -H 'Content-Type: application/json' \\
                --data-binary @- "http://localhost/usage" >/dev/null 2>&1
        fi

        \(forward)
        exit 0
        """
    }

    /// settings.json に書き込む statusLine コマンド。
    ///
    /// スクリプトのパスをそのまま書くと、`~/.subghost` を手で消したときに
    /// 存在しないコマンドが残り、ユーザーのstatuslineが戻らなくなる。
    /// 元のコマンドをここへ持たせておくことで、Subghost側の資産が全て消えても
    /// 自動的に元のstatuslineへ戻る。
    static func statuslineCommand(scriptPath: String, previous: String?) -> String {
        let body = """
            [ -x "$1" ] && exec "$1"; [ -n "$2" ] && exec /bin/sh -c "$2"; exit 0
            """
        let args = [scriptPath, previous ?? ""].map(shellQuoted).joined(separator: " ")
        return "/bin/sh -c \(shellQuoted(body)) subghost \(args) # \(marker)"
    }

    /// 自分が書いたコマンド文字列から、包む前の元コマンドを読み戻す。
    /// 保存ファイル（previousStatuslinePath）が失われていても解除できるようにするための経路。
    static func embeddedPreviousStatusline(in command: String) -> String? {
        guard command.contains(marker) else { return nil }
        // [本文, スクリプトのパス, 元コマンド] の順に並んでいる
        let arguments = singleQuotedArguments(in: command)
        guard arguments.count >= 3, !arguments[2].isEmpty else { return nil }
        return arguments[2]
    }

    /// シェルの単一引用符で包まれた引数を取り出す。
    /// 自分で組み立てた文字列を読み戻すためのもので、一般のシェル構文の解釈ではない。
    static func singleQuotedArguments(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "'" else { index += 1; continue }
            index += 1
            var current = ""
            while index < characters.count {
                if characters[index] == "'" {
                    // shellQuoted が引用符そのものを表すために使う '\'' の並び
                    let isEscapedQuote = index + 3 < characters.count
                        && characters[index + 1] == "\\"
                        && characters[index + 2] == "'"
                        && characters[index + 3] == "'"
                    guard isEscapedQuote else { break }
                    current.append("'")
                    index += 4
                    continue
                }
                current.append(characters[index])
                index += 1
            }
            index += 1
            result.append(current)
        }
        return result
    }

    static func isStatuslineInstalled() -> Bool {
        guard let root = try? loadSettings(.claude),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return false }
        return command.contains(marker)
    }

    /// statuslineの横取りを開始する
    static func installStatusline() throws {
        var root = try loadSettings(.claude)
        let statusLine = root["statusLine"] as? [String: Any]
        let current = statusLine?["command"] as? String

        // 既に自分が入っている場合は元コマンドを上書きしない。
        // 保存ファイルが消えていても、コマンド文字列の中から読み戻せる。
        let previous: String?
        if let current, current.contains(marker) {
            previous = embeddedPreviousStatusline(in: current)
                ?? (try? String(contentsOf: previousStatuslinePath, encoding: .utf8))
                    .flatMap { $0.isEmpty ? nil : $0 }
        } else {
            previous = current
            if let current {
                try FileManager.default.createDirectory(
                    at: supportDirectory, withIntermediateDirectories: true)
                try current.write(to: previousStatuslinePath, atomically: true, encoding: .utf8)
            }
        }

        let binDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try statuslineScript(socketPath: socketPath, next: previous)
            .write(toFile: statuslineScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: statuslineScriptPath)

        try backupSettings(.claude)
        var updated = statusLine ?? ["type": "command"]
        updated["command"] = statuslineCommand(
            scriptPath: statuslineScriptPath, previous: previous)
        if updated["type"] == nil { updated["type"] = "command" }
        root["statusLine"] = updated
        try writeSettings(root, target: .claude)
    }

    /// 元のstatuslineコマンドへ戻す
    static func uninstallStatusline() throws {
        var root = try loadSettings(.claude)
        guard var statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              command.contains(marker)
        else { return }

        try backupSettings(.claude)
        // コマンド文字列に埋め込んだ元コマンドを優先し、保存ファイルは予備に使う。
        // どちらも失われていれば、元は無かったものとして設定ごと取り除く。
        let saved = (try? String(contentsOf: previousStatuslinePath, encoding: .utf8))
            .flatMap { $0.isEmpty ? nil : $0 }
        if let previous = embeddedPreviousStatusline(in: command) ?? saved {
            statusLine["command"] = previous
            root["statusLine"] = statusLine
        } else {
            // 元が無かった場合は設定ごと取り除く
            root.removeValue(forKey: "statusLine")
        }
        try writeSettings(root, target: .claude)
        try? FileManager.default.removeItem(atPath: statuslineScriptPath)
        try? FileManager.default.removeItem(at: previousStatuslinePath)
    }

    // MARK: - settings.json への登録

    /// 文字列をシェルの単一引用符で安全に包む。
    /// ホームディレクトリ名に ' や " や空白が含まれていても、
    /// 生成したコマンドがシェル構文エラーにならないようにする。
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// フックのコマンド文字列。スクリプトが無い場合は何もせず成功で抜ける。
    ///
    /// パスは本文へ埋め込まず `sh -c` の引数として渡す。埋め込むと、パスに含まれる
    /// 引用符・空白・`$` が本文の構文を壊し、CLIが毎イベントでエラーを出すことになる。
    ///
    /// 末尾のシェルコメントは、設置先のパスに関わらずSubghostの項目を identify するための目印。
    /// パス文字列に目印が含まれることに依存すると、設置先を変えた際に解除できなくなる。
    static func hookCommand(
        scriptPath: String,
        source: String = "claude",
        timeout: Int = normalTimeoutSeconds
    ) -> String {
        let body = "[ -x \"$1\" ] && \"$1\" \"$2\" \"$3\"; exit 0"
        let args = [scriptPath, source, String(timeout)].map(shellQuoted).joined(separator: " ")
        return "/bin/sh -c \(shellQuoted(body)) subghost \(args) # \(marker)"
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
            // 既存の値が想定した形でなければ、そのイベントには一切触れない。
            // 空配列で置き換えるとユーザーが自分で書いたフックを消してしまう。
            let existing = hooks[event]
            guard var matchers = existing as? [[String: Any]] ?? (existing == nil ? [] : nil)
            else { continue }

            // 同じ目印を持つ既存エントリは入れ替える（重複登録の防止）
            matchers.removeAll { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }

            // 承認待ちは応答があるまで接続を保持するため、長めの上限を指定する
            let isPermission = event == "PermissionRequest"
            let timeout = isPermission ? permissionTimeoutSeconds : normalTimeoutSeconds
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": hookCommand(
                    scriptPath: scriptPath, source: target.rawValue, timeout: timeout),
                "timeout": timeout,
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

    static func loadSettings(_ target: HookTarget) throws -> [String: Any] {
        let url = target.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.settingsNotAnObject(url.lastPathComponent)
        }
        return root
    }

    /// 残しておくバックアップの数。導入・解除のたびに増え続けると
    /// 設定ディレクトリが実体の分からないファイルで埋まる。
    static let backupsToKeep = 3

    static func backupFileName(for url: URL) -> String {
        "\(url.lastPathComponent).subghost-backup-"
    }

    /// 書き換え前に日時付きのバックアップを残し、古いものは間引く
    static func backupSettings(_ target: HookTarget) throws {
        let url = target.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = url.deletingLastPathComponent()
        let prefix = backupFileName(for: url)
        let backup = directory.appendingPathComponent("\(prefix)\(formatter.string(from: Date()))")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: url, to: backup)

        // 名前に日時が入っているので、名前順に並べれば新しいものが後ろに来る
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ours = existing.filter { $0.hasPrefix(prefix) }.sorted()
        for stale in ours.dropLast(backupsToKeep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
    }

    /// 実際に書き込む先。
    /// 設定ファイルをdotfilesリポジトリへのシンボリックリンクにしている人がいるため、
    /// 原子的書き込みでリンクを実ファイルに置き換えてしまわないよう実体を解決する。
    static func writeURL(for target: HookTarget) -> URL {
        let url = target.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        return url.resolvingSymlinksInPath()
    }

    /// 設定をファイルへ書ける形にして返す。
    /// 書いてから壊れていたと気づいてはCLIの起動を妨げてしまうため、
    /// ここで必ず「読み返せること」まで確かめてから返す。
    static func encodedSettings(_ root: [String: Any], fileName: String) throws -> Data {
        // JSONにできない値が混じっていると JSONSerialization.data は Swift の error ではなく
        // NSException を投げる。do/catch では捕まえられずアプリが落ちるため、
        // 必ずこの判定を先に通す。
        guard JSONSerialization.isValidJSONObject(root) else {
            throw HookInstallError.wouldWriteInvalidSettings(fileName)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
            throw HookInstallError.wouldWriteInvalidSettings(fileName)
        }
        return data
    }

    static func writeSettings(_ root: [String: Any], target: HookTarget) throws {
        let url = writeURL(for: target)
        // 専用ファイルで中身が空になったらファイルごと消す（元が無かった状態に戻す）
        if target.isDedicatedFile, root.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encodedSettings(root, fileName: url.lastPathComponent)
        let previousContents = try? Data(contentsOf: url)
        try data.write(to: url, options: .atomic)

        // 書き込み後も読み返して確認し、駄目なら直前の内容へ戻す。
        // ここで戻せなければユーザーはCLIを起動できなくなる。
        if (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) })
            == nil {
            if let previousContents {
                try? previousContents.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            throw HookInstallError.wouldWriteInvalidSettings(url.lastPathComponent)
        }
    }
}

nonisolated enum HookInstallError: Error, LocalizedError {
    case settingsNotAnObject(String)
    case wouldWriteInvalidSettings(String)

    var errorDescription: String? {
        switch self {
        case .settingsNotAnObject(let fileName):
            return "\(fileName) の形式を認識できませんでした。手動で確認してください。"
        case .wouldWriteInvalidSettings(let fileName):
            return "\(fileName) を安全に書き換えられなかったため、変更を取り消しました。"
        }
    }
}
