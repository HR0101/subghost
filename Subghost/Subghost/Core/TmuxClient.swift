//
//  TmuxClient.swift
//  Subghost
//
//  設計書 3.2 橋渡し方式：tmux
//  設計書 9. セキュリティ：Processで引数配列を使い、シェル文字列連結をしない
//

import Foundation

nonisolated struct TmuxResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

nonisolated enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux が見つかりません。Homebrew等でインストールしてください。"
        case .launchFailed(let message):
            return "tmux の実行に失敗しました: \(message)"
        }
    }
}

/// tmux CLIの薄いラッパー。すべて引数配列で実行する。
nonisolated enum TmuxClient {

    /// GUIアプリはPATHが最小構成のため、tmuxの実体パスを候補から解決する。
    static func resolveTmuxPath() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "tmuxPath"),
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// tmuxを引数配列で実行し、終了を待って結果を返す（メインスレッドはブロックしない）。
    static func run(_ arguments: [String]) async throws -> TmuxResult {
        guard let tmuxPath = resolveTmuxPath() else { throw TmuxError.tmuxNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: TmuxResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: TmuxError.launchFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - 高レベルAPI

    /// 全ペインを列挙し、pty → ペイン宛先（"session:0.1"）の対応表を返す。
    /// これによりセッション名の命名規則に依存せずtmux内のプロセスを紐づけられる。
    static func paneTargetsByTTY() async -> [String: String] {
        guard let result = try? await run([
            "list-panes", "-a", "-F", "#{pane_tty}|#{session_name}:#{window_index}.#{pane_index}",
        ]), result.succeeded else { return [:] }
        return parsePaneTargets(result.stdout)
    }

    /// list-panesの出力を解析する（テスト対象の純粋ロジック）
    static func parsePaneTargets(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty, !target.isEmpty else { continue }
            map[tty] = target
        }
        return map
    }

    /// セッションにアタッチしているクライアントのtty（例 "/dev/ttys004"）を返す。
    /// どのターミナルのどのタブで動いているかを特定するために使う (Jump)。
    /// デタッチ中のセッションでは nil。
    static func clientTTY(session: String) async -> String? {
        guard let result = try? await run(["list-clients", "-t", session, "-F", "#{client_tty}"]),
              result.succeeded else { return nil }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// `tmux capture-pane -p` でペインのプレーンテキストを取得する (設計書 5.1)
    static func capturePane(target: String) async -> String? {
        guard let result = try? await run(["capture-pane", "-p", "-J", "-t", target]),
              result.succeeded else { return nil }
        return result.stdout
    }

    /// `tmux send-keys` でプロンプトを送信する (設計書 4.3)
    /// テキストは `-l`（リテラル）で送り、Enterは別コマンドで送る。
    static func sendPrompt(_ text: String, to target: String) async throws {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return }

        let sendText = try await run(["send-keys", "-t", target, "-l", "--", sanitized])
        guard sendText.succeeded else {
            throw TmuxError.launchFailed(sendText.stderr.isEmpty ? "send-keys failed" : sendText.stderr)
        }
        // TUIがペーストを処理してからEnterを送る
        try? await Task.sleep(for: .milliseconds(120))
        let sendEnter = try await run(["send-keys", "-t", target, "Enter"])
        guard sendEnter.succeeded else {
            throw TmuxError.launchFailed(sendEnter.stderr.isEmpty ? "send-keys Enter failed" : sendEnter.stderr)
        }
    }

    /// 選択肢への回答キーを送信する（Approve / Ask）
    /// 番号選択メニューは番号キーだけで確定するため、Enterは needsEnter のときのみ送る。
    static func sendChoice(_ option: ChoiceOption, to target: String) async throws {
        let key = sanitize(option.keystroke)
        guard !key.isEmpty else { return }

        let sendKey = try await run(["send-keys", "-t", target, "-l", "--", key])
        guard sendKey.succeeded else {
            throw TmuxError.launchFailed(sendKey.stderr.isEmpty ? "send-keys failed" : sendKey.stderr)
        }
        guard option.needsEnter else { return }

        // TUIがキー入力を処理してからEnterを送る
        try? await Task.sleep(for: .milliseconds(120))
        let sendEnter = try await run(["send-keys", "-t", target, "Enter"])
        guard sendEnter.succeeded else {
            throw TmuxError.launchFailed(sendEnter.stderr.isEmpty ? "send-keys Enter failed" : sendEnter.stderr)
        }
    }

    /// send-keysに渡す前に制御文字を除去する (設計書 9)
    static func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let cleaned = normalized.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }
        return String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
