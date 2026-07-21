//
//  ShellIntegration.swift
//  Subghost
//
//  設計書 追補: AI CLIを自動的にtmux内で起動する
//
//  背景（他の画面を見ている間）からノッチで回答するにはtmuxが要る。
//  毎回 tmux と打たなくて済むよう、claude/codex/agy をシェル関数で包み、
//  対話起動のときだけ自動でtmuxセッション内に入れる。
//  agyy → agy、codexA/codexB → codex のような既存エイリアスも、
//  展開後に同じ関数を通るため、エイリアス側のオプションを保持できる。
//
//  安全設計:
//  - ~/.zshrc は書き換え前にバックアップする
//  - Subghostが追加した行は目印で囲み、解除時にその範囲だけを取り除く
//  - 包む処理は「Subghost未起動・非対話・tmux内・tmux未導入」のときは何もせず
//    素通しする（claude --version などが壊れない）。Subghostの起動判定は
//    監視ソケットの有無で行い、フック(subghost-bridge)と同じ基準に揃える。
//    これによりアプリを終了・削除しても claude 等の起動は元のまま壊れない。
//

import Foundation

nonisolated enum ShellIntegration {

    /// 包む対象のコマンド（実体名）。エイリアス名は上書きしない。
    static let wrappedCommands = ["claude", "codex", "agy"]

    /// zshrc に挿入するブロックの目印
    static let beginMarker = "# >>> subghost auto-tmux >>>"
    static let endMarker = "# <<< subghost auto-tmux <<<"

    static var scriptPath: String {
        HookInstaller.supportDirectory.appendingPathComponent("shell/auto-tmux.sh").path
    }

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    // MARK: - スクリプト本体

    /// 対象コマンドを包むシェル関数を生成する。
    /// - Parameter extraCommands: ユーザー登録のカスタムエイリアス名（実行ファイル名）。
    ///   ビルトインと重複するもの（大文字小文字を区別しない）は無視する。
    static func scriptBody(extraCommands: [String] = []) -> String {
        var seen = Set<String>()
        let allCommands = (wrappedCommands + extraCommands)
            .filter { seen.insert($0.lowercased()).inserted }
        let functions = allCommands.map { command in
            "\(command)() { _subghost_run \(command) \"$@\"; }"
        }.joined(separator: "\n")

        return """
        #!/bin/sh
        # Subghost: AI CLIを対話起動のときだけ自動でtmux内に入れる。
        # Subghostが動いていなければ（監視ソケットが無ければ）何もせず素通しするので、
        # アプリを終了・削除しても claude などの起動は元のまま壊れない。
        _subghost_sock="\(HookInstaller.socketPath)"
        _subghost_run() {
            _sg_cmd="$1"; shift
            # Subghost未起動 / 既にtmux内 / tmux未導入 / 非対話（パイプ等）はそのまま実行する
            if [ ! -S "$_subghost_sock" ] || [ -n "$TMUX" ] || ! command -v tmux >/dev/null 2>&1 || [ ! -t 1 ]; then
                command "$_sg_cmd" "$@"
            else
                tmux new-session "$_sg_cmd" "$@"
            fi
        }
        \(functions)
        """
    }

    /// zshrc へ挿入する1行（スクリプトが在るときだけ読み込む）
    static func sourceLine() -> String {
        """
        \(beginMarker)
        [ -f "\(scriptPath)" ] && . "\(scriptPath)"
        \(endMarker)
        """
    }

    // MARK: - 状態

    static func isInstalled() -> Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return contents.contains(beginMarker)
    }

    // MARK: - 導入 / 解除

    static func install(extraCommands: [String] = []) throws {
        try writeScript(extraCommands: extraCommands)

        let current = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        // 既に入っていれば二重に足さない
        guard !current.contains(beginMarker) else { return }

        try backupZshrc()
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        let updated = current + separator + "\n" + sourceLine() + "\n"
        try updated.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        guard let current = try? String(contentsOf: zshrcURL, encoding: .utf8),
              current.contains(beginMarker) else { return }
        try backupZshrc()
        let cleaned = removeBlock(from: current)
        try cleaned.write(to: zshrcURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: scriptPath)
    }

    // MARK: - テキスト操作（テスト対象の純粋ロジック）

    /// 目印で囲まれたブロックを取り除く
    static func removeBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var inside = false
        for line in lines {
            if line.contains(beginMarker) { inside = true; continue }
            if line.contains(endMarker) { inside = false; continue }
            if !inside { result.append(line) }
        }
        // 除去で生じた連続空行を1つに畳む
        var collapsed: [String] = []
        for line in result {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
    }

    // MARK: - ファイル入出力

    private static func writeScript(extraCommands: [String] = []) throws {
        let dir = (scriptPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try scriptBody(extraCommands: extraCommands).write(toFile: scriptPath, atomically: true, encoding: .utf8)
    }

    private static func backupZshrc() throws {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = zshrcURL.deletingLastPathComponent()
            .appendingPathComponent(".zshrc.subghost-backup-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: zshrcURL, to: backup)
    }
}
