# リリース手順

1. `CHANGELOG.md` の次回リリース欄を更新する。
2. 次を実行し、警告と失敗がないことを確認する。

   ```sh
   xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
     -destination 'platform=macOS' test
   xcodebuild -project Subghost/Subghost.xcodeproj -scheme Subghost \
     -configuration Release -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO analyze
   plutil -lint Subghost/Subghost/PrivacyInfo.xcprivacy
   ! grep -R -nE \
     'send-keys|capture-pane|new-session|attach-session|kill-session|SIGTERM|SIGKILL|kill[[:space:]]*\(' \
     Subghost/Subghost --include='*.swift'
   ```

3. Claude CodeとCodex CLIをそれぞれ再起動し、`Working` → `Done`、失敗時のエラー履歴、通知、メニューバーの復旧導線を確認する。
4. tmuxが未導入のMacでも起動・監視でき、シェル起動時にtmuxが開始されず、CLIへ入力や終了シグナルを送らないことを確認する。
5. Release構成でArchiveし、Developer ID Applicationで署名する。
6. `notarytool`でAppleへ公証し、承認後にstapleする。
7. 公証済みアプリを新規ユーザー環境で起動し、Gatekeeper、初回案内、通知許可、フックの登録と解除を確認する。

自動更新を導入する場合は、署名済み配布先と更新フィードを先に確定し、ダウングレード・署名検証・ロールバックを含めて別途設計する。
