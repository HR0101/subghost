//
//  ConversationLocator.swift
//  Subghost
//
//  設計書 追補: 監視できないセッションでも会話履歴を出す
//
//  状態（動作中か）はフックやtmuxが無いと分からないが、直近のやり取り
//  （送ったプロンプトと返信）はセッション記録から読める。
//  記録は作業ディレクトリから特定できるため、psで見つけただけのセッションでも
//  会話履歴を表示できる。
//

import Foundation

/// 直近のやり取り
nonisolated struct ConversationTail: Sendable, Equatable {
    let userPrompt: String?
    let assistantReply: String?

    var isEmpty: Bool { userPrompt == nil && assistantReply == nil }
}

nonisolated enum ConversationLocator {

    // MARK: - プロセスの作業ディレクトリ

    /// プロセスの作業ディレクトリを lsof で取得する
    static func workingDirectory(pid: Int32) -> String? {
        guard let output = runLsof(["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        return parseWorkingDirectory(output)
    }

    /// lsof -Fn の出力から作業ディレクトリ行を取り出す（テスト対象）
    static func parseWorkingDirectory(_ output: String) -> String? {
        // "n" で始まる行がファイル名（cwdのパス）
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    // MARK: - Claude Codeの記録

    /// Claude Codeは作業ディレクトリのパスを "/" と空白を "-" に置換してディレクトリ名にする
    static func claudeProjectDirName(cwd: String) -> String {
        cwd.map { $0 == "/" || $0 == " " ? "-" : String($0) }.joined()
    }

    /// 作業ディレクトリに対応する、直近のClaude記録ファイルのパス
    static func claudeTranscriptPath(cwd: String) -> String? {
        let dirName = claudeProjectDirName(cwd: cwd)
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(dirName)", isDirectory: true)
        return newestJSONL(in: projectDir)
    }

    /// ディレクトリ内で最も新しい .jsonl のパス
    static func newestJSONL(in directory: URL) -> String? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (path: String, date: Date)?
        for url in entries where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.date {
                newest = (url.path, modified)
            }
        }
        return newest?.path
    }

    // MARK: - 会話履歴の取得

    /// セッションの直近のやり取りを取得する。
    /// フック由来の記録パスがあればそれを、無ければ作業ディレクトリから探す。
    static func conversationTail(pid: Int32, profileID: String) -> ConversationTail {
        let path: String?
        switch profileID {
        case "codex":
            path = CodexRollout.latestPath()
        default: // claude
            guard let cwd = workingDirectory(pid: pid) else { return ConversationTail(userPrompt: nil, assistantReply: nil) }
            path = claudeTranscriptPath(cwd: cwd)
        }
        guard let path, let text = TranscriptReader.readTail(path: path) else {
            return ConversationTail(userPrompt: nil, assistantReply: nil)
        }

        let reply = TranscriptReader.latestAssistantText(inJSONLines: text).first
        let prompt = TranscriptReader.latestUserText(inJSONLines: text)
        return ConversationTail(userPrompt: prompt, assistantReply: reply)
    }

    // MARK: - lsof 実行

    private static func runLsof(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
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
            NSLog("Subghost: lsofの実行に失敗しました: \(error.localizedDescription)")
            return nil
        }
    }
}
