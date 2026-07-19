//
//  AgentDiscovery.swift
//  Subghost
//
//  設計書 追補: ゼロコンフィグ検出
//
//  従来は「ai-* という名前のtmuxセッション」だけを監視対象としていたため、
//  ユーザーにシェルエイリアスの登録を強いていた。
//  本モジュールは実行中プロセスからAI CLIを直接見つけるため、
//  エイリアスもセッション命名規則も不要になる。
//
//  検出の要点:
//  - `ps -o comm=` はカーネルが持つ実行ファイル名を返すため、
//    CLIが自身のプロセス名を書き換えていても正しく判定できる
//    （Claude Codeは pane_current_command にバージョン文字列を出すため当てにできない）
//  - 制御端末を持たないプロセス（tty が "??"）はGUIアプリの同梱バイナリなので除外する
//    （例: ChatGPT.appが同梱する codex）
//

import Foundation

// MARK: - 検出結果

/// psで見つかったAI CLIのプロセス1つ分
nonisolated struct DiscoveredAgent: Sendable, Equatable, Hashable {
    let pid: Int32
    /// 制御端末（"/dev/ttys004"）。tmux内で動く場合はペインのptyを指す。
    let tty: String
    let profile: CLIProfile
    /// tmuxのペイン宛先（"session:0.1"）。tmux外で動いている場合は nil。
    let tmuxTarget: String?
    /// 所属するtmuxセッション名。tmux外なら nil。
    let tmuxSession: String?
}

// MARK: - 検出

nonisolated enum AgentDiscovery {

    /// 実行中のAI CLIを列挙し、tmuxのペインと突き合わせる
    static func discover(profiles: [CLIProfile] = CLIProfile.builtins) async -> [DiscoveredAgent] {
        let processes = agentProcesses(profiles: profiles)
        guard !processes.isEmpty else { return [] }

        // tmux未導入・未起動でも検出自体は成立させる（監視だけができない状態になる）
        let panes = await TmuxClient.paneTargetsByTTY()

        return processes.map { process in
            let target = panes[process.tty]
            return DiscoveredAgent(
                pid: process.pid,
                tty: process.tty,
                profile: process.profile,
                tmuxTarget: target,
                tmuxSession: target.map { String($0.prefix(while: { $0 != ":" })) }
            )
        }
        .sorted { ($0.profile.id, $0.tty) < ($1.profile.id, $1.tty) }
    }

    // MARK: - プロセス列挙

    nonisolated struct AgentProcess: Sendable, Equatable {
        let pid: Int32
        let tty: String
        let profile: CLIProfile
    }

    /// `ps` の出力からAI CLIのプロセスを抜き出す
    static func agentProcesses(profiles: [CLIProfile]) -> [AgentProcess] {
        guard let output = runPS(["-A", "-o", "pid=,tty=,comm="]) else { return [] }
        return parseAgentProcesses(output, profiles: profiles)
    }

    /// psの出力行を解析する（テスト対象の純粋ロジック）
    ///
    /// 行の形式: `<pid> <tty> <実行ファイルパス>`
    /// commにはスペースを含むパスが来ることがあるため、3列目以降はすべてパスとして扱う。
    static func parseAgentProcesses(_ output: String, profiles: [CLIProfile]) -> [AgentProcess] {
        var results: [AgentProcess] = []

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }

            let tty = String(fields[1])
            // 制御端末を持たないプロセス（GUIアプリの同梱バイナリなど）は対象外
            guard tty != "??", tty != "?" else { continue }

            let commandPath = fields[2...].joined(separator: " ")
            guard let profile = matchProfile(commandPath: commandPath, profiles: profiles) else { continue }

            results.append(AgentProcess(pid: pid, tty: "/dev/" + tty, profile: profile))
        }
        return results
    }

    /// 実行ファイルパスの末尾要素からCLIプロファイルを判定する
    static func matchProfile(commandPath: String, profiles: [CLIProfile]) -> CLIProfile? {
        let name = (commandPath as NSString).lastPathComponent.lowercased()
        // 完全一致のみ。"claude-something" のような別物を拾わないようにする。
        return profiles.first { $0.executableNames.contains(name) }
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
