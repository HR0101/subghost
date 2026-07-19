//
//  StateDetector.swift
//  Subghost
//
//  設計書 5. 状態判定ロジック詳細
//  capture-paneのテキストから idle/thinking/completed/error を判定する純粋ロジック。
//

import Foundation

/// 1回のポーリング結果として検出されたイベント
nonisolated enum DetectorEvent: Equatable, Sendable {
    case none
    case becameThinking
    case becameCompleted(preview: [String])   // 完了＋チラ見せ用テキスト
    case becameError(preview: [String])
    case becameIdle
    case becameAwaitingChoice(PendingChoice)  // 承認/質問の選択待ち
    case choiceResolved                       // 選択待ちが解消（回答済み）
}

/// セッション1つ分の状態機械。ポーリングごとに `ingest` を呼ぶ。
nonisolated struct StateDetector: Sendable {
    let profile: CLIProfile

    /// 変化停止から completed 判定までの秒数 (設計書 4.1: 例 1.5秒)
    var stableInterval: TimeInterval = 1.5
    /// completed から idle へ自動遷移するまでの秒数 (設計書 5.2)
    var completedHoldInterval: TimeInterval = 8.0
    /// thinking固着の保険: プロンプト記号が検出できないCLIでも、この秒数静止したら idle へ戻す
    var idleFallbackInterval: TimeInterval = 30.0
    /// 回答直後に同じ選択肢が画面に残っている間、再通知を抑制する秒数
    var answeredSuppressionInterval: TimeInterval = 4.0

    private(set) var state: AIState = .idle
    /// 現在表示中の選択待ちブロック（承認/質問）
    private(set) var pendingChoice: PendingChoice?
    private var lastCleanedText: String = ""
    private var lastChangeAt: Date?
    private var completedAt: Date?
    private var hasBaseline = false
    /// ノッチから回答済みの選択肢（残像による再通知を抑制するために保持）
    private var answeredChoice: PendingChoice?
    private var answeredAt: Date?

    init(profile: CLIProfile) {
        self.profile = profile
    }

    /// capture-paneの生テキストを取り込み、状態遷移イベントを返す。
    mutating func ingest(rawText: String, at now: Date) -> DetectorEvent {
        let cleaned = Self.clean(rawText, profile: profile)

        // 初回は基準値として保存するだけ（起動時に thinking と誤判定しない）
        guard hasBaseline else {
            hasBaseline = true
            lastCleanedText = cleaned
            lastChangeAt = now
            return .none
        }

        let changed = cleaned != lastCleanedText
        if changed {
            lastCleanedText = cleaned
            lastChangeAt = now
        }

        // 選択待ち（承認/質問）は他のどの判定よりも優先する。
        // ユーザーが答えるまでCLIは進まないため、completedと誤判定してはならない。
        if let choice = ChoicePrompt.detect(in: rawText, profile: profile) {
            // 回答直後は同じ選択肢が画面に残ることがあるため、一定時間は再通知しない
            if let answered = answeredChoice, answered == choice,
               let answeredAt, now.timeIntervalSince(answeredAt) < answeredSuppressionInterval {
                return .none
            }
            guard pendingChoice != choice else { return .none }   // 同じ問いを表示し続けている
            pendingChoice = choice
            answeredChoice = nil
            completedAt = nil
            state = choice.kind == .approval ? .awaitingApproval : .awaitingAnswer
            return .becameAwaitingChoice(choice)
        }

        answeredChoice = nil
        if pendingChoice != nil {
            // 選択肢が消えた＝ターミナル側で回答済み。処理再開とみなす。
            pendingChoice = nil
            state = .thinking
            lastChangeAt = now
            return .choiceResolved
        }

        switch state {
        case .idle, .error, .completed, .awaitingApproval, .awaitingAnswer:
            // 出力が伸長 → thinking (設計書 5.2)
            if changed {
                state = .thinking
                completedAt = nil
                return .becameThinking
            }
            // completed → 一定時間経過で idle
            if state == .completed, let doneAt = completedAt,
               now.timeIntervalSince(doneAt) >= completedHoldInterval {
                state = .idle
                completedAt = nil
                return .becameIdle
            }
            return .none

        case .thinking:
            // エラーパターン検出 → error
            if Self.matches(pattern: profile.errorPattern, in: cleaned) {
                state = .error
                return .becameError(preview: Self.extractPreview(from: rawText, profile: profile))
            }
            // busy表示が残っている間は thinking を維持
            if Self.matches(pattern: profile.busyPattern, in: cleaned) {
                return .none
            }
            // N秒変化なし＋プロンプト記号 → completed
            if !changed,
               let lastChange = lastChangeAt,
               now.timeIntervalSince(lastChange) >= stableInterval,
               Self.matches(pattern: profile.promptPattern, in: Self.tail(of: cleaned, lines: 12)) {
                state = .completed
                completedAt = now
                return .becameCompleted(preview: Self.extractPreview(from: rawText, profile: profile))
            }
            // プロンプト記号が検出できないCLI向けの保険: 長時間静止で idle へ戻す
            if !changed,
               let lastChange = lastChangeAt,
               now.timeIntervalSince(lastChange) >= idleFallbackInterval {
                state = .idle
                completedAt = nil
                return .becameIdle
            }
            return .none
        }
    }

    /// プロンプト送信直後に呼ぶ (設計書 5.2: completed → 新規プロンプト送信 → thinking)
    mutating func noteUserSentPrompt(at now: Date) -> DetectorEvent {
        completedAt = nil
        lastChangeAt = now
        guard state != .thinking else { return .none }
        state = .thinking
        return .becameThinking
    }

    /// ノッチから選択肢へ回答した直後に呼ぶ。
    /// 画面が更新されるまでの間、同じ問いを再通知しないよう記録する。
    mutating func noteUserAnsweredChoice(at now: Date) -> DetectorEvent {
        guard let answered = pendingChoice else { return .none }
        answeredChoice = answered
        answeredAt = now
        pendingChoice = nil
        completedAt = nil
        lastChangeAt = now
        state = .thinking
        return .becameThinking
    }

    /// ユーザーが通知を確認した時に呼ぶ (completed → idle)
    mutating func acknowledgeCompletion() {
        guard state == .completed else { return }
        state = .idle
        completedAt = nil
    }

    // MARK: - テキスト処理 (設計書 5.3)

    /// スピナー・制御文字を除去し、比較用に正規化する
    static func clean(_ text: String, profile: CLIProfile) -> String {
        var result = text
        // 残存ANSIエスケープの除去（capture-pane -p でも念のため）
        result = result.replacingOccurrences(
            of: #"\x{1B}\[[0-9;?]*[a-zA-Z]"#, with: "", options: .regularExpression)
        // プロファイル定義のスピナー除去
        if !profile.spinnerPattern.isEmpty {
            result = result.replacingOccurrences(
                of: profile.spinnerPattern, with: "", options: .regularExpression)
        }
        // 経過秒数など時々刻々変わる表示を無視（例: "(12s"、"3.2s)"）
        result = result.replacingOccurrences(
            of: #"\(?\d+(\.\d+)?s\)?"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\d+(\.\d+)?k? tokens"#, with: "", options: .regularExpression)
        // 各行の末尾空白を落とし、末尾の空行を除去
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed.joined(separator: "\n")
    }

    static func matches(pattern: String, in text: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func tail(of text: String, lines count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// 最終応答のチラ見せ用テキストを抽出する (設計書 4.2)
    /// 入力ボックス/プロンプト行より上の、直近の本文ブロックを最大4行返す。
    static func extractPreview(from rawText: String, profile: CLIProfile, maxLines: Int = 4) -> [String] {
        let boxChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤┬┴┼═║╔╗╚╝▔▁")
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // 枠線・スピナーを除去
                var s = String(line)
                if !profile.spinnerPattern.isEmpty {
                    s = s.replacingOccurrences(of: profile.spinnerPattern, with: "", options: .regularExpression)
                }
                s = String(s.unicodeScalars.filter { !boxChars.contains($0) })
                return s.trimmingCharacters(in: .whitespaces)
            }

        // 末尾から遡り、プロンプト行・ステータス行・空行をスキップして本文ブロックを集める
        var collected: [String] = []
        var inBody = false
        for line in lines.reversed() {
            let isNoise = line.isEmpty
                || matches(pattern: profile.promptPattern, in: line)
                || matches(pattern: profile.busyPattern, in: line)
                || matches(pattern: #"(?i)^\?? ?(for shortcuts|shift\+tab|tab to|auto-accept|bypass|plan mode|context left|tokens|/help|esc to)"#, in: line)
            if !inBody {
                if isNoise { continue }
                inBody = true
                collected.append(line)
            } else {
                if line.isEmpty { break }   // 本文ブロックの境界
                if isNoise { continue }
                collected.append(line)
                if collected.count >= 12 { break }  // 遡りすぎ防止
            }
        }
        // collected は逆順（下→上）なので戻し、先頭からmaxLines行 (設計書 4.2: 冒頭3〜4行)
        return Array(collected.reversed().prefix(maxLines))
    }
}
