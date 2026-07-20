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

    /// 直近に更新されたセッション記録のパス
    static func latestPath() -> String? {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (path: String, date: Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.date {
                newest = (url.path, modified)
            }
        }
        return newest?.path
    }
}
