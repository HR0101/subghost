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
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"

    /// このイベントが表すセッション状態。nilなら状態を変えない。
    var resultingState: AIState? {
        switch self {
        case .sessionStart, .sessionEnd: return .completed
        case .userPromptSubmit, .preToolUse, .postToolUse: return .thinking
        // サブエージェントが終わっても親はまだ作業中
        case .subagentStart, .subagentStop: return .thinking
        // 圧縮は処理の一部なので状態は変えない
        case .preCompact, .postCompact: return nil
        case .notification, .permissionRequest: return .thinking
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

    /// 監視専用のため、CLIを待たせるイベントはない。
    var isBlocking: Bool { false }
}

// MARK: - イベント

nonisolated struct HookEvent: Sendable, Equatable {
    let kind: HookEventKind
    let sessionID: String
    let cwd: String?
    /// セッション記録(JSONL)のパス。プレビューを明示的に有効にした場合だけ読む。
    let transcriptPath: String?
    /// UserPromptSubmitに直接含まれる入力本文。CLIやバージョンによっては
    /// transcript_pathより早く、または確実に取得できる。
    let prompt: String?
    /// Stopイベントが直接渡す最新のAI返答。Codexはtranscript_pathと合わせて
    /// 提供するが、書き込み完了前でもポップアップへ即座に出せるよう利用する。
    let lastAssistantMessage: String?

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

        return HookEvent(
            kind: kind,
            sessionID: dict["session_id"] as? String ?? "",
            cwd: dict["cwd"] as? String,
            transcriptPath: Self.transcriptPath(in: dict),
            prompt: kind == .userPromptSubmit ? Self.prompt(in: dict) : nil,
            lastAssistantMessage: kind == .stop || kind == .subagentStop
                ? Self.lastAssistantMessage(in: dict)
                : nil
        )
    }

    private static func transcriptPath(in dict: [String: Any]) -> String? {
        for key in ["transcript_path", "transcriptPath", "rollout_path", "rolloutPath"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func prompt(in dict: [String: Any]) -> String? {
        // Claude Codeはprompt、Codexやラッパーはuser_prompt/messageを使うことがある。
        for key in ["prompt", "user_prompt", "userPrompt", "message"] {
            if let value = dict[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func lastAssistantMessage(in dict: [String: Any]) -> String? {
        for key in ["last_assistant_message", "lastAssistantMessage", "assistant_message"] {
            if let value = dict[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
    /// イベント名のキーはCLIによって異なるため、候補を順に探す
    static func eventName(in dict: [String: Any]) -> String? {
        let candidateKeys = ["hook_event_name", "hookEventName", "hook_event", "event_name", "event"]
        for key in candidateKeys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
