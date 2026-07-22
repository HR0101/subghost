//
//  TmuxClient.swift
//  Subghost
//
//  設計書 3.2 橋渡し方式：tmux
//  設計書 9. セキュリティ：Processで引数配列を使い、シェル文字列連結をしない
//
//  tmux コマンドの実行を包む薄い層。画面内容の取り出し(capture-pane)と、
//  CLIへの文字・キー送信(send-keys)という2つの用途がある。
//
//  引数は必ず配列で渡し、シェルを経由しない。ユーザーの入力がそのまま
//  tmuxへ届く経路なので、文字列連結でコマンドを組み立てると命令を混ぜ込まれる。
//

import Foundation

nonisolated struct TmuxResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

nonisolated enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case launchFailed(String)
    /// 確定ボタンの位置を画面から確認できなかった（フェールセーフ: 当て推量では送らない）
    case cannotVerifyMenuPosition
    /// 送信後も選択待ちが解消していない（フェールソフト: 成功と偽って表示しない）
    case choiceNotResolvedAfterSend

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux が見つかりません。Homebrew等でインストールしてください。"
        case .launchFailed(let message):
            return "tmux の実行に失敗しました: \(message)"
        case .cannotVerifyMenuPosition:
            return "確定ボタンの位置を画面から確認できませんでした。誤操作を避けるため送信を中止しました。"
                + "ターミナルで直接お選びください。"
        case .choiceNotResolvedAfterSend:
            return "送信しましたが、選択待ちがまだ解消していません。ターミナルでご確認ください。"
        }
    }
}

