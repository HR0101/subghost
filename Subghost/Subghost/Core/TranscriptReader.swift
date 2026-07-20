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
        latestQuestions(transcriptPath: transcriptPath).first
    }

    /// 記録の末尾から、直近の質問を全問取り出す。
    /// AskUserQuestion は複数の問いを1回の呼び出しにまとめるため、配列で返す。
    static func latestQuestions(transcriptPath: String) -> [PendingChoice] {
        guard let text = readTail(path: transcriptPath) else { return [] }
        return latestQuestions(inJSONLines: text)
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

    /// JSONL文字列から直近の「未回答の」質問を取り出す（テスト対象の純粋ロジック）
    ///
    /// 質問(tool_use)には id があり、回答されると同じ tool_use_id を持つ
    /// tool_result が後に記録される。回答済みの質問を復元しないよう、
    /// tool_result が存在しない質問だけを返す。
    static func latestQuestion(inJSONLines text: String) -> PendingChoice? {
        latestQuestions(inJSONLines: text).first
    }

    /// JSONL文字列から直近の「未回答の」質問を全問取り出す（テスト対象の純粋ロジック）
    static func latestQuestions(inJSONLines text: String) -> [PendingChoice] {
        let records = text.split(separator: "\n").suffix(maxRecords).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // 回答済みの質問id（tool_result の tool_use_id）を集める
        let answeredIDs = Set(records.flatMap { record -> [String] in
            blocks(in: record).compactMap { block in
                block["type"] as? String == "tool_result"
                    ? block["tool_use_id"] as? String : nil
            }
        })

        // 新しいものから遡り、まだ回答されていない質問を探す
        for record in records.reversed() {
            for block in blocks(in: record).reversed() {
                guard block["type"] as? String == "tool_use",
                      let name = block["name"] as? String,
                      questionToolNames.contains(name)
                else { continue }
                // 回答済みは飛ばす
                if let id = block["id"] as? String, answeredIDs.contains(id) { continue }
                guard let input = block["input"] as? [String: Any] else { continue }
                let choices = parseQuestions(input: input)
                if choices.isEmpty { continue }
                return choices
            }
        }
        return []
    }

    /// レコードから content ブロックの配列を取り出す
    private static func blocks(in record: [String: Any]) -> [[String: Any]] {
        (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// AskUserQuestion の入力から先頭の問いを組み立てる（単一の問いを扱う既存経路向け）
    static func parseQuestion(input: [String: Any]) -> PendingChoice? {
        parseQuestions(input: input).first
    }

    /// AskUserQuestion の入力から全ての問いを組み立てる。
    ///
    /// questions は複数の問いを持てる。CLIは1問ずつ順に尋ねるため、
    /// ここでは配列のまま返し、回答のたびに次を出す側（SessionWatcher）へ委ねる。
    static func parseQuestions(input: [String: Any]) -> [PendingChoice] {
        guard let questions = input["questions"] as? [[String: Any]] else { return [] }

        let parsed = questions.compactMap { entry -> (String, [[String: Any]], Bool)? in
            guard let title = entry["question"] as? String,
                  let rawOptions = entry["options"] as? [[String: Any]]
            else { return nil }
            return (title, rawOptions, entry["multiSelect"] as? Bool ?? false)
        }
        guard !parsed.isEmpty else { return [] }

        return parsed.enumerated().compactMap { index, item in
            let (title, rawOptions, isMultiSelect) = item
            let options = buildOptions(from: rawOptions, isMultiSelect: isMultiSelect)
            guard options.count >= 2 else { return nil }

            // 補足説明があれば文脈として最初の1件だけ添える
            let detail = (rawOptions.first?["description"] as? String).map { [$0] } ?? []

            return PendingChoice(
                kind: .question,
                title: title,
                detail: detail,
                options: options,
                isMultiSelect: isMultiSelect,
                questionIndex: index + 1,
                questionCount: parsed.count)
        }
    }

    /// options 配列を ChoiceOption へ変換する
    private static func buildOptions(
        from rawOptions: [[String: Any]],
        isMultiSelect: Bool
    ) -> [ChoiceOption] {
        rawOptions.enumerated().compactMap { index, entry in
            guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
            let number = index + 1
            return ChoiceOption(
                number: number,
                label: label,
                keystroke: String(number),
                // 単一選択は「番号 → Enter」で確定する。
                // 複数選択は番号キーがトグルなので、確定のEnterは
                // 全ての番号を送り終えてから1度だけ送る（送信側で担当する）。
                needsEnter: !isMultiSelect)
        }
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
