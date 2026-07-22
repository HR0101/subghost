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
//  最優先の要件は「どんな状況でも元のCLIが必ず起動すること」。
//  ここはユーザーのシェルに常駐し、失敗するとCLIごと起動できなくなるため、
//  機能が働かないことより壊れないことを優先する。
//
//  - ~/.zshrc は書き換え前にバックアップする。シンボリックリンク（dotfiles管理）
//    の場合は実体へ書き、リンクを壊さない
//  - Subghostが追加した行は目印で囲み、解除時にその範囲だけを取り除く
//  - tmuxへ入れる条件は事前に厳しく判定する。判定を1つでも満たさなければ素通しする
//  - 判定を通ってもtmuxが失敗しうるので、必ず素の実行へ戻す経路を用意する。
//    セッションは切り離し(-d)で作ってから繋ぐ。作成に失敗した時点では
//    CLIは一度も実行されていないため、二重実行の心配なく戻せる
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

    /// 実際に書き込む先。
    /// ~/.zshrc をdotfilesリポジトリへのシンボリックリンクにしている人は多く、
    /// 原子的書き込み（一時ファイル＋rename）はリンクを実ファイルで置き換えてしまう。
    /// 実体を解決してから書くことで、ユーザーのdotfiles管理を壊さない。
    static var zshrcWriteURL: URL {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return zshrcURL }
        return zshrcURL.resolvingSymlinksInPath()
    }

    // MARK: - スクリプト本体

    /// 対象コマンドを包むシェル関数を生成する。
    /// - Parameter extraCommands: ユーザー登録のカスタムエイリアス名（実行ファイル名）。
    ///   ビルトインと重複するもの（大文字小文字を区別しない）は無視する。
    static func scriptBody(extraCommands: [String] = []) -> String {
        // ここでコマンド名をそのままシェル関数定義へ埋め込むため、呼び出し元の
        // バリデーション（CustomAliasStore.add）を信頼しきらず、ここでも
        // 安全な文字だけに絞る（多層防御。実機レビューで指摘された脆弱性）。
        var seen = Set<String>()
        let allCommands = (wrappedCommands + extraCommands.filter(CustomAlias.isValidName))
            .filter { seen.insert($0.lowercased()).inserted }
        let functions = allCommands.map { command in
            "\(command)() { _subghost_run \(command) \"$@\"; }"
        }.joined(separator: "\n")

        return """
        #!/bin/sh
        # Subghost: AI CLIを対話起動のときだけ自動でtmux内に入れる。
        #
        # この関数はユーザーのシェルに常駐するため、何があっても元のCLIが
        # 起動しなくなることは許されない。tmuxを経由する条件は事前に厳しく判定し、
        # それでも失敗したときは必ず素の実行へ戻す。
        _subghost_sock="\(HookInstaller.socketPath)"

        # tmuxへ入れてよい状況かを判定する（0を返したときだけ包む）
        _subghost_can_wrap() {
            # Subghost未起動 / 既にtmux内 / tmux未導入
            [ -S "$_subghost_sock" ] || return 1
            [ -z "$TMUX" ] || return 1
            command -v tmux >/dev/null 2>&1 || return 1
            # tmuxが画面に繋ぐには入力・出力・エラーのすべてが端末である必要がある。
            # 1つでも欠けると "open terminal failed" でCLIごと起動できなくなる。
            # 例: `claude < /dev/null`、エディタ組み込み端末、CI。
            [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || return 1
            # 画面制御ができない端末ではtmuxは起動できない
            case "${TERM:-}" in
                "" | dumb | unknown | emacs) return 1 ;;
            esac
            return 0
        }

        # 対話セッションを開かない使い方は包まない。
        # 包むとtmux終了時に画面が復元され、出力が消えてしまう（--version 等）。
        _subghost_is_interactive_use() {
            for _sg_arg in "$@"; do
                case "$_sg_arg" in
                    -p | --print | -v | --version | -h | --help \\
                    | doctor | update | mcp | config | install | setup-token | migrate-installer)
                        return 1 ;;
                esac
            done
            return 0
        }

        _subghost_run() {
            _sg_cmd="$1"; shift
            if ! _subghost_can_wrap || ! _subghost_is_interactive_use "$@"; then
                command "$_sg_cmd" "$@"
                return $?
            fi

            # 切り離した状態で作る。ここが失敗した時点ではCLIは一度も実行されて
            # いないので、二重実行の心配なく素の実行へ戻せる。
            _sg_sess="ai-$_sg_cmd-$$"
            if tmux new-session -d -s "$_sg_sess" "$_sg_cmd" "$@" 2>/dev/null; then
                tmux attach-session -t "$_sg_sess" 2>/dev/null && return 0
                # 繋げなかった。セッションが残っていればCLIはtmux内で動いているので、
                # 畳んでから素の実行へ戻す（残っていなければ既に実行・終了済み）。
                if tmux has-session -t "$_sg_sess" 2>/dev/null; then
                    tmux kill-session -t "$_sg_sess" 2>/dev/null
                else
                    return 0
                fi
            fi
            command "$_sg_cmd" "$@"
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
        try updated.write(to: zshrcWriteURL, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        guard let current = try? String(contentsOf: zshrcURL, encoding: .utf8),
              current.contains(beginMarker) else { return }
        try backupZshrc()
        let cleaned = removeBlock(from: current)
        try cleaned.write(to: zshrcWriteURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: scriptPath)
    }

    /// 既に導入済みの場合だけ、最新のカスタムエイリアスを反映してスクリプト本体を
    /// 再生成する。zshrcは変更しない（導入されていなければ何もしない）。
    ///
    /// カスタムエイリアスの追加・削除のたびに呼ぶ必要がある。導入時にしか
    /// スクリプトを書き出さないと、後から登録したエイリアス名が自動tmux起動に
    /// 反映されないままになる（実機レビューで指摘された不具合）。
    static func refreshScriptIfInstalled(extraCommands: [String] = []) {
        guard isInstalled() else { return }
        try? writeScript(extraCommands: extraCommands)
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
