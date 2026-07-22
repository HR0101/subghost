//
//  Models.swift
//  Subghost
//
//  設計書 8. データモデル
//
//  アプリ全体で共有する値型の定義をまとめた場所。
//  AI状態(AIState)、CLIごとの検出・判定パターン(CLIProfile)、
//  ユーザー登録の起動名(CustomAlias)、定型文(Snippet)、
//  検出したセッション1件(SessionInfo)。
//  いずれも振る舞いを持たない純粋なデータで、I/Oは Core 側が担う。
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
        case .idle: return "Stand-by"
        case .thinking: return "Working"
        case .awaitingApproval: return "Approval"
        case .awaitingAnswer: return "Question"
        case .completed: return "Done"
        case .error: return "Error"
        }
    }

    /// VoiceOverへ読み上げる状態名。
    /// 画面上のバッジは短さを優先して英語のままだが、日本語UIの読み上げに英単語が
    /// 混ざると意味が伝わらないため、支援技術にはこちらを渡す。
    var accessibilityDescription: String {
        switch self {
        case .idle: return "待機中"
        case .thinking: return "生成中"
        case .awaitingApproval: return "承認待ち"
        case .awaitingAnswer: return "質問への回答待ち"
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
    /// psのcommに現れる実行ファイル名（この名前でプロセスを同定する）。
    /// ビルトインの名前に加え、ユーザー登録のカスタムエイリアス名もここへ合成される。
    var executableNames: [String]
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
        // 実機のClaude Codeは「横罫線＋❯」入力UI。単独の ❯ 行にもマッチさせる
        promptPattern: #"(^|\n)\s*(│\s*)?(>|❯)"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✻✽✢·✳*]+"#,
        // 実機の作業中表示は `✢ Drizzling… (2m 35s · ↓ 10.5k tokens)` で、
        // 動詞は毎回ランダムに変わり "esc to interrupt" も出ない。文言を並べても追随できないため、
        // 「…（経過時間」「経過秒数…」「↓ トークン数」という形そのものを目印にする。
        // (StateDetector.stripDecoration のテキストに対して当てること。cleanでは数字が消える)
        busyPattern: #"esc to interrupt|…\s*\(\d|\d+(\.\d+)?s…|↓\s*\d+(\.\d+)?k?\s*tokens"#
            + #"|Thinking…|Compacting"#,
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
        busyPattern: #"Esc to interrupt|Working|Thinking|…\s*\(\d|\d+(\.\d+)?s…"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |stream error|fatal:)"#,
        approvalPattern: commonApprovalPattern
    )

    static let antigravity = CLIProfile(
        id: "antigravity",
        displayName: "Antigravity",
        launchCommand: "agy",
        // 実体は "agy"（実測: /Users/*/.local/bin/agy）。
        // "antigravity" という名前のコマンドは存在しない。
        executableNames: ["agy", "antigravity"],
        promptPattern: #"(^|\n)\s*(❯|>|\$)\s*"#,
        spinnerPattern: #"[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+"#,
        busyPattern: #"(?i)running|thinking|working|executing"#,
        errorPattern: #"(?i)(^|\n)\s*(error:|✗ |fatal:)"#,
        approvalPattern: commonApprovalPattern
    )

    static let builtins: [CLIProfile] = [.claude, .codex, .antigravity]

    /// ビルトインのプロファイルに、ユーザー登録のカスタムエイリアス名を合成して返す。
    /// (実行ファイル名が違うだけで実体は同じCLIを、独自の名前やラッパースクリプトで
    /// 起動している場合に、そのCLIとして検出できるようにするため)
    static func withCustomAliases(_ aliases: [CustomAlias]) -> [CLIProfile] {
        var result = builtins
        for alias in aliases {
            // AgentDiscovery.matchProfile は実行ファイル名を小文字化してから比較するため、
            // ここでも小文字化して揃えておかないと大文字混じりの登録が一致しなくなる。
            let name = alias.name.lowercased()
            guard !name.isEmpty,
                  let index = result.firstIndex(where: { $0.id == alias.baseProfileID }),
                  !result[index].executableNames.contains(name)
            else { continue }
            result[index].executableNames.append(name)
        }
        return result
    }
}

// MARK: - カスタムエイリアス (設計書 追補: ユーザー独自のCLI起動名)

