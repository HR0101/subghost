# CLAUDE.md

SubghostはSwiftUI製のmacOSメニューバー／ノッチ常駐アプリです。Claude CodeとCodex CLIのタスクが作業途中か完了したかを、CLIフックから監視します。

## 重要な製品境界

- 監視専用。CLIへプロンプト、承認、回答、キー入力を送らない。
- tmuxを起動・接続・キャプチャ・操作しない。
- `ShellIntegration` は旧版が追加したauto-tmuxブロックを削除する移行専用。新しい設定を追加する処理へ戻さない。
- 画面テキストから状態を推測しない。状態の正はフックイベントとする。
- 終了イベントを時間だけで推測しない。取りこぼし時の誤完了より、`Working`の維持を選ぶ。

## 構成

- `Core/AgentDiscovery.swift`: `ps`からCLIプロセス、PID、TTYを検出
- `Core/HookInstaller.swift`: Claude/Codex設定への監視フックの安全な追加・解除
- `Core/HookServer.swift`: Unixドメインソケット上のローカルHTTP受信
- `Core/SessionWatcher.swift`: プロセス照合、フック状態、診断情報
- `Core/TranscriptReader.swift`: 本文表示を明示的に有効にした場合だけ記録末尾を読む
- `UI/AppCoordinator.swift`: 監視イベントを通知、履歴、サウンド、スリープへ伝播
- `UI/NotchView.swift`: ノッチUI
- `SubghostApp.swift`: アプリ入口とメニューバーの復旧導線

## セッション識別

`SessionInfo.id`はPIDがある場合はCLI種別＋PID、フック専用セッションではCLI種別＋`session_id`を使います。TTYはターミナルへ移動するための属性であり、同一性には使いません。同じTTYで複数CLIが動く場合や、TTYのないバックグラウンド実行を取り違えないためです。

フックの対応付けは次の順です。

1. CLIの`session_id`
2. PID
3. 候補が1件だけのTTY
4. 候補が1件だけの作業フォルダ

## フックの安全性

- 既存設定は保持し、書き換え前にバックアップする。
- Subghost所有項目は`subghost-bridge`マーカーで識別する。
- ブリッジはソケットが無ければ成功終了し、通信には1秒の上限を持つ。
- 受信サーバは状態処理を始める前に空応答を返す。
- フックは判断を返さず、CLI本来の承認フローへ介入しない。
- CLIの対応イベントは更新されるため、イベント集合を変更するときは導入中のCLIと公式資料を確認する。

## プライバシー

本文プレビューは既定で無効です。無効中はtranscriptを読まず、履歴にはプレースホルダだけを保存します。無効へ切り替えた時点で既存の履歴本文も置換します。診断ダンプは明示設定時だけ有効です。

## ビルドとテスト

```sh
xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SubghostTests test
```

UI、通知、フォーカス、ノッチ操作を変えた場合は署名可能な環境で全テストを実行します。テストでは固定`Date`と純粋ロジックを優先し、待ち時間に依存させません。

## 変更時の確認

- 生成したブリッジに`tmux`、`send-keys`、`.zshrc`変更が含まれない
- 同一TTYの別PIDを別セッションとして扱う
- `StopFailure`をエラーとして履歴へ残す
- 本文非表示中にtranscriptを読まない
- メニューバーから一覧、設定、終了へ到達できる
- 既存フックと旧版auto-tmux削除の移行を壊さない
