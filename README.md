# Subghost

Claude Code / Codex CLI のタスク状態をMacのノッチから確認する、SwiftUI製macOS常駐アプリです。

## できること

- 実行中のAI CLIをプロセスから自動検出
- 各タスクを `Working`（作業途中）/ `Done`（完了）で表示
- タスク完了時にノッチ、macOS通知、サウンドで通知
- 対象のターミナルへ移動
- 指定したタスクの完了後にMacをスリープ

Subghostは監視専用です。プロンプト、承認、質問への回答をCLIへ送信しません。tmuxも使用しません。

## 対応CLI

| CLI | 検出 | 状態監視 |
| --- | --- | --- |
| Claude Code | 対応 | フック連携で対応 |
| Codex CLI | 対応 | フック連携で対応 |

Antigravityは利用できるフック機構を確認できていないため、現在は状態監視の対象外です。

## セットアップ

1. Subghostを起動する
2. 設定の「フック連携」で使用するCLIを有効にする
3. 実行中のCLIを再起動する

Claude Codeは `~/.claude/settings.json`、Codexは `~/.codex/hooks.json` にSubghost用フックを追記します。既存設定は保持し、変更前にバックアップを作成します。Subghostが起動していない場合、フックは何もせず正常終了します。

旧版の「自動でtmux内起動」が有効だった場合は、初回起動時にSubghostが追加したシェル設定だけを自動解除します。

## 状態の扱い

- `UserPromptSubmit`、ツール実行、通知・承認要求など、タスクが終了していないイベントは `Working`
- `Stop` と終了イベントは `Done`
- `Done` は次のタスクが始まるまで保持
- Stopイベントを取りこぼした場合は、10分間イベントが無ければ安全弁として `Done` に戻す

承認や質問が発生してもSubghostは回答せず、CLI本来の画面へそのまま委ねます。

## ビルドとテスト

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost build
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' test
```

テスト署名を使えない環境では、コンパイル確認だけを次で行えます。

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```
