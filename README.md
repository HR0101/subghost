# Subghost

Claude Code / Codex CLI のタスク状態をMacのノッチから確認する、SwiftUI製macOS常駐アプリです。

## できること

- フックイベントを受信したAI CLIセッションを自動表示
- 各タスクを `Working`（作業途中）/ `Done`（完了）で表示
- タスク完了時にノッチ、macOS通知、サウンドで通知
- 本文表示を許可した場合、CLI本文・送信内容・返答・AIタスクリストをノッチのポップアップで表示
- 対象のターミナルへ移動
- 指定したタスクの完了後にMacをスリープ
- ノッチを見失った場合も使えるメニューバーの復旧メニュー

Subghostは監視専用です。プロンプト、承認、質問への回答をCLIへ送信せず、CLIプロセスの終了も行いません。
送信内容はCLIフック、CLI本文・返答・AIタスクリストはフックが示すローカルのセッション記録から読み取ります。端末画面のキャプチャやターミナルマルチプレクサには依存しません。

## 動作環境

- macOS 14 Sonoma以降
- Claude CodeまたはCodex CLI（状態監視にはフック連携が必要）

## 対応CLI

| CLI | 状態監視 |
| --- | --- |
| Claude Code | フック連携で対応 |
| Codex CLI | フック連携で対応 |

Antigravityは利用できるフック機構を確認できていないため、現在は状態監視の対象外です。

## セットアップ

1. Subghostを起動する
2. 設定の「フック連携」で使用するCLIを有効にする
3. 実行中のCLIを再起動する

Claude Codeは `~/.claude/settings.json`、Codexは `~/.codex/hooks.json` にSubghost用フックを追記します。既存設定は保持し、変更前にバックアップを作成します。Subghostが起動していない場合、フックは何もせず正常終了します。

現行版はシェル起動設定を変更せず、フック設定だけを監視専用イベントへ更新します。

## 状態の扱い

- タスク開始、ツール実行、承認要求など、終了していないイベントは `Working`
- `Stop` とセッション終了は `Done`
- `StopFailure` は内部ではエラーとして記録し、2状態表示では `Done`
- `Done` は次のタスクが始まるまで保持

承認や質問が発生してもSubghostは回答せず、CLI本来の画面へそのまま委ねます。
本文ポップアップは設定の「会話本文とAIタスクを表示しない」をオフにした場合だけ表示します。タスクリストも会話本文と同じプライバシー設定に従います。

終了フックを取りこぼした場合、誤って完了扱いにせず `Working` を維持します。設定の「統合」にある受信テストと最終受信時刻で疎通を確認できます。

## プライバシー

会話本文のプレビューは既定で無効です。この状態では、Subghostはフックに含まれるセッション記録パスから本文やタスクリストを読みません。プレビューを有効にした場合だけ、ローカルの記録末尾を読み、ポップアップと通知に表示します。詳しくは [PRIVACY.md](PRIVACY.md) を参照してください。

Codexの使用量取得は既定で有効です。不要な場合は設定から無効にできます。

## ビルドとテスト

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SubghostTests test
```

UIテストを含む全テストは、署名できるローカル環境で次を実行します。

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' test
```

配布前の手順は [RELEASING.md](RELEASING.md) にまとめています。
