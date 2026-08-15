//
//  TranscriptReader.swift
//  Subghost
//
//  完了通知で明示的に許可された場合だけ、セッション記録末尾から表示本文を読む。
//
//  記録は追記のみで巨大になりうるため、末尾の一定量だけを読む。
//

import Foundation

nonisolated enum AITaskStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress
    case completed
    case blocked
    case cancelled

    static func parse(_ raw: String?) -> Self {
        switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "in_progress", "inprogress", "active", "working": return .inProgress
        case "completed", "complete", "done", "success": return .completed
        case "blocked", "waiting": return .blocked
        case "cancelled", "canceled", "deleted": return .cancelled
        default: return .pending
        }
    }

    var displayName: String {
        switch self {
        case .pending: return "未着手"
        case .inProgress: return "進行中"
        case .completed: return "完了"
        case .blocked: return "停止中"
        case .cancelled: return "取消"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

/// CLIが持つチェックリストの1項目。本文と同じく、プライバシー設定が
/// 有効な場合はTranscriptReaderから取り出さない。
nonisolated struct AITaskItem: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let status: AITaskStatus
    let activeForm: String?

    init(
        id: String,
        title: String,
        status: AITaskStatus = .pending,
        activeForm: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.activeForm = activeForm
    }
}

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

    /// 記録から直近のAIタスクリストを取り出す。
    ///
    /// Claude CodeのTodoWrite/Task系と、Codexのupdate_planは保存形式が異なる。
    /// ここでは「最後に確認できたスナップショット」を基準にしつつ、TaskCreate/
    /// TaskUpdateの差分形式も後ろから順に適用する。タスクツールが一度も記録
    /// されていなければnil、空のリストが明示された場合は空配列を返す。
    static func latestTaskList(transcriptPath: String) -> [AITaskItem]? {
        guard let text = readTail(path: transcriptPath) else { return nil }
        return latestTaskList(inJSONLines: text)
    }

    static func latestTaskList(inJSONLines text: String) -> [AITaskItem]? {
        let records = text.split(separator: "\n").suffix(maxRecords).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        var current: [AITaskItem] = []
        var foundTaskRecord = false
        for record in records {
            guard let taskRecord = taskRecord(in: record) else { continue }
            foundTaskRecord = true
            switch taskRecord {
            case .snapshot(let items):
                current = items
            case .upsert(let change), .update(let change):
                apply(change, to: &current)
            case .remove(let id):
                current.removeAll { $0.id == id }
            }
        }
        return foundTaskRecord ? current : nil
    }

    /// Claude CodeのTaskCreate/TaskUpdateが保持する、セッション単位のタスク状態を読む。
    /// 現行のClaude Codeは会話JSONLとは別に ~/.claude/tasks/<session-id>/*.json
    /// を更新するため、JSONLにツール呼び出しが残らない場合もこちらを正とする。
    static func latestClaudeTaskList(sessionID: String) -> [AITaskItem]? {
        guard !sessionID.isEmpty else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tasks", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            ?? []
        let files = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return latestClaudeTaskList(inJSONFiles: files) ?? []
    }

    /// Claude Codeのタスクファイル形式をテスト可能な形で正規化する。
    static func latestClaudeTaskList(inJSONFiles files: [String]) -> [AITaskItem]? {
        guard !files.isEmpty else { return [] }
        let tasks = files.compactMap { file -> AITaskItem? in
            guard let data = file.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = firstString(in: dictionary, keys: ["id"]),
                  let title = firstString(in: dictionary, keys: ["subject", "title", "content"])
            else { return nil }
            return AITaskItem(
                id: id,
                title: title,
                status: AITaskStatus.parse(firstString(in: dictionary, keys: ["status", "state"])),
                activeForm: firstString(in: dictionary, keys: ["activeForm", "active_form"])
            )
        }
        return tasks
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

    private struct TaskChange {
        let id: String
        let title: String?
        let status: AITaskStatus?
        let activeForm: String?
    }

    private enum TaskRecord {
        case snapshot([AITaskItem])
        case upsert(TaskChange)
        case update(TaskChange)
        case remove(String)
    }

    private static func taskRecord(in record: [String: Any]) -> TaskRecord? {
        // Claude Code: assistant.message.content にtool_useブロックが入る。
        if let message = record["message"] as? [String: Any],
           let blocks = message["content"] as? [Any] {
            for block in blocks {
                guard let block = block as? [String: Any],
                      block["type"] as? String == "tool_use",
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                if let result = taskRecord(
                    toolName: name,
                    input: input,
                    toolCallID: block["id"] as? String
                ) {
                    return result
                }
            }
        }

        guard let payload = record["payload"] as? [String: Any] else {
            // ラッパーがtool callをトップレベルへ持ち上げる形式にも対応する。
            if let name = record["name"] as? String,
               let input = dictionary(from: record["input"] ?? record["arguments"]) {
                return taskRecord(toolName: name, input: input, toolCallID: record["id"] as? String)
            }
            return nil
        }

        // Codex rollout: response_item.payload.type=function_call。
        if let name = payload["name"] as? String,
           let input = dictionary(from: payload["arguments"] ?? payload["input"])
        {
            if let result = taskRecord(toolName: name, input: input, toolCallID: payload["call_id"] as? String) {
                return result
            }
        }

        // Codexのイベント形式。plan_update/task_listの配列は全体スナップショット。
        if record["type"] as? String == "event_msg",
           let eventType = payload["type"] as? String {
            let normalized = normalizedName(eventType)
            if normalized == "planupdate" || normalized == "tasklist" {
                return snapshot(in: payload, keys: ["plan", "tasks", "todos", "items"])
            }
        }

        return nil
    }

    private static func taskRecord(
        toolName: String,
        input: [String: Any],
        toolCallID: String?
    ) -> TaskRecord? {
        let normalized = normalizedName(toolName)
        switch normalized {
        case "todowrite":
            return snapshot(in: input, keys: ["todos", "tasks"])
        case "updateplan":
            return snapshot(in: input, keys: ["plan", "tasks", "todos"])
        case "tasklist":
            return snapshot(in: input, keys: ["tasks", "todos", "plan"])
        case "taskcreate":
            guard let change = taskChange(in: input, fallbackID: toolCallID, defaultStatus: .pending)
            else { return nil }
            return .upsert(change)
        case "taskupdate":
            guard let change = taskChange(in: input, fallbackID: toolCallID, defaultStatus: nil)
            else { return nil }
            return .update(change)
        case "taskdelete":
            guard let id = firstString(in: input, keys: ["taskId", "task_id", "id"]) else { return nil }
            return .remove(id)
        default:
            // 将来のタスク工具名でも、既知の配列キーがあれば安全に拾う。
            return snapshot(in: input, keys: ["todos", "tasks", "plan", "task_list", "taskList"])
        }
    }

    private static func snapshot(in dictionary: [String: Any], keys: [String]) -> TaskRecord? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            guard let rawItems = value as? [Any] else { return nil }
            let items = rawItems.enumerated().compactMap { index, value in
                taskItem(from: value, index: index, fallbackID: nil)
            }
            return .snapshot(items)
        }
        return nil
    }

    private static func taskItem(from value: Any, index: Int, fallbackID: String?) -> AITaskItem? {
        guard let dictionary = value as? [String: Any],
              let title = firstString(
                  in: dictionary,
                  keys: ["content", "step", "subject", "title", "task", "description"]
              ),
              !title.isEmpty
        else { return nil }

        let id = firstString(in: dictionary, keys: ["id", "taskId", "task_id"])
            ?? fallbackID
            ?? String(index)
        let activeForm = firstString(in: dictionary, keys: ["activeForm", "active_form"])
        let status = AITaskStatus.parse(firstString(in: dictionary, keys: ["status", "state"]))
        return AITaskItem(id: id, title: title, status: status, activeForm: activeForm)
    }

    private static func taskChange(
        in dictionary: [String: Any],
        fallbackID: String?,
        defaultStatus: AITaskStatus?
    ) -> TaskChange? {
        guard let id = firstString(in: dictionary, keys: ["id", "taskId", "task_id"]) ?? fallbackID else {
            return nil
        }
        let title = firstString(
            in: dictionary,
            keys: ["content", "step", "subject", "title", "task", "description"]
        )
        let rawStatus = firstString(in: dictionary, keys: ["status", "state"])
        let status = rawStatus.map(AITaskStatus.parse) ?? defaultStatus
        let activeForm = firstString(in: dictionary, keys: ["activeForm", "active_form"])
        return TaskChange(id: id, title: title, status: status, activeForm: activeForm)
    }

    private static func apply(_ change: TaskChange, to items: inout [AITaskItem]) {
        if let index = items.firstIndex(where: { $0.id == change.id }) {
            let existing = items[index]
            items[index] = AITaskItem(
                id: existing.id,
                title: change.title ?? existing.title,
                status: change.status ?? existing.status,
                activeForm: change.activeForm ?? existing.activeForm
            )
            return
        }
        guard let title = change.title, !title.isEmpty else { return }
        items.append(AITaskItem(
            id: change.id,
            title: title,
            status: change.status ?? .pending,
            activeForm: change.activeForm
        ))
    }

    private static func dictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let string = value as? String,
              let data = string.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func normalizedName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
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
