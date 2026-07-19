//
//  Models.swift
//  Subghost
//
//  設計書 8. データモデル
//

import Foundation

// MARK: - AI状態 (設計書 4.1)

nonisolated enum AIState: String, Codable, Sendable {
    case idle               // 待機
    case thinking           // 生成中
    case awaitingApproval   // 権限リクエストの承認待ち
    case awaitingAnswer     // エージェントからの質問待ち
    case completed          // 完了
    case error              // エラー

    var displayName: String {
        switch self {
        case .idle: return "待機"
        case .thinking: return "生成中"
        case .awaitingApproval: return "承認待ち"
        case .awaitingAnswer: return "質問中"
        case .completed: return "完了"
        case .error: return "エラー"
        }
    }

    /// ユーザーの応答がないと先に進まない状態か
    var needsUserResponse: Bool {
        self == .awaitingApproval || self == .awaitingAnswer
    }

    /// 状態ドットを点滅させて注意を引くべき状態か
    var shouldPulse: Bool {
        self == .thinking || needsUserResponse
    }
}

// MARK: - CLIプロファイル (設計書 2.1 / 8.1)

/// AI CLIごとの出力パターン定義。状態判定・スピナー除去に使う。
nonisolated struct CLIProfile: Codable, Sendable, Identifiable, Hashable {
    let id: String              // "claude" | "codex" | "antigravity"
    let displayName: String
    let launchCommand: String
    /// psのcommに現れる実行ファイル名（この名前でプロセスを同定する）
    let executableNames: [String]
    /// プロンプト待ち受け記号（応答完了の指標）の正規表現
    let promptPattern: String
    /// 除去対象のスピナー/装飾文字の正規表現
    let spinnerPattern: String
    /// 「実行中」を強く示す文言の正規表現（あれば thinking を維持）
    let busyPattern: String
    /// エラー判定の正規表現
    let errorPattern: String
    /// 選択肢の問いかけを「権限リクエスト」と分類する文言の正規表現。
    /// マッチしなければ「エージェントからの質問」として扱う。
    let approvalPattern: String

    /// 権限リクエストに共通して現れる文言（各プロファイルで共用）
    private static let commonApprovalPattern =
        #"(?i)(do you want|would you like|allow |permission|proceed\?|approve|grant |trust |apply (this )?(edit|patch|change)|run this command|承認|許可|実行しますか|適用しますか)"#

    static let claude = CLIProfile(
        id: "claude",
        displayName: "Claude Code",
        launchCommand: "claude",
        executableNames: ["claude"],
        promptPattern: #"(^|\n)\s*(│|>)\s*(>|❯)?\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✻✽✢·✳*]+"#,
        busyPattern: #"esc to interrupt|Thinking…|Compacting|Wrangling|Herding|Simmering"#,
        errorPattern: #"(?i)(^|\n)\s*(Error:|API Error|✗ |fatal:|Traceback \(most recent call last\))"#,
        approvalPattern: commonApprovalPattern
    )

    static let codex = CLIProfile(
        id: "codex",
        displayName: "Codex CLI",
        launchCommand: "codex",
        executableNames: ["codex"],
        promptPattern: #"(^|\n)\s*(▌|›|❯|>)\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+"#,
        busyPattern: #"Esc to interrupt|Working|Thinking"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |stream error|fatal:)"#,
        approvalPattern: commonApprovalPattern
    )

    static let antigravity = CLIProfile(
        id: "antigravity",
        displayName: "Antigravity",
        launchCommand: "antigravity",
        executableNames: ["antigravity", "anti"],
        promptPattern: #"(^|\n)\s*(❯|>|\$)\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+"#,
        busyPattern: #"(?i)running|thinking|working|executing"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |fatal:)"#,
        approvalPattern: commonApprovalPattern
    )

    static let builtins: [CLIProfile] = [.claude, .codex, .antigravity]
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

// MARK: - セッション情報 (設計書 8.1、追補: ゼロコンフィグ検出)

/// 検出したAI CLI 1つ分の識別情報。
/// ttyを同一性の軸にしているため、tmuxの有無やセッション名に依存しない。
nonisolated struct SessionInfo: Sendable, Identifiable, Hashable {
    /// 制御端末（"/dev/ttys004"）。ターミナルの1タブ／1ペインに対応する。
    let tty: String
    let profile: CLIProfile
    let pid: Int32
    /// tmuxのペイン宛先（"work:0.1"）。tmux外で動いている場合は nil。
    let tmuxTarget: String?
    /// 所属するtmuxセッション名。tmux外なら nil。
    let tmuxSession: String?
    /// フックが届いている場合のCLI側セッションID。tmuxなしでも監視できる。
    var hookSessionID: String?
    /// フック経由で得た作業ディレクトリ名（表示用）
    var projectName: String?

    var id: String { tty }

    /// フック方式で監視できているか（tmux不要）
    var isHookConnected: Bool { hookSessionID != nil }

    /// 画面の読み取りとキー送信ができるか。
    /// フックが届いていればtmuxは不要。どちらも無ければ検出とタブ移動のみ。
    var isMonitorable: Bool { tmuxTarget != nil || isHookConnected }

    /// "ttys004" のような短い表示名
    var shortName: String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// ノッチやメニューに出す表示名
    var displayName: String {
        if let projectName { return "\(projectName) (\(shortName))" }
        if let tmuxSession { return "\(tmuxSession) (\(shortName))" }
        return shortName
    }

    /// 監視の経路（表示・診断用）
    var monitoringSource: String {
        if isHookConnected { return "フック" }
        if tmuxTarget != nil { return "tmux" }
        return "なし"
    }

    init(agent: DiscoveredAgent) {
        self.tty = agent.tty
        self.profile = agent.profile
        self.pid = agent.pid
        self.tmuxTarget = agent.tmuxTarget
        self.tmuxSession = agent.tmuxSession
    }
}