/// tmux CLIの薄いラッパー。すべて引数配列で実行する。
nonisolated enum TmuxClient {

    /// GUIアプリはPATHが最小構成のため、tmuxの実体パスを候補から解決する。
    static func resolveTmuxPath() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "tmuxPath"),
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// tmuxを引数配列で実行し、終了を待って結果を返す（メインスレッドはブロックしない）。
    static func run(_ arguments: [String]) async throws -> TmuxResult {
        guard let tmuxPath = resolveTmuxPath() else { throw TmuxError.tmuxNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: TmuxResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: TmuxError.launchFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - 高レベルAPI

    /// 全ペインを列挙し、pty → ペイン宛先（"session:0.1"）の対応表を返す。
    /// これによりセッション名の命名規則に依存せずtmux内のプロセスを紐づけられる。
    static func paneTargetsByTTY() async -> [String: String] {
        guard let result = try? await run([
            "list-panes", "-a", "-F", "#{pane_tty}|#{session_name}:#{window_index}.#{pane_index}",
        ]), result.succeeded else { return [:] }
        return parsePaneTargets(result.stdout)
    }

    /// list-panesの出力を解析する（テスト対象の純粋ロジック）
    static func parsePaneTargets(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty, !target.isEmpty else { continue }
            map[tty] = target
        }
        return map
    }

    /// 全ペインを列挙し、pty → 最後に出力があった時刻の対応表を返す。
    ///
    /// tmux自身が記録している時刻なので、Subghostを再起動しても失われない。
    /// 「もう使っていないセッション」を一覧から外す判断に使う。
    /// (Subghost側の `lastActivityAt` はフック受信時にしか動かず、tmux経路の
    ///  セッションでは起動時刻のまま止まってしまうため、こちらを併用する)
    static func activityByTTY() async -> [String: Date] {
        guard let result = try? await run([
            "list-panes", "-a", "-F", "#{pane_tty}|#{window_activity}",
        ]), result.succeeded else { return [:] }
        return parsePaneActivity(result.stdout)
    }

    /// list-panesの活動時刻出力を解析する（テスト対象の純粋ロジック）
    nonisolated static func parsePaneActivity(_ output: String) -> [String: Date] {
        var map: [String: Date] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            // tmuxはUNIX秒で返す。解釈できない値は「不明」として捨てる（0を時刻とみなさない）
            guard !tty.isEmpty,
                  let seconds = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)),
                  seconds > 0
            else { continue }
            map[tty] = Date(timeIntervalSince1970: seconds)
        }
        return map
    }

    /// セッションにアタッチしているクライアントのtty（例 "/dev/ttys004"）を返す。
    /// どのターミナルのどのタブで動いているかを特定するために使う (Jump)。
    /// デタッチ中のセッションでは nil。
    static func clientTTY(session: String) async -> String? {
        guard let result = try? await run(["list-clients", "-t", session, "-F", "#{client_tty}"]),
              result.succeeded else { return nil }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// `tmux capture-pane -p` でペインのプレーンテキストを取得する (設計書 5.1)
    static func capturePane(target: String) async -> String? {
        guard let result = try? await run(["capture-pane", "-p", "-J", "-t", target]),
              result.succeeded else { return nil }
        return result.stdout
    }

    /// `tmux send-keys` でプロンプトを送信する (設計書 4.3)
    /// テキストは `-l`（リテラル）で送り、Enterは別コマンドで送る。
    static func sendPrompt(_ text: String, to target: String) async throws {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return }

        let sendText = try await run(["send-keys", "-t", target, "-l", "--", sanitized])
        guard sendText.succeeded else {
            throw TmuxError.launchFailed(sendText.stderr.isEmpty ? "send-keys failed" : sendText.stderr)
        }
        // TUIがペーストを処理してからEnterを送る
        try? await Task.sleep(for: .milliseconds(120))
        let sendEnter = try await run(["send-keys", "-t", target, "Enter"])
        guard sendEnter.succeeded else {
            throw TmuxError.launchFailed(sendEnter.stderr.isEmpty ? "send-keys Enter failed" : sendEnter.stderr)
        }
    }

    /// キー送信のあいだにTUIが描画を追いつかせるための間隔
    private static let keyInterval = Duration.milliseconds(120)

    /// 選択肢への回答キーを送信する（Approve / Ask）。
    ///
    /// needsEnter で経路が分かれる:
    /// - false: 画面解析で検出した番号メニュー（"❯ 1. Yes" 等、Submit行を持たない）。
    ///   番号キーだけで即確定する構造を前提とし、Enterは送らない。
    /// - true: AskUserQuestion由来の単一選択（タブ形式のUI）。
    ///   番号キーを送った直後に画面を確認し、まだ同じ問いの選択肢が残っていれば
    ///   Submit/Next行への到達とEnterで確定する。
    ///   (実機で確認した不具合: 複数問構成では、単一選択は番号キーを押した時点で
    ///   選択が確定し自動的に次の質問(タブ)へ画面が切り替わることがある。それに
    ///   気づかず一律でSubmit/Next移動のキーを送っていたため、既に切り替わった
    ///   次の質問の画面に対して誤った位置でEnterを押し、無回答のまま送信していた)
    ///
    /// - Parameter allOptionLabels: この問い全体の選択肢ラベル（選んだものだけでなく全て）。
    ///   選んだラベル1つだけで画面を照合すると、次の質問の画面に偶然同じ文字列
    ///   （選択済みの回答サマリー等）が含まれていた場合に「まだ同じ問いの画面」と
    ///   誤判定しうる。全ラベルが必要な分だけ、次の質問への遷移をより確実に検知できる
    ///   (実機で確認した不具合: ラベル1つだけの判定では、切り替わった次の質問の
    ///   画面を誤って「同じ画面のまま」と判定し、無関係な位置へキーを送っていた)。
    static func sendChoice(
        _ option: ChoiceOption,
        allOptionLabels: [String],
        totalOptionCount: Int,
        to target: String
    ) async throws {
        let key = sanitize(option.keystroke)
        guard !key.isEmpty else { return }
        try await sendLiteral(key, to: target)

        guard option.needsEnter else { return }
        try? await Task.sleep(for: keyInterval)

        // まだ同じ問いの選択肢が画面に残っているかを確認する。既に消えていれば
        // 番号キーだけで確定・画面遷移済みとみなし、それ以上の操作はしない。
        guard let paneText = await capturePane(target: target),
              ChoicePrompt.matchesCurrentScreen(optionLabels: allOptionLabels, in: paneText)
        else { return }

        try await confirmSelection(to: target)
    }

    /// 画面キャプチャの読み直しを試みる回数。1回失敗しただけの一時的な取りこぼしを拾うため。
    private static let paneReadRetries = 2

    /// 複数選択の回答を送信する。
    ///
    /// 複数選択UIでは番号キーが「選択のトグル」で、Enterは「カーソル行の選択」を意味する。
    /// 確定は一覧の末尾にある `Submit`/`Next` 行へカーソルを下ろしてEnterを押す操作なので、
    /// 番号を送ったあとに画面を読み、そこまでの距離だけ↓を送ってから確定する。
    ///
    /// フェールセーフ: Submit/Next行の位置は必ず画面から確認する。読めない場合は
    /// 当て推量で↓の回数を決めず、送信を中止する（実機で確認した不具合の再発防止:
    /// 推測値が実際とズレ、自由記述欄やレビュー画面のCancelを誤って踏んだことがあった）。
    ///
    /// - Parameters:
    ///   - options: チェックを入れる（選んだ）選択肢。トグルするキーの対象。
    ///   - totalOptionCount: この問いの選択肢の総数（自由記述欄を除く）。参考情報として保持するのみで、
    ///     ↓の回数の当て推量には使わない（選んだ数と総数を混同しないこと自体は変わらず重要）。
    static func sendChoices(
        _ options: [ChoiceOption],
        totalOptionCount: Int,
        to target: String
    ) async throws {
        let keys = options.map { sanitize($0.keystroke) }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return }

        // 番号キーは選択のトグル。カーソルの位置は動かない。
        for key in keys {
            try await sendLiteral(key, to: target)
            // 連続して送るとトグルを取りこぼすため、1つずつ間を空ける
            try? await Task.sleep(for: keyInterval)
        }

        try await confirmSelection(to: target)
    }

    /// 選択肢を選び終えた後、Submit/Next行まで移動してEnterで確定する共通処理。
    /// 単一選択(sendChoice)・複数選択(sendChoices)の両方から使う。
    private static func confirmSelection(to target: String) async throws {
        // Submit/Next行までの距離は必ず画面から確認する。一時的な取りこぼしに備えて
        // 数回だけ読み直すが、それでも読めなければ当て推量で↓を送らず中止する。
        var steps: Int?
        for _ in 0..<paneReadRetries {
            if let paneText = await capturePane(target: target),
               let found = stepsToSubmit(inPaneText: paneText) {
                steps = found
                break
            }
            try? await Task.sleep(for: keyInterval)
        }
        guard let steps else { throw TmuxError.cannotVerifyMenuPosition }

        for _ in 0..<steps {
            try await sendKey("Down", to: target)
            try? await Task.sleep(for: keyInterval)
        }
        // Submit行はEnterで確定する。ただし最後の問いの場合、これは即送信ではなく
        // 「Review your answers」という確認画面を開くだけの操作になる（実機で確認した挙動）。
        // Next行（中間の問い）はこの確認画面を経由せず、そのまま次のタブへ進む。
        try await sendEnter(to: target)

        // 確認画面が開いていれば、そこでもう一段 "1"（1. Submit answers）を送って確定する。
        try? await Task.sleep(for: keyInterval)
        if let confirmText = await capturePane(target: target), isReviewScreen(confirmText) {
            try await sendLiteral("1", to: target)
            try? await Task.sleep(for: keyInterval)
        }

        // フェールソフト: 送信後もなお同じ選択メニューが画面に残っていれば、
        // 「送信しました」と偽らずエラーとして報告し、手動対応へ導く。
        if let afterText = await capturePane(target: target),
           stepsToSubmit(inPaneText: afterText) != nil {
            throw TmuxError.choiceNotResolvedAfterSend
        }
    }

    /// 文字列をリテラル（`-l`）として送る
    private static func sendLiteral(_ text: String, to target: String) async throws {
        let result = try await run(["send-keys", "-t", target, "-l", "--", text])
        guard result.succeeded else {
            throw TmuxError.launchFailed(result.stderr.isEmpty ? "send-keys failed" : result.stderr)
        }
    }

    /// Enterキーを送る
    private static func sendEnter(to target: String) async throws {
        try await sendKey("Enter", to: target)
    }

    /// 名前付きのキー（Enter / Down など）を送る
    private static func sendKey(_ name: String, to target: String) async throws {
        let result = try await run(["send-keys", "-t", target, name])
        guard result.succeeded else {
            throw TmuxError.launchFailed(
                result.stderr.isEmpty ? "send-keys \(name) failed" : result.stderr)
        }
    }

    // MARK: - 確定ボタンの位置（テスト対象の純粋ロジック）

    /// カーソル行の目印
    private static let cursorMarker = "❯"
    /// 確定ボタンの表示。
    /// 複数の問いが1画面にタブでまとまっている場合、最後の問いだけ "Submit"、
    /// それ以外は次のタブへ進む "Next" と表示される。どちらも「↓とEnterで進む」操作は同じ。
    private static let submitLabels: Set<String> = ["Submit", "Next"]
    /// 選択肢行の書式: "1. [ ] ラベル"
    private static let numberedLinePattern = #"^\d{1,2}\.\s"#

    /// 画面テキストから、カーソル位置からSubmitまでに必要な↓の回数を求める。
    ///
    /// 選択肢の下には説明文が挟まるが、↓は説明文を飛ばして選択肢単位で動く。
    /// そのため行数ではなく「移動できる行」の数を数える。
    /// 見つからなければ nil（呼び出し側で推定値を使う）。
    nonisolated static func stepsToSubmit(inPaneText text: String) -> Int? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 画面上部の会話にも "❯" が現れうるため、一番下の出現をカーソルとみなす
        guard let cursorLine = lines.lastIndex(where: { $0.contains(cursorMarker) }) else { return nil }

        var steps = 0
        for line in lines[(cursorLine + 1)...] {
            if isSubmitLine(line) { return steps + 1 }
            if isOptionLine(line) { steps += 1 }
        }
        return nil
    }

    /// 確定ボタンだけの行か（上部のタブ表示と区別する）
    private static func isSubmitLine(_ line: String) -> Bool {
        submitLabels.contains(stripped(line))
    }

    /// 最終問のSubmitを押した後に出る「Review your answers」確認画面の目印。
    /// この画面には "1. Submit answers" という、選択肢とは別番号体系の確定行がある。
    private static let reviewScreenMarker = "Submit answers"

    /// 確認画面（もう一段の確定が要る画面）が開いているか
    nonisolated static func isReviewScreen(_ paneText: String) -> Bool {
        paneText.contains(reviewScreenMarker)
    }

    /// 番号付きの選択肢行か
    private static func isOptionLine(_ line: String) -> Bool {
        stripped(line).range(of: numberedLinePattern, options: .regularExpression) != nil
    }

    /// カーソル記号と前後の空白を落とす
    private static func stripped(_ line: String) -> String {
        line.replacingOccurrences(of: cursorMarker, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// send-keysに渡す前に制御文字を除去する (設計書 9)
    static func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let cleaned = normalized.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }
        return String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