/// ユーザーが登録した、既存CLIプロファイルに紐づく追加の実行ファイル名。
/// 例: 独自のラッパースクリプト「codexA」をCodexとして検出させたい場合。
nonisolated struct CustomAlias: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// psのcommに現れる実行ファイル名（大文字小文字は区別しない）
    var name: String
    /// 紐づける既存プロファイルのid（"claude" | "codex" | "antigravity"）
    var baseProfileID: String

    init(id: UUID = UUID(), name: String, baseProfileID: String) {
        self.id = id
        self.name = name
        self.baseProfileID = baseProfileID
    }

    /// シェル関数名・実行ファイル名として安全に使える名前か。
    ///
    /// この名前は ShellIntegration.scriptBody でシェルスクリプトへそのまま
    /// 埋め込まれ関数定義になる（例: "\(name)() { ... }"）。空白・セミコロン・
    /// 括弧・コマンド置換などを許すとシェルインジェクションが成立してしまうため、
    /// 関数名として安全な文字だけに制限する。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
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

// MARK: - セッションに対してできること

/// Subghostがそのセッションに対して何をできるかの区分。
///
/// tmux を使う構成と使わない構成で、できることがはっきり違う。
/// 画面のあちこちで `tmuxTarget != nil` を個別に判定すると
/// 「入力欄は出るのに送れない」といった食い違いが生まれるため、
/// 判断はこの型に集約し、UIはこれを見て出し分ける。
nonisolated enum SessionCapability: Int, Sendable, Comparable, CaseIterable {
    /// 検出しただけ。状態は読めず、送信もできない。ターミナルのタブへ移動できるのみ。
    case detectedOnly
    /// 監視のみ（tmuxなしの簡易構成）。フックで状態・完了通知は届き、
    /// 承認の「はい／いいえ」もフックの戻り値で答えられる。
    /// ただし任意のテキストを送る経路が無いため、プロンプト入力は提供しない。
    case monitorOnly
    /// tmux経由で任意のテキストを送れる。すべての機能が使える。
    case full

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 一覧のバッジ用の短い名前
    var label: String {
        switch self {
        case .detectedOnly: return "検出のみ"
        case .monitorOnly: return "監視のみ"
        case .full: return "送信可"
        }
    }

    /// この段階に到達するために必要な構成（設定画面の一覧に出す）
    var requirement: String {
        switch self {
        case .detectedOnly: return "設定不要"
        case .monitorOnly: return "フック登録"
        case .full: return "フック登録 ＋ tmux"
        }
    }

    /// 何ができるのかを一文で説明する（支援技術の読み上げと補足文に使う）
    var summary: String {
        switch self {
        case .detectedOnly:
            return "起動は検出できていますが、状態の取得も送信もできません。"
                + "フックを登録すると状態が分かるようになります。"
        case .monitorOnly:
            return "状態の監視と承認への回答ができます。"
                + "プロンプトの送信には tmux が必要です。"
        case .full:
            return "状態の監視、プロンプトの送信、質問への回答がすべて行えます。"
        }
    }
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
    /// プロセスの作業ディレクトリ（表示用）。psで見つけたセッションでも解決する。
    var workingDirectory: String?
    /// 動作しているターミナルの名前（表示用）。検出時に一度だけ解決する。
    var terminalName: String?

    var id: String { tty }

    /// フック方式で監視できているか（tmux不要）
    var isHookConnected: Bool { hookSessionID != nil }

    /// このセッションに対してSubghostが何をできるか。
    /// UIの出し分けは必ずここを見る（tmuxの有無を画面ごとに個別判定しない）。
    var capability: SessionCapability {
        if tmuxTarget != nil { return .full }
        if isHookConnected { return .monitorOnly }
        return .detectedOnly
    }

    /// 状態を読めるか。フックが届いていればtmuxは不要。
    /// どちらも無ければ検出とタブ移動のみ。
    var isMonitorable: Bool { capability >= .monitorOnly }

    /// 任意のテキスト（プロンプト）を送れるか。
    ///
    /// 送信経路は tmux の pty 書き込みだけ。キー入力の合成（KeystrokeSender）は
    /// 対象タブを前面に出す必要があり、「裏で動いているCLIへ送る」という
    /// この機能の前提を満たせないため、送信経路には数えない。
    var canSendPrompt: Bool { capability == .full }

    /// "ttys004" のような短い表示名
    var shortName: String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// CLIが起動しているフォルダ名（作業ディレクトリの末尾）
    var folderName: String? {
        if let projectName, !projectName.isEmpty { return projectName }
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// ノッチやメニューに出す表示名。ttyではなくフォルダ名を主体にする。
    var displayName: String {
        folderName ?? tmuxSession ?? shortName
    }

    /// 監視の経路（表示・診断用）
    var monitoringSource: String {
        if isHookConnected { return "フック" }
        if tmuxTarget != nil { return "tmux" }
        return "なし"
    }

    /// 一覧のバッジに出す、できることの短い説明
    var capabilityLabel: String { capability.label }

    init(agent: DiscoveredAgent) {
        self.tty = agent.tty
        self.profile = agent.profile
        self.pid = agent.pid
        self.tmuxTarget = agent.tmuxTarget
        self.tmuxSession = agent.tmuxSession
    }
}
