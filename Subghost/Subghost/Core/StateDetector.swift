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
    /// 完了を知らせた直後、作業中の裏付け（busy表示）が無いまま再び静止した場合に
    /// 改めて完了と判定するまでの秒数。
    ///
    /// 完了後の画面はステータス行の更新やヒント行の差し替えだけでも「変化」するため、
    /// `changed` を根拠に thinking へ戻ってしまう。それを通常と同じ 1.5 秒で
    /// completed に戻すと、1回の応答に対して通知が何度も出る。
    var redrawStableInterval: TimeInterval = 12.0

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
    /// 直前に「完了」として知らせた本文。同じ応答を二度知らせないための控え。
    private var announcedPreview: [String]?
    /// 現在の thinking が、完了直後の画面の再描画だけで始まったものか。
    /// true の間は作業していた裏付けが無いため、完了判定を急がない。
    private var isRedrawAfterCompletion = false
    /// 起動直後の初回判定で選択肢を見つけたが、まだ確定させていない候補。
    /// (フールプルーフ: 起動直後はフックがまだ繋がっておらず、会話に残った過去の
    /// テキストを誤って選択メニューと検出するリスクが最も高い。1回見ただけでは
    /// 確定させず、次のポーリングでも同じ内容が見えて初めて「生きている」とみなす)
    private var candidateChoice: PendingChoice?

    init(profile: CLIProfile) {
        self.profile = profile
    }

    /// まだ一度も画面を取り込んでいない（起動時の状態推定が必要）か
    var needsInitialAdoption: Bool { !hasBaseline }

    /// Subghost起動時、すでに動いているCLIの「現在の状態」を画面から推定する。
    ///
    /// 通常の `ingest` は差分（画面が伸びた等）から状態を判断するため、
    /// 初回は基準値を置くだけで待機のままになる。それだと起動前から
    /// 承認待ちで止まっているセッションを取りこぼす。
    ///
    /// 完了は意図的に返さない。Subghost起動前に終わっていた応答について
    /// 「完了しました」と通知や音を出すのは、ユーザーにとって誤報だからである。
    mutating func adoptCurrentState(rawText: String, at now: Date) -> DetectorEvent {
        hasBaseline = true
        lastCleanedText = Self.clean(rawText, profile: profile)
        lastChangeAt = now

        // 応答待ちで止まっているものは、今も操作を必要としているので拾いたい。
        // ただし起動直後はフックがまだ繋がっておらず誤検出のリスクが最も高いタイミングなので、
        // ここでは即座に確定させず「次のポーリングでも同じなら確定する」候補として保持するに留める。
        // (実機で確認した不具合: 会話に残った番号付き箇条書きを選択待ちと誤検出していた)
        if let choice = ChoicePrompt.detect(in: rawText, profile: profile) {
            candidateChoice = choice
            return .none
        }

        // 実行中を示す表示が出ていれば生成中とみなす
        if Self.isCurrentlyBusy(rawText, profile: profile) {
            state = .thinking
            return .becameThinking
        }

        state = .idle
        return .none
    }

    /// capture-paneの生テキストを取り込み、状態遷移イベントを返す。
    mutating func ingest(rawText: String, at now: Date) -> DetectorEvent {
        let cleaned = Self.clean(rawText, profile: profile)
        // 作業中表示の判定には、経過時間やトークン数を残したテキストを使う（stripDecoration参照）
        let isBusy = Self.isCurrentlyBusy(rawText, profile: profile)

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

        let detected = ChoicePrompt.detect(in: rawText, profile: profile)

        // 起動直後の初回判定で見つけた候補が残っていれば、ここで様子見の結果を確認する。
        // 今回も同じ内容が見えていれば「生きている」と確定し、消えていれば一過性の
        // 誤検出だったとみなして破棄する（以降は detected を通常どおり使う）。
        if let candidate = candidateChoice {
            candidateChoice = nil
            if detected == candidate {
                pendingChoice = candidate
                completedAt = nil
                state = candidate.kind == .approval ? .awaitingApproval : .awaitingAnswer
                return .becameAwaitingChoice(candidate)
            }
        }

        // 選択待ち（承認/質問）は他のどの判定よりも優先する。
        // ユーザーが答えるまでCLIは進まないため、completedと誤判定してはならない。
        if let choice = detected {
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
            beginNewTurn()
            return .choiceResolved
        }

        switch state {
        case .idle, .error, .completed, .awaitingApproval, .awaitingAnswer:
            // 出力が伸長、または作業中表示が出ている → thinking (設計書 5.2)
            //
            // 変化が無くても busy を見るのは、経過時間だけが動く画面（ツール実行の待ち等）で
            // 一度 completed と誤判定してしまった場合に、自力で生成中へ戻れるようにするため。
            if changed || isBusy {
                // 完了直後に、作業中の裏付け（busy表示）が無いまま画面だけが変化した場合、
                // それは応答の再開ではなくステータス行やヒント行の再描画である可能性が高い。
                // 印を付けておき、下の完了判定で急がないようにする。
                // (実機で確認した不具合: 1回の応答に対して通知が何度も出ていた)
                isRedrawAfterCompletion = (state == .completed && !isBusy)
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
            // busy表示が残っている間は thinking を維持。
            // ここに来た＝実際に作業していた裏付けが取れたということなので、
            // 再描画由来の印は落として通常の完了判定へ戻す。
            if isBusy {
                isRedrawAfterCompletion = false
                return .none
            }
            // N秒変化なし＋プロンプト記号 → completed
            let requiredStableInterval = isRedrawAfterCompletion ? redrawStableInterval : stableInterval
            if !changed,
               let lastChange = lastChangeAt,
               now.timeIntervalSince(lastChange) >= requiredStableInterval,
               Self.matches(pattern: profile.promptPattern, in: Self.tail(of: cleaned, lines: 12)) {
                let preview = Self.extractPreview(from: rawText, profile: profile)
                isRedrawAfterCompletion = false
                // 直前に知らせたのと同じ本文なら、新しい応答ではなく同じ応答の再判定。
                // 状態は待機へ戻すだけにして、通知・音は出さない。
                guard preview != announcedPreview else {
                    state = .idle
                    completedAt = nil
                    return .becameIdle
                }
                announcedPreview = preview
                state = .completed
                completedAt = now
                return .becameCompleted(preview: preview)
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
        // ここから先は新しい応答。前回と同じ本文でも改めて知らせる。
        beginNewTurn()
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
        beginNewTurn()
        state = .thinking
        return .becameThinking
    }

    /// 新しい応答が始まるときの共通処理。
    /// 「同じ本文なら知らせない」抑制と、再描画由来の印を持ち越さない。
    private mutating func beginNewTurn() {
        announcedPreview = nil
        isRedrawAfterCompletion = false
    }

    /// ユーザーが通知を確認した時に呼ぶ (completed → idle)
    mutating func acknowledgeCompletion() {
        guard state == .completed else { return }
        state = .idle
        completedAt = nil
    }

    // MARK: - テキスト処理 (設計書 5.3)

    /// ANSIエスケープとスピナー装飾だけを落とす。
    ///
    /// `clean` と違い、経過秒数やトークン数は残す。実機のClaude Codeの作業中表示は
    /// `✢ Drizzling… (2m 35s · ↓ 10.5k tokens)` のように動詞がランダムに変わるため、
    /// 文言ではなく「…(経過時間" や "↓ トークン数" という形そのものが目印になる。
    /// これを `clean` で消したテキストに対して busyPattern を当てると拾えない。
    static func stripDecoration(_ text: String, profile: CLIProfile) -> String {
        // 残存ANSIエスケープの除去（capture-pane -p でも念のため）
        var result = text.replacingOccurrences(
            of: #"\x{1B}\[[0-9;?]*[a-zA-Z]"#, with: "", options: .regularExpression)
        // プロファイル定義のスピナー除去
        if !profile.spinnerPattern.isEmpty {
            result = result.replacingOccurrences(
                of: profile.spinnerPattern, with: "", options: .regularExpression)
        }
        return trimTrailing(result)
    }

    /// スピナー・制御文字を除去し、比較用に正規化する
    static func clean(_ text: String, profile: CLIProfile) -> String {
        var result = stripDecoration(text, profile: profile)
        // 経過秒数など時々刻々変わる表示を無視（例: "(12s"、"3.2s)"）
        result = result.replacingOccurrences(
            of: #"\(?\d+(\.\d+)?s\)?"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\d+(\.\d+)?k? tokens"#, with: "", options: .regularExpression)
        return trimTrailing(result)
    }

    /// 各行の末尾空白を落とし、末尾の空行を除去する
    private static func trimTrailing(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func matches(pattern: String, in text: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func tail(of text: String, lines count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// 現在のTUIステータス領域に作業中表示があるか。
    ///
    /// capture-pane全体には過去の応答やユーザーの依頼文が残るため、そこに
    /// "Working" / "Thinking" が含まれるだけで生成中と判定してはいけない。
    /// 入力欄と現在のステータスが置かれる末尾だけを対象にする。
    static func isCurrentlyBusy(_ rawText: String, profile: CLIProfile) -> Bool {
        let currentStatus = tail(
            of: stripDecoration(rawText, profile: profile),
            lines: 12
        )
        return matches(pattern: profile.busyPattern, in: currentStatus)
    }

    /// 本文ではなく、CLIが常設しているヒント・モード表示の行。
    /// 応答のチラ見せに混ぜると「途中の状態表示」が答えとして出てしまう。
    static let statusNoisePattern =
        #"(?i)^\?? ?(for shortcuts|shift\+tab|tab to|auto-accept|bypass|plan mode"#
        // 所要時間の行は完了後も残るが本文ではない。動詞はランダムなので形で弾く
        // （実機: "Worked for 6m 23s" / "Sautéed for 9s"）
        + #"|context left|tokens|/help|esc to|tip:)|^\S+ for \d|/effort\s*$"#

    /// 最終応答のチラ見せ用テキストを抽出する (設計書 4.2)
    /// 入力ボックス/プロンプト行より上の、直近の本文ブロックを最大4行返す。
    static func extractPreview(from rawText: String, profile: CLIProfile, maxLines: Int = 4) -> [String] {
        let boxChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤┬┴┼═║╔╗╚╝▔▁⎿◉")
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

        // 入力ボックスのプロンプト行より下（ステータスバー・モード表示等）は対象外にする
        let lastPromptIndex = lines.lastIndex {
            !$0.isEmpty && matches(pattern: profile.promptPattern, in: $0)
        }
        let searchLines = lastPromptIndex.map { Array(lines[..<$0]) } ?? lines

        // 末尾から遡り、プロンプト行・ステータス行・空行をスキップして本文ブロックを集める
        var collected: [String] = []
        var inBody = false
        for line in searchLines.reversed() {
            let isNoise = line.isEmpty
                || matches(pattern: profile.promptPattern, in: line)
                || matches(pattern: profile.busyPattern, in: line)
                || matches(pattern: statusNoisePattern, in: line)
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
