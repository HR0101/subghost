# Subghost

Ghosttyで動かすAI CLI(Claude Code / Codex / Antigravity)をMacのノッチから監視・操作する常駐アプリ。

- ノッチに各セッションの状態(待機/生成中/完了/エラー)を表示
- 応答完了時にノッチが展開して内容をチラ見せ
- `⌥Space` でノッチからプロンプトを直接送信(複数セッションの送信先切替対応)

## 前提

- tmux(`brew install tmux`)
- 各AI CLI(`claude` / `codex` / `antigravity`)

SubghostはtmuxセッションをAI CLIとの橋渡しに使うため、**CLIは `ai-` で始まる名前のtmuxセッション内で起動する必要がある**。tmuxの外で起動したCLIは検出も送信もできない。

## セットアップ:エイリアス登録

`~/.zshrc` に以下を追加する(各CLI最大4つまで同時追跡):

```zsh
# Subghost用: AI CLIをtmuxの ai-* セッション内で起動する(各CLI最大4つ)
alias aiclaude='tmux new-session -A -s ai-claude claude'
alias aiclaude2='tmux new-session -A -s ai-claude2 claude'
alias aiclaude3='tmux new-session -A -s ai-claude3 claude'
alias aiclaude4='tmux new-session -A -s ai-claude4 claude'
alias aicodex='tmux new-session -A -s ai-codex codex'
alias aicodex2='tmux new-session -A -s ai-codex2 codex'
alias aicodex3='tmux new-session -A -s ai-codex3 codex'
alias aicodex4='tmux new-session -A -s ai-codex4 codex'
alias aianti='tmux new-session -A -s ai-antigravity antigravity'
alias aianti2='tmux new-session -A -s ai-antigravity2 antigravity'
alias aianti3='tmux new-session -A -s ai-antigravity3 antigravity'
alias aianti4='tmux new-session -A -s ai-antigravity4 antigravity'
```

追加後、開いているタブでは `source ~/.zshrc` を実行(新しいタブでは不要)。

- `-s ai-〇〇` … セッション名。`ai-` プレフィックスがSubghostの検出条件で、続く名前の前方一致でCLIプロファイル(プロンプト記号・スピナー等の判定パターン)が選ばれる
- `-A` … 同名セッションが既にあれば新規作成せずそこに再接続する

## 使い方

1. Ghosttyのタブで `aiclaude` などを実行してCLIを起動
2. Subghostが自動検出し、ノッチに状態が表示される
3. `⌥Space` でプロンプト入力欄が開く
   - 送信先はドロップダウンまたは `Tab` キーで切替
   - `↑` で履歴呼び出し、`Esc` で閉じる
4. 応答完了はノッチ展開と通知で知らせる。クリックでGhosttyへ移動

## tmux基本操作

| したいこと | 操作 |
|---|---|
| セッションを残したままタブを離れる(デタッチ) | `Ctrl+b` → `d` |
| セッションに戻る | 同じエイリアスを再実行(例: `aiclaude`) |
| セッションを終了 | 中のCLIを終了する、または `tmux kill-session -t ai-claude` |
| セッション一覧 | `tmux ls` |

## ビルド

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost build
```

詳細は[詳細設計書.md](./詳細設計書.md)を参照。
