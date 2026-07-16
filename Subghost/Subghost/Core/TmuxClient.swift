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

    /// `tmux list-sessions` で "ai-*" セッションを列挙する (設計書 10.2)
    static func listAISessions() async -> [String] {
        guard let result = try? await run(["list-sessions", "-F", "#{session_name}"]),
              result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("ai-") }
            .sorted()
    }

    /// `tmux capture-pane -p` でペインのプレーンテキストを取得する (設計書 5.1)
    static func capturePane(session: String) async -> String? {
        guard let result = try? await run(["capture-pane", "-p", "-J", "-t", session]),
              result.succeeded else { return nil }
        return result.stdout
    }

    /// `tmux send-keys` でプロンプトを送信する (設計書 4.3)
    /// テキストは `-l`（リテラル）で送り、Enterは別コマンドで送る。
    static func sendPrompt(_ text: String, to session: String) async throws {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return }

        let sendText = try await run(["send-keys", "-t", session, "-l", "--", sanitized])
        guard sendText.succeeded else {
            throw TmuxError.launchFailed(sendText.stderr.isEmpty ? "send-keys failed" : sendText.stderr)
        }
        // TUIがペーストを処理してからEnterを送る
        try? await Task.sleep(for: .milliseconds(120))
        let sendEnter = try await run(["send-keys", "-t", session, "Enter"])
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
