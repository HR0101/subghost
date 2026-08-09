//
//  CodexRollout.swift
//  Subghost
//
//  設計書 追補: Codexの使用量取得
//
//  Codexにはstatuslineの仕組みが無く、レート制限はセッション記録(JSONL)の
//  `token_count` イベントにのみ含まれる。記録は日付階層に置かれるため、
//  最も新しいファイルを探して末尾を読む。
//

import Foundation

nonisolated enum CodexRollout {

    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// 日付階層とISO日時を含むファイル名から、直近のセッション記録を選ぶ。
    /// ファイル時刻APIを使わず、Codexの命名規則どおりの辞書順で比較する。
    static func latestPath() -> String? {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newestPath: String?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            if newestPath == nil || url.path > newestPath! { newestPath = url.path }
        }
        return newestPath
    }
}
