//
//  ConversationLocator.swift
//  Subghost
//
//  CLIプロセスの作業ディレクトリを表示用に解決する。
//

import Foundation

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
