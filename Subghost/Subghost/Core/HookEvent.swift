//
//  HookEvent.swift
//  Subghost
//
//  設計書 追補: フック方式
//
//  Claude Codeのフックが標準入力へ渡すJSONを解釈する。
//  仕様変更に耐えるため、未知のフィールドや形が違う場合は
//  「解釈できない」として素通し（CLI本来の挙動）に倒す。
//

import Foundation

// MARK: - イベント種別

nonisolated enum HookEventKind: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"   // コンテキストが逼迫し圧縮が始まる

    /// このイベントが表すセッション状態。nilなら状態を変えない。
    var resultingState: AIState? {
        switch self {
        case .sessionStart, .sessionEnd: return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse: return .thinking
        // サブエージェントが終わっても親はまだ作業中
        case .subagentStop: return .thinking
        // 圧縮は処理の一部なので状態は変えない
        case .preCompact: return nil
        case .notification: return .awaitingAnswer
        case .permissionRequest: return .awaitingApproval
        case .stop: return .completed
        case .stopFailure: return .error
        }
    }

    /// CLIによって表記が揺れる（PascalCase / snake_case）ため、正規化して解釈する
    init?(normalizing raw: String) {
        if let exact = HookEventKind(rawValue: raw) {
            self = exact
            return
        }
        // "permission_request" や "permissionrequest" も受け付ける
        let flattened = raw.replacingOccurrences(of: "_", with: "").lowercased()
        guard let match = HookEventKind.allCases.first(where: {
            $0.rawValue.lowercased() == flattened
        }) else { return nil }
        self = match
    }

    /// 応答を返すまでCLIを待たせる必要があるか
    var isBlocking: Bool { self == .permissionRequest }
}

// MARK: - イベント

nonisolated struct HookEvent: Sendable, Equatable {
    let kind: HookEventKind
    let sessionID: String
    let cwd: String?
    /// 権限リクエストの対象ツール名（"Bash" 等）
    let toolName: String?
    /// 権限リクエストの内容を1行に要約したもの（コマンド文字列など）
    let toolSummary: String?
    /// Notificationイベントの本文
    let message: String?
    /// セッション記録(JSONL)のパス。選択肢の復元に使う。
    let transcriptPath: String?

    /// ノッチに出す問いかけ文
    var title: String {
        switch kind {
        case .permissionRequest:
            if let toolName, let toolSummary, !toolSummary.isEmpty {
                return "\(toolName) の実行を許可しますか？\n\(toolSummary)"
            }
            if let toolName { return "\(toolName) の実行を許可しますか？" }
            return "実行を許可しますか？"
        case .notification:
            return message ?? "入力を待っています"
        default:
            return kind.rawValue
        }
    }

    /// 作業ディレクトリ名（表示用）
    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - 解釈

nonisolated enum HookEventDecoder {

    /// フックのJSONを解釈する。解釈できなければ nil。
    static func decode(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let rawName = Self.eventName(in: dict),
              let kind = HookEventKind(normalizing: rawName)
        else { return nil }

        let toolInput = dict["tool_input"] as? [String: Any]

        return HookEvent(
            kind: kind,
            sessionID: dict["session_id"] as? String ?? "",
            cwd: dict["cwd"] as? String,
            toolName: dict["tool_name"] as? String,
            toolSummary: toolInput.flatMap { summarize(toolInput: $0) },
            message: dict["message"] as? String,
            transcriptPath: dict["transcript_path"] as? String
        )
    }

    /// イベント名のキーはCLIによって異なるため、候補を順に探す
    static func eventName(in dict: [String: Any]) -> String? {
        let candidateKeys = ["hook_event_name", "hookEventName", "hook_event", "event_name", "event"]
        for key in candidateKeys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// tool_inputから人が読める1行の要約を作る
    static func summarize(toolInput: [String: Any], maxLength: Int = 120) -> String? {
        // よく使われるキーを優先順に拾う
        let preferredKeys = ["command", "file_path", "path", "pattern", "url", "description"]
        var summary: String?
        for key in preferredKeys {
            if let value = toolInput[key] as? String, !value.isEmpty {
                summary = value
                break
            }
        }
        guard var text = summary else { return nil }

        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "…"
        }
        return text
    }
}

// MARK: - 権限リクエストへの応答

nonisolated enum HookDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
    /// 介入せず、CLI本来の確認画面に任せる
    case passthrough

    /// フックの標準出力へ返すJSON
    var json: String {
        switch self {
        case .passthrough:
            // 空オブジェクト＝何も指示しない。CLIは通常どおりユーザーに尋ねる。
            return "{}"
        case .allow:
            return Self.decisionJSON(decision: "allow", reason: "Subghostで承認しました")
        case .deny(let reason):
            return Self.decisionJSON(decision: "deny", reason: reason)
        }
    }

    private static func decisionJSON(decision: String, reason: String) -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
