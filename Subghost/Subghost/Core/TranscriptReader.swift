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
                  let message = message(in: record),
                  message.role == .assistant
            else { continue }

            return normalize(message.text)
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
                  let message = message(in: record),
                  message.role == .user
            else { continue }

            return oneLine(message.text)
        }
        return nil
    }

    // MARK: - JSONL形式の差異

    /// Claude Codeの記録とCodexのrollout記録を、同じ役割・本文へ正規化する。
    ///
    /// Claudeは `assistant.message.content`、Codexは
    /// `response_item.payload` または `event_msg.payload` に本文を持つ。
    /// CLIごとの差異をこの正規化層へ閉じ込め、表示側が形式を意識しないようにする。
    private struct TranscriptMessage {
        enum Role: Equatable { case user, assistant }
        let role: Role
        let text: String
    }

    private static func message(in record: [String: Any]) -> TranscriptMessage? {
        let type = record["type"] as? String

        // Claude Code transcript:
        // {"type":"user|assistant", "message":{"content": ...}}
        if type == "user" || type == "assistant",
           let message = record["message"] as? [String: Any],
           let text = text(from: message["content"]),
           !text.isEmpty {
            return TranscriptMessage(
                role: type == "user" ? .user : .assistant,
                text: text
            )
        }

        guard let payload = record["payload"] as? [String: Any] else { return nil }

        // Codex rollout:
        // {"type":"response_item", "payload":{"type":"message",
        //   "role":"user|assistant", "content":[...]}}
        if type == "response_item",
           payload["type"] as? String == "message",
           let rawRole = payload["role"] as? String,
           let role = role(for: rawRole),
           let text = text(from: payload["content"]),
           !text.isEmpty {
            return TranscriptMessage(role: role, text: text)
        }

        // Codex also emits compact event messages in some versions.
        // They are useful as a fallback when response_item content is omitted.
        guard type == "event_msg",
              let rawType = payload["type"] as? String,
              let role = role(forEventType: rawType),
              let text = payload["message"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return TranscriptMessage(role: role, text: text)
    }

    private static func role(for rawRole: String) -> TranscriptMessage.Role? {
        switch rawRole.lowercased() {
        case "user": return .user
        case "assistant", "agent": return .assistant
        default: return nil
        }
    }

    private static func role(forEventType rawType: String) -> TranscriptMessage.Role? {
        switch rawType.lowercased() {
        case "user_message", "userprompt": return .user
        case "agent_message", "assistant_message": return .assistant
        default: return nil
        }
    }

    /// contentは文字列の場合と、text/input_text/output_textブロック配列の場合がある。
    private static func text(from content: Any?) -> String? {
        if let plain = content as? String {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let value = block["text"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
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
