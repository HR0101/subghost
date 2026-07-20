//
//  ChoicePrompt.swift
//  Subghost
//
//  設計書 追補: Approve（権限リクエストの承認/拒否）/ Ask（質問への回答）
//  capture-paneのテキストから「ユーザーの選択待ち」ブロックを抽出する純粋ロジック。
//  ここでは検出のみを行い、キー送信は TmuxClient が担う。
//

import Foundation

// MARK: - 種別

/// ノッチから応答できる問い合わせの種類
nonisolated enum ChoiceKind: String, Codable, Sendable {
    case approval   // 権限リクエスト（承認/拒否）
    case question   // エージェントからの質問

    var displayName: String {
        switch self {
        case .approval: return "承認リクエスト"
        case .question: return "質問"
        }
    }
}

// MARK: - 選択肢

nonisolated struct ChoiceOption: Sendable, Equatable, Hashable, Identifiable {
    /// 1始まりの選択肢番号。y/n形式など番号のない問いでは 0。
    let number: Int
    let label: String
    /// tmuxへリテラル送信するキー（"1" や "y"）
    let keystroke: String
    /// キー送信後にEnterが必要か（番号選択メニューは即時確定のため不要）
    let needsEnter: Bool

    var id: String { "\(number)-\(keystroke)" }

    /// 「はい」系の選択肢か（通知アクションの割り当てに使う）
    var isAffirmative: Bool {
        ChoicePrompt.matches(pattern: #"(?i)^(y\b|yes\b|allow\b|approve\b|accept\b|ok\b|はい|承認|許可)"#, in: label)
    }

    /// 「いいえ」系の選択肢か
    var isNegative: Bool {
        ChoicePrompt.matches(pattern: #"(?i)^(n\b|no\b|deny\b|reject\b|cancel\b|decline\b|いいえ|拒否|却下)"#, in: label)
    }
}

// MARK: - 問い合わせ

nonisolated struct PendingChoice: Sendable, Equatable, Hashable {
    let kind: ChoiceKind
    /// 問いかけ本文（"Do you want to make this edit to foo.swift?" 等）
    let title: String
    /// 問いかけの直前にある文脈行（差分の要約など）を最大3行
    let detail: [String]
    let options: [ChoiceOption]
    /// 複数の選択肢を同時に選べる問いか（AskUserQuestion の multiSelect）
    let isMultiSelect: Bool
    /// 一度に出された問いのうち何問目か（1始まり）
    let questionIndex: Int
    /// 一度に出された問いの総数
    let questionCount: Int

    /// 既定値付きの初期化子。
    /// 承認リクエストや y/n 形式は単一選択の1問目なので、後ろ3つは省略できる。
    init(
        kind: ChoiceKind,
        title: String,
        detail: [String],
        options: [ChoiceOption],
        isMultiSelect: Bool = false,
        questionIndex: Int = 1,
        questionCount: Int = 1
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.options = options
        self.isMultiSelect = isMultiSelect
        self.questionIndex = questionIndex
        self.questionCount = questionCount
    }

    /// 「はい」に相当する選択肢（通知の承認アクション用）
    var affirmativeOption: ChoiceOption? { options.first { $0.isAffirmative } }
    /// 「いいえ」に相当する選択肢（通知の拒否アクション用）
    var negativeOption: ChoiceOption? { options.first { $0.isNegative } }

    /// 複数問あるときだけ「2 / 3」のような進捗表示を返す
    var progressLabel: String? {
        questionCount > 1 ? "\(questionIndex) / \(questionCount)" : nil
    }
}

// MARK: - 抽出ロジック

nonisolated enum ChoicePrompt {

    /// 走査対象とする末尾行数。画面下部の生きたプロンプトだけを見る。
    static let maxScanLines = 40
    /// 問いかけ本文を探して遡る最大行数
    private static let titleLookbackLines = 6
    /// y/n 形式のプロンプトが「生きている」とみなす末尾からの距離
    private static let yesNoTailLines = 5

    /// 選択肢行: "❯ 1. Yes" / "  2) No" / "▶ 3. …"
    private static let optionPattern = #"^(?:[❯>▶●•*]\s*)?(\d{1,2})[.)]\s+(\S.*)$"#
    /// y/n 形式: "Continue? (y/n)" / "上書きしますか [Y/n]:"
    private static let yesNoPattern = #"(?i)[\[(]\s*y(?:es)?\s*/\s*n(?:o)?\s*[\])]\s*[:?]?\s*$"#
    /// 選択肢ブロックの直上にあってもタイトルとみなさないノイズ行
    private static let noisePattern =
        #"(?i)^(\?? ?for shortcuts|shift\+tab|tab to|auto-accept|bypass|plan mode|context left|esc to|press |use (arrow|↑))"#

    /// 生のcapture-paneテキストから選択待ちブロックを検出する。
    /// 見つからなければ nil（＝ユーザー応答は不要）。
    static func detect(in rawText: String, profile: CLIProfile) -> PendingChoice? {
        let lines = Array(normalizedLines(from: rawText).suffix(maxScanLines))
        guard !lines.isEmpty else { return nil }

        if let numbered = detectNumbered(in: lines, profile: profile) { return numbered }
        return detectYesNo(in: lines, profile: profile)
    }

    // MARK: - 番号付きメニュー

    private static func detectNumbered(in lines: [String], profile: CLIProfile) -> PendingChoice? {
        // 選択肢ブロックの下にヒント行が続くことがあるため、最後の選択肢行を起点に上へ遡る
        guard let lastIndex = lines.lastIndex(where: { parseOption($0) != nil }) else { return nil }

        var collected: [ChoiceOption] = []
        var index = lastIndex
        while index >= 0, let parsed = parseOption(lines[index]) {
            // 上へ遡るので番号は 1 ずつ減っていくはず。飛んでいたら別ブロック。
            if let head = collected.first, parsed.number != head.number - 1 { break }
            collected.insert(parsed, at: 0)
            index -= 1
        }

        // 1から始まる2つ以上の連番のみを選択メニューとみなす（誤検出防止）
        guard collected.count >= 2, collected.first?.number == 1 else { return nil }

        let (title, detail) = extractTitle(above: index, in: lines)
        guard !title.isEmpty else { return nil }

        return PendingChoice(
            kind: classify(title: title, detail: detail, profile: profile),
            title: title,
            detail: detail,
            options: collected
        )
    }

    /// "❯ 1. Yes" 形式の1行を選択肢へ変換する
    private static func parseOption(_ line: String) -> ChoiceOption? {
        guard let range = line.range(of: optionPattern, options: .regularExpression) else { return nil }
        guard range.lowerBound == line.startIndex else { return nil }

        // 正規表現のキャプチャを取り出す（NSRegularExpressionで番号とラベルを分離）
        guard let regex = try? NSRegularExpression(pattern: optionPattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 3,
              let numberRange = Range(match.range(at: 1), in: line),
              let labelRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange]),
              number >= 1, number <= 20
        else { return nil }

        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        return ChoiceOption(
            number: number,
            label: label,
            keystroke: String(number),
            needsEnter: false   // 番号キーで即確定するTUIを前提とする
        )
    }

    // MARK: - y/n 形式

    private static func detectYesNo(in lines: [String], profile: CLIProfile) -> PendingChoice? {
        let tail = lines.suffix(yesNoTailLines)
        guard let title = tail.last(where: { matches(pattern: yesNoPattern, in: $0) }) else { return nil }

        let options = [
            ChoiceOption(number: 1, label: "Yes", keystroke: "y", needsEnter: true),
            ChoiceOption(number: 2, label: "No", keystroke: "n", needsEnter: true),
        ]
        return PendingChoice(
            kind: classify(title: title, detail: [], profile: profile),
            title: title,
            detail: [],
            options: options
        )
    }

    // MARK: - 補助

    /// 選択肢ブロックの直上から問いかけ本文と文脈行を取り出す
    private static func extractTitle(above blockTop: Int, in lines: [String]) -> (String, [String]) {
        var title = ""
        var titleIndex = blockTop

        var cursor = blockTop
        let limit = max(0, blockTop - titleLookbackLines)
        while cursor >= limit {
            let line = lines[cursor]
            if !line.isEmpty, !matches(pattern: noisePattern, in: line) {
                title = line
                titleIndex = cursor
                break
            }
            cursor -= 1
        }
        guard !title.isEmpty else { return ("", []) }

        // 問いかけの上にある文脈行を最大3行（空行に当たったら打ち切り）
        var detail: [String] = []
        var above = titleIndex - 1
        while above >= 0, detail.count < 3 {
            let line = lines[above]
            if line.isEmpty { break }
            if !matches(pattern: noisePattern, in: line) { detail.insert(line, at: 0) }
            above -= 1
        }
        return (title, detail)
    }

    /// 問いかけ文から「承認リクエスト」か「質問」かを判定する
    private static func classify(title: String, detail: [String], profile: CLIProfile) -> ChoiceKind {
        let haystack = ([title] + detail).joined(separator: "\n")
        return matches(pattern: profile.approvalPattern, in: haystack) ? .approval : .question
    }

    /// 枠線・スピナー・ANSIを落として1行ずつに正規化する
    static func normalizedLines(from rawText: String) -> [String] {
        let boxCharacters = Set("╭╮╰╯│─┌┐└┘├┤┬┴┼═║╔╗╚╝▔▁▌▐█ \t")
        let withoutANSI = rawText.replacingOccurrences(
            of: #"\x{1B}\[[0-9;?]*[a-zA-Z]"#, with: "", options: .regularExpression)

        return withoutANSI
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var slice = Substring(line)
                while let first = slice.first, boxCharacters.contains(first) { slice = slice.dropFirst() }
                while let last = slice.last, boxCharacters.contains(last) { slice = slice.dropLast() }
                return String(slice).trimmingCharacters(in: .whitespaces)
            }
    }

    static func matches(pattern: String, in text: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
