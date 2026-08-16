//
//  Models.swift
//  Subghost
//
//  設計書 8. データモデル
//
//  アプリ全体で共有する値型の定義をまとめた場所。
//  AI状態(AIState)、CLIごとのプロセス照合情報(CLIProfile)、
//  ユーザー登録の起動名(CustomAlias)、
//  フック受信セッション1件(SessionInfo)。
//  いずれも振る舞いを持たない純粋なデータで、I/Oは Core 側が担う。
//

import Foundation

// MARK: - AI状態 (設計書 4.1)

nonisolated enum AIState: String, Codable, Sendable {
    case idle               // 待機
    case thinking           // 生成中
    case completed          // 完了
    case error              // エラー

    var displayName: String {
        switch self {
        case .idle: return "Done"
        case .thinking: return "Working"
        case .completed: return "Done"
        case .error: return "Done"
        }
    }

    /// VoiceOverへ読み上げる状態名。
    /// 画面上のバッジは短さを優先して英語のままだが、日本語UIの読み上げに英単語が
    /// 混ざると意味が伝わらないため、支援技術にはこちらを渡す。
    var accessibilityDescription: String {
        switch self {
        case .idle: return "完了"
        case .thinking: return "作業途中"
        case .completed: return "完了"
        case .error: return "完了"
        }
    }

    /// 状態ドットを点滅させて注意を引くべき状態か
    var shouldPulse: Bool {
        self == .thinking
    }
}

// MARK: - CLIプロファイル (設計書 2.1 / 8.1)

/// AI CLIごとのプロセス照合情報。
nonisolated struct CLIProfile: Codable, Sendable, Identifiable, Hashable {
    let id: String              // "claude" | "codex" | "antigravity"
    let displayName: String
    /// psのcommに現れる実行ファイル名（この名前でプロセスを同定する）。
    /// ビルトインの名前に加え、ユーザー登録のカスタムエイリアス名もここへ合成される。
    var executableNames: [String]

    static let claude = CLIProfile(
        id: "claude",
        displayName: "Claude Code",
        executableNames: ["claude"]
    )

    static let codex = CLIProfile(
        id: "codex",
        displayName: "Codex CLI",
        executableNames: ["codex"]
    )

    static let antigravity = CLIProfile(
        id: "antigravity",
        displayName: "Antigravity",
        // 実体は "agy"（実測: /Users/*/.local/bin/agy）。
        // "antigravity" という名前のコマンドは存在しない。
        executableNames: ["agy", "antigravity"]
    )

    static let builtins: [CLIProfile] = [.claude, .codex, .antigravity]

    /// ビルトインのプロファイルに、ユーザー登録のカスタムエイリアス名を合成して返す。
    /// 実行ファイル名が異なるラッパースクリプト等でも、フック済みセッションのPIDと
    /// TTYを照合できるようにする。
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
/// 例: 独自のラッパースクリプト「codexA」をCodexのセッションとして照合したい場合。
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

    /// プロセスの実行ファイル名として扱える、安全で短い名前か。
    /// 設定や表示へ持ち込む値を必要最小限の文字種に制限する。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }
}

// MARK: - セッション情報 (設計書 8.1)

/// フックを受信したAI CLIセッション1つ分の識別情報。
/// PIDまたはCLI側のhook session_idを同一性の軸にする。
/// TTYはターミナルへ移動するための属性であり、セッションIDには使わない。
nonisolated struct SessionInfo: Sendable, Identifiable, Hashable {
    /// 制御端末（"/dev/ttys004"）。ターミナルの1タブ／1ペインに対応する。
    let tty: String
    let profile: CLIProfile
    let pid: Int32
    /// フックが届いている場合のCLI側セッションID。
    var hookSessionID: String?
    /// フック経由で得た作業ディレクトリ名（表示用）
    var projectName: String?
    /// プロセスの作業ディレクトリ（表示用）。
    var workingDirectory: String?
    /// 動作しているターミナルの名前（表示用）。フック受信時に一度だけ解決する。
    var terminalName: String?

    var id: String {
        if pid > 0 { return "\(profile.id):pid:\(pid)" }
        return "\(profile.id):hook:\(hookSessionID ?? "unknown")"
    }

    /// "ttys004" のような短い表示名
    var shortName: String {
        if tty.isEmpty { return "バックグラウンド" }
        return tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
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
        folderName ?? shortName
    }

    init(agent: DiscoveredAgent) {
        self.tty = agent.tty
        self.profile = agent.profile
        self.pid = agent.pid
    }

    init(hookSource: String, sessionID: String, pid: Int32?, tty: String?, cwd: String?) {
        self.tty = tty ?? ""
        self.profile = CLIProfile.builtins.first { $0.id == hookSource } ?? .codex
        self.pid = pid ?? 0
        self.hookSessionID = sessionID
        self.projectName = cwd.map { ($0 as NSString).lastPathComponent }
        self.workingDirectory = cwd
    }
}
