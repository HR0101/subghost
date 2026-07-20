//
//  TmuxClient.swift
//  Subghost
//
//  設計書 3.2 橋渡し方式：tmux
//  設計書 9. セキュリティ：Processで引数配列を使い、シェル文字列連結をしない
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

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux が見つかりません。Homebrew等でインストールしてください。"
        case .launchFailed(let message):
            return "tmux の実行に失敗しました: \(message)"
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

    /// 選択肢への回答キーを送信する（Approve / Ask）
    /// 番号選択メニューは番号キーだけで確定するため、Enterは needsEnter のときのみ送る。
    static func sendChoice(_ option: ChoiceOption, to target: String) async throws {
        let key = sanitize(option.keystroke)
        guard !key.isEmpty else { return }

        try await sendLiteral(key, to: target)
        guard option.needsEnter else { return }

        // TUIがキー入力を処理してからEnterを送る
        try? await Task.sleep(for: keyInterval)
        try await sendEnter(to: target)
    }

    /// 複数選択の回答を送信する。
    ///
    /// 複数選択UIでは番号キーが「選択のトグル」で、Enterは「カーソル行の選択」を意味する。
    /// 確定は一覧の末尾にある `Submit`/`Next` 行へカーソルを下ろしてEnterを押す操作なので、
    /// 番号を送ったあとに画面を読み、そこまでの距離だけ↓を送ってから確定する。
    ///
    /// - Parameters:
    ///   - options: チェックを入れる（選んだ）選択肢。トグルするキーの対象。
    ///   - totalOptionCount: この問いの選択肢の総数（自由記述欄を除く）。
    ///     画面が読めなかったときの推定値に使うため、選んだ数と混同しないこと。
    ///     選んだ数（options.count）を使うと、末尾の選択肢を選ばなかった場合に
    ///     Submit/Nextの手前で止まり、後続のキー入力が自由記述欄に誤入力される。
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

        // 画面を読めない場合に備えた推定値。
        // カーソルは先頭の選択肢にある。末尾の選択肢まで (総数-1) 回、
        // 自由記述欄まで+1回、Submit/Nextまでさらに+1回で「総数+1」回。
        let fallback = totalOptionCount + 1
        let paneText = await capturePane(target: target)
        let steps = paneText.flatMap { stepsToSubmit(inPaneText: $0) } ?? fallback

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
