//
//  Models.swift
//  Subghost
//
//  設計書 8. データモデル
//

import Foundation

// MARK: - AI状態 (設計書 4.1)

nonisolated enum AIState: String, Codable, Sendable {
    case idle       // 待機
    case thinking   // 生成中
    case completed  // 完了
    case error      // エラー

    var displayName: String {
        switch self {
        case .idle: return "待機"
        case .thinking: return "生成中"
        case .completed: return "完了"
        case .error: return "エラー"
        }
    }
}

// MARK: - CLIプロファイル (設計書 2.1 / 8.1)

/// AI CLIごとの出力パターン定義。状態判定・スピナー除去に使う。
nonisolated struct CLIProfile: Codable, Sendable, Identifiable, Hashable {
    let id: String              // "claude" | "codex" | "antigravity"
    let displayName: String
    let launchCommand: String
    /// プロンプト待ち受け記号（応答完了の指標）の正規表現
    let promptPattern: String
    /// 除去対象のスピナー/装飾文字の正規表現
    let spinnerPattern: String
    /// 「実行中」を強く示す文言の正規表現（あれば thinking を維持）
    let busyPattern: String
    /// エラー判定の正規表現
    let errorPattern: String

    static let claude = CLIProfile(
        id: "claude",
        displayName: "Claude Code",
        launchCommand: "claude",
        promptPattern: #"(^|\n)\s*(│|>)\s*(>|❯)?\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✻✽✢·✳*]+"#,
        busyPattern: #"esc to interrupt|Thinking…|Compacting|Wrangling|Herding|Simmering"#,
        errorPattern: #"(?i)(^|\n)\s*(Error:|API Error|✗ |fatal:|Traceback \(most recent call last\))"#
    )

    static let codex = CLIProfile(
        id: "codex",
        displayName: "Codex CLI",
        launchCommand: "codex",
        promptPattern: #"(^|\n)\s*(▌|›|❯|>)\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+"#,
        busyPattern: #"Esc to interrupt|Working|Thinking"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |stream error|fatal:)"#
    )

    static let antigravity = CLIProfile(
        id: "antigravity",
        displayName: "Antigravity",
        launchCommand: "antigravity",
        promptPattern: #"(^|\n)\s*(❯|>|\$)\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+"#,
        busyPattern: #"(?i)running|thinking|working|executing"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |fatal:)"#
    )

    static let builtins: [CLIProfile] = [.claude, .codex, .antigravity]

    /// tmuxセッション名（"ai-claude" 等）からプロファイルを推定
    static func match(sessionName: String, from profiles: [CLIProfile] = builtins) -> CLIProfile {
        let suffix = sessionName.hasPrefix("ai-") ? String(sessionName.dropFirst(3)) : sessionName
        return profiles.first { suffix.lowercased().hasPrefix($0.id) } ?? .claude
    }
}

// MARK: - スニペット (設計書 4.4 / 8.1)

nonisolated struct Snippet: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    static let defaults: [Snippet] = [
        Snippet(title: "テストも書いて", body: "テストも書いてください"),
        Snippet(title: "日本語で", body: "日本語で説明してください"),
        Snippet(title: "リファクタして", body: "このコードをリファクタリングしてください"),
        Snippet(title: "続けて", body: "続けてください"),
    ]
}

// MARK: - セッション情報 (設計書 8.1)

nonisolated struct SessionInfo: Sendable, Identifiable, Hashable {
    let tmuxName: String        // "ai-claude" 等
    let profile: CLIProfile

    var id: String { tmuxName }

    /// "ai-claude" → "claude" のような短い表示名
    var shortName: String {
        tmuxName.hasPrefix("ai-") ? String(tmuxName.dropFirst(3)) : tmuxName
    }
}
