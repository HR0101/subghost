//
//  TerminalActivator.swift
//  Subghost
//
//  設計書 4.2: クリックでターミナルを最前面化
//  設計書 追補: Jump（AI CLIが動いている「タブ」まで正確に移動する）
//
//  tmuxのクライアントttyを手がかりに、どのターミナルのどのタブかを特定する。
//  ターミナル.appはAppleScriptでタブを直接選択できる。
//  GhosttyはAppleScript非対応のため、アプリの前面化までを行う。
//

import AppKit

// MARK: - 対応ターミナル

nonisolated enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case ghostty
    case terminal

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .terminal: return "com.apple.Terminal"
        }
    }

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .terminal: return "ターミナル.app"
        }
    }

    /// タブ単位の正確な移動ができるか（AppleScript対応の有無）
    var supportsTabJump: Bool {
        self == .terminal
    }

    /// 起動中のインスタンスがあるか
    @MainActor
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

// MARK: - アクティベータ

@MainActor
enum TerminalActivator {

    /// 設定で指定された優先ターミナル。未設定なら自動判定。
    static var preferred: TerminalApp? {
        guard let raw = UserDefaults.standard.string(forKey: "preferredTerminal") else { return nil }
        return TerminalApp(rawValue: raw)
    }

    // MARK: - Jump

    /// 指定セッションが動いているターミナルのタブへ移動する。
    /// タブを特定できない場合はアプリの前面化にとどめる。
    static func jump(to session: SessionInfo) async {
        // tmux内のCLIのttyはtmuxが作ったptyであり、ターミナルのタブとは対応しない。
        // その場合はアタッチ中クライアントのttyを使う。
        let terminalTTY: String?
        if let tmuxSession = session.tmuxSession {
            terminalTTY = await TmuxClient.clientTTY(session: tmuxSession)
        } else {
            terminalTTY = session.tty
        }

        guard let tty = terminalTTY, isValidTTY(tty) else {
            // tmuxセッションがデタッチ中などで、対応するタブが存在しない場合
            activate()
            return
        }

        let app = hostingTerminal(tty: tty) ?? preferred ?? firstRunning() ?? .ghostty

        // タブの選択とアクティベートはAppleScript側で完了する
        if app.supportsTabJump, selectTerminalTab(tty: tty) { return }
        activate(app)
    }

    /// セッションを問わずターミナルを前面化する
    static func activate() {
        guard let app = preferred ?? firstRunning() else {
            // どれも起動していなければ優先ターミナル（既定はGhostty）を起動する
            launch(preferred ?? .ghostty)
            return
        }
        activate(app)
    }

    static func activate(_ app: TerminalApp) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            running.activate()
            return
        }
        launch(app)
    }

    private static func launch(_ app: TerminalApp) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            NSLog("Subghost: \(app.displayName) が見つかりません")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                NSLog("Subghost: \(app.displayName) の起動に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private static func firstRunning() -> TerminalApp? {
        TerminalApp.allCases.first { $0.isRunning }
    }

    // MARK: - tty からホストのターミナルを特定する

    /// ttyを使っているプロセスの祖先をたどり、どのターミナルの配下かを判定する
    static func hostingTerminal(tty: String) -> TerminalApp? {
        // 起動中ターミナルの pid → 種別 の対応表を作る
        var terminalsByPID: [Int32: TerminalApp] = [:]
        for app in TerminalApp.allCases {
            for instance in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                terminalsByPID[instance.processIdentifier] = app
            }
        }
        guard !terminalsByPID.isEmpty else { return nil }

        let parents = ProcessTree.parentMap()
        for pid in ProcessTree.pids(onTTY: tty) {
            if let app = ProcessTree.findAncestor(of: pid, in: terminalsByPID, parents: parents) {
                return app
            }
        }
        return nil
    }

    // MARK: - ターミナル.app のタブ選択 (AppleScript)

    /// ttyの一致するタブを選択して前面化する。成功したら true。
    static func selectTerminalTab(tty: String) -> Bool {
        guard isValidTTY(tty), TerminalApp.terminal.isRunning else { return false }

        let source = """
        tell application "Terminal"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    try
                        if tty of theTab is "\(tty)" then
                            set selected of theTab to true
                            set index of theWindow to 1
                            activate
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return "notfound"
        """

        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // 「システム設定 > プライバシーとセキュリティ > 自動化」が未許可の場合もここに来る
            NSLog("Subghost: ターミナルのタブ選択に失敗しました: \(errorInfo)")
            return false
        }
        return result.stringValue == "ok"
    }

    // MARK: - 入力先の検証

    /// 現在前面にあるタブのtty。特定できない場合は nil。
    ///
    /// キー入力を合成する前に「本当に狙ったタブが前面か」を確かめるために使う。
    /// Ghosttyはタブを問い合わせる手段が無いため必ず nil を返す。
    static func frontmostTTY() -> String? {
        guard TerminalApp.terminal.isRunning else { return nil }

        let source = """
        tell application "Terminal"
            if (count of windows) is 0 then return ""
            return tty of selected tab of window 1
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }

        guard let tty = result.stringValue, isValidTTY(tty) else { return nil }
        return tty
    }

    /// 指定セッションのタブが前面にあると確認できたか。
    /// 確認できない場合（Ghostty等）は nil を返し、呼び出し側で送信を中止させる。
    static func isFrontmostTab(session: SessionInfo) -> Bool? {
        // tmux配下なら送信はtmux経由で行うため、この検証は不要
        guard session.tmuxTarget == nil else { return true }

        guard let focused = frontmostTTY() else { return nil }
        return focused == session.tty
    }

    /// AppleScriptへ埋め込む前にttyの形式を検証する（スクリプト注入の防止）
    nonisolated static func isValidTTY(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/"), tty.count <= 32 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/"))
        return tty.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - プロセスツリーの照会

/// `ps` の出力からプロセスの親子関係を読む小さなヘルパー
nonisolated enum ProcessTree {

    /// 祖先をたどる最大段数（循環や異常系での暴走を防ぐ）
    private static let maxHops = 40

    /// pid → 親pid の対応表を作る
    static func parentMap() -> [Int32: Int32] {
        guard let output = runPS(["-A", "-o", "pid=,ppid="]) else { return [:] }
        return parseParentMap(output)
    }

    /// 指定ttyを使っているプロセスのpidを列挙する
    static func pids(onTTY tty: String) -> [Int32] {
        // psの -t にはデバイス名だけを渡す（"/dev/ttys004" → "ttys004"）
        let device = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard !device.isEmpty, let output = runPS(["-t", device, "-o", "pid="]) else { return [] }
        return parsePIDs(output)
    }

    /// pidの祖先をたどり、対応表に載っているプロセスを探す
    static func findAncestor<T>(
        of pid: Int32,
        in table: [Int32: T],
        parents: [Int32: Int32]
    ) -> T? {
        var current = pid
        var hops = 0
        while current > 1, hops < maxHops {
            if let found = table[current] { return found }
            guard let parent = parents[current] else { return nil }
            current = parent
            hops += 1
        }
        return nil
    }

    // MARK: - 出力の解析（テスト対象の純粋ロジック）

    static func parseParentMap(_ output: String) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            map[pid] = ppid
        }
        return map
    }

    static func parsePIDs(_ output: String) -> [Int32] {
        output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `/bin/ps` を引数配列で実行する（シェルを介さない: 設計書 9）
    private static func runPS(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            NSLog("Subghost: psの実行に失敗しました: \(error.localizedDescription)")
            return nil
        }
    }
}
