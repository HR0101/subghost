//
//  TranscriptReader.swift
//  Subghost
//
//  設計書 追補: 質問の選択肢をセッション記録から復元する
//
//  Notificationフックのペイロードには本文しか入っておらず、選択肢の一覧が含まれない。
//  一方でフックは transcript_path（セッション記録のJSONL）を渡してくるため、
//  その末尾を読めば直近の質問と選択肢を取り出せる。
//
//  記録は追記のみで巨大になりうるため、末尾の一定量だけを読む。
//

import Foundation

nonisolated enum TranscriptReader {

    /// 末尾から読む最大バイト数。質問1件を含むには十分な量。
    static let tailByteLimit = 256 * 1024
    /// 走査するレコード数の上限
    static let maxRecords = 60
    /// 選択肢を持つツール名
    static let questionToolNames = ["AskUserQuestion"]

    // MARK: - 公開API

    /// 記録の末尾から、直近の「選択肢つきの質問」を取り出す
    static func latestQuestion(transcriptPath: String) -> PendingChoice? {
        guard let text = readTail(path: transcriptPath) else { return nil }
        return latestQuestion(inJSONLines: text)
    }

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

    /// JSONL文字列から直近の質問を取り出す（テスト対象の純粋ロジック）
    static func latestQuestion(inJSONLines text: String) -> PendingChoice? {
        let lines = text.split(separator: "\n").suffix(maxRecords)

        // 新しいものから遡る
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }

            for block in blocks.reversed() {
                guard block["type"] as? String == "tool_use",
                      let name = block["name"] as? String,
                      questionToolNames.contains(name),
                      let input = block["input"] as? [String: Any],
                      let choice = parseQuestion(input: input)
                else { continue }
                return choice
            }
        }
        return nil
    }

    /// AskUserQuestion の入力から選択肢を組み立てる
    static func parseQuestion(input: [String: Any]) -> PendingChoice? {
        guard let questions = input["questions"] as? [[String: Any]],
              let first = questions.first,
              let title = first["question"] as? String,
              let rawOptions = first["options"] as? [[String: Any]]
        else { return nil }

        let options = rawOptions.enumerated().compactMap { index, entry -> ChoiceOption? in
            guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
            let number = index + 1
            return ChoiceOption(
                number: number,
                label: label,
                keystroke: String(number),
                needsEnter: false)
        }
        guard options.count >= 2 else { return nil }

        // 補足説明があれば文脈として最初の1件だけ添える
        let detail = (rawOptions.first?["description"] as? String).map { [$0] } ?? []

        return PendingChoice(
            kind: .question,
            title: title,
            detail: detail,
            options: options)
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
