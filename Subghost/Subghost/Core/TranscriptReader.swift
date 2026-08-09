//
//  TranscriptReader.swift
//  Subghost
//
//  完了通知で明示的に許可された場合だけ、セッション記録末尾から表示本文を読む。
//
//  記録は追記のみで巨大になりうるため、末尾の一定量だけを読む。
//

import Foundation

nonisolated enum TranscriptReader {

    /// 末尾から読む最大バイト数。
    static let tailByteLimit = 256 * 1024
    /// 走査するレコード数の上限
    static let maxRecords = 60
    // MARK: - 公開API

    /// 応答本文として取り出す最大行数
    static let maxAnswerLines = 40

    /// 記録の末尾から、直近のAIの応答本文を取り出す
    static func latestAssistantText(transcriptPath: String) -> [String] {
        guard let text = readTail(path: transcriptPath) else { return [] }
        return latestAssistantText(inJSONLines: text)
    }

    /// JSONL文字列から直近の応答本文を取り出す（テスト対象の純粋ロジック）
    ///
    /// 末尾のレコードから遡り、最初に見つかったテキストブロックを本文とする。
    /// ツール実行だけのレコードは本文を持たないため読み飛ばす。
    static func latestAssistantText(inJSONLines text: String) -> [String] {
        let lines = text.split(separator: "\n").suffix(maxRecords)

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }

            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let value = block["text"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
            guard !texts.isEmpty else { continue }

            return normalize(texts.joined(separator: "\n"))
        }
        return []
    }

    /// 記録の末尾から、直近のユーザー発言を1行にして取り出す
    static func latestUserText(transcriptPath: String) -> String? {
        guard let text = readTail(path: transcriptPath) else { return nil }
        return latestUserText(inJSONLines: text)
    }

    static func latestUserText(inJSONLines text: String) -> String? {
        let lines = text.split(separator: "\n").suffix(maxRecords)

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["type"] as? String == "user",
                  let message = record["message"] as? [String: Any]
            else { continue }

            // content は文字列の場合と配列の場合がある
            if let plain = message["content"] as? String, !plain.isEmpty {
                return oneLine(plain)
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let value = block["text"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
            if let first = texts.first { return oneLine(first) }
        }
        return nil
    }

    /// 一覧に収まるよう1行へ畳む
    static func oneLine(_ text: String, maxLength: Int = 120) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > maxLength ? String(flat.prefix(maxLength)) + "…" : flat
    }

    /// 表示用に行へ分解する。空行の連続をまとめ、行数を制限する。
    static func normalize(_ text: String) -> [String] {
        var result: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 空行が続く場合は1行にまとめる（ノッチの限られた高さを無駄にしない）
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
            if result.count >= maxAnswerLines { break }
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    // MARK: - ファイル読み込み

    /// ファイル末尾の一定量を文字列として読む。
    /// 先頭が行の途中で切れる可能性があるため、最初の改行までは捨てる。
    static func readTail(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return nil }

            var text = String(decoding: data, as: UTF8.self)
            // 途中から読み始めた場合、最初の行は壊れている可能性がある
            if offset > 0, let firstBreak = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstBreak)...])
            }
            return text
        } catch {
            NSLog("Subghost: セッション記録を読めませんでした: \(error.localizedDescription)")
            return nil
        }
    }
}
