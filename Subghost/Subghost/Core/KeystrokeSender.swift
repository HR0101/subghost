//
//  KeystrokeSender.swift
//  Subghost
//
//  設計書 追補: tmuxを介さないセッションへの入力送信
//
//  フックはイベントを受け取れるだけで、CLIへ文字を送る手段は持たない。
//  質問への回答やプロンプト送信には別の経路が要る。
//  tmuxがあれば send-keys を使うが、無い場合はキー入力を合成するしかない。
//
//  安全設計:
//  - 合成したキーは「現在フォーカスされている場所」に入る。誤爆すると
//    無関係のウインドウへ文字を打ち込むため、対象タブの前面化に成功した
//    場合にのみ送信する。
//  - 送信は必ずユーザーの明示的な操作を起点とする。自動送信はしない。
//  - アクセシビリティ権限が無い場合は何も送らず、その旨をエラーで返す。
//

import AppKit
import CoreGraphics

nonisolated enum KeystrokeError: Error, LocalizedError {
    case accessibilityNotTrusted
    case eventCreationFailed
    case cannotVerifyTarget
    case wrongTabFocused

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "キー入力の送信にはアクセシビリティの許可が必要です。"
                + "システム設定 > プライバシーとセキュリティ > アクセシビリティ で Subghost を有効にしてください。"
        case .eventCreationFailed:
            return "キーイベントを作成できませんでした。"
        case .cannotVerifyTarget:
            return "送信先のタブを特定できないため中止しました。"
                + "Ghosttyはタブを指定して切り替えられず、別のCLIへ誤送信する恐れがあります。"
                + "このセッションへ送るには tmux 内で起動してください。"
        case .wrongTabFocused:
            return "狙ったタブが前面に出なかったため中止しました。もう一度お試しください。"
        }
    }
}

@MainActor
enum KeystrokeSender {

    /// Returnキーの仮想キーコード
    private static let returnKeyCode: CGKeyCode = 36

    /// タブを前面化してから入力するまでの待ち時間
    private static let focusSettleDelay = Duration.milliseconds(250)
    /// 文字送信とReturnの間隔（TUIが入力を処理する猶予）
    private static let submitDelay = Duration.milliseconds(120)

    // MARK: - 権限

    /// アクセシビリティの許可があるか
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 許可を求めるダイアログを出す（未許可のときのみ表示される）
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - 送信

    /// 対象セッションのタブへ移動してから文字列を送る。
    /// `submit` が真なら末尾でReturnを送る。
    static func send(
        text: String,
        to session: SessionInfo,
        submit: Bool
    ) async throws {
        guard isTrusted else { throw KeystrokeError.accessibilityNotTrusted }

        let payload = sanitize(text)
        guard !payload.isEmpty || submit else { return }

        // 入力先を確実にするため、まず該当タブを前面に出す
        await TerminalActivator.jump(to: session)
        try? await Task.sleep(for: focusSettleDelay)

        // 前面のタブが本当に狙ったセッションか確かめる。
        // 合成したキーは「今フォーカスされている場所」に入るため、
        // 確認できないまま送ると別のCLIへプロンプトが飛ぶ。
        switch TerminalActivator.isFrontmostTab(session: session) {
        case .some(true):
            break
        case .some(false):
            throw KeystrokeError.wrongTabFocused
        case .none:
            throw KeystrokeError.cannotVerifyTarget
        }

        if !payload.isEmpty {
            try type(payload)
        }
        if submit {
            try? await Task.sleep(for: submitDelay)
            try pressReturn()
        }
    }

    // MARK: - 低レベル

    /// 任意の文字列をキーイベントとして送る。
    /// 仮想キーコードへの変換はキーボード配列に依存するため、
    /// Unicode文字列を直接載せる方式にしている（配列非依存）。
    static func type(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)

        for chunk in chunked(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw KeystrokeError.eventCreationFailed }

            var buffer = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func pressReturn() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false)
        else { throw KeystrokeError.eventCreationFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 純粋ロジック（テスト対象）

    /// 1イベントに載る長さへ分割する
    /// 1イベントに載せられるUTF-16単位の上限（余裕を持たせた値）
    nonisolated static let unicodeChunkSize = 16

    nonisolated static func chunked(_ text: String, size: Int = unicodeChunkSize) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.utf16.count >= size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 制御文字を落とす。改行は送信操作（Return）と区別するため空白にする。
    nonisolated static func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let filtered = normalized.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }
        return String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
