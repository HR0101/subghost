//
//  HotkeyManager.swift
//  Subghost
//
//  設計書 4.3: グローバルショートカット（デフォルト ⌥Space）
//  Carbon RegisterEventHotKey を使用（アクセシビリティ権限が不要）。
//
//  当初はプロンプト入力を開く1つだけを、3つのプリセットから選ぶ形だった。
//  操作ごとに任意のキーを割り当てられるよう、行動(HotkeyAction)と
//  キーの組(HotkeyBinding)に分けている。
//

import AppKit
import Carbon.HIToolbox

// MARK: - キーの組み合わせ

/// 1つのショートカットを表す。
///
/// `keyLabel` は記録した時点で `charactersIgnoringModifiers` から取った表示用の文字。
/// キーコードから文字を逆算するとキーボード配列ごとの変換が必要になるため、
/// 押された瞬間の文字をそのまま覚えておくほうが確実で、実装も小さく済む。
nonisolated struct HotkeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon の修飾キー（cmdKey / optionKey / controlKey / shiftKey の OR）
    var carbonModifiers: UInt32
    var keyLabel: String

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// "⇧⌘Space" のような表示。修飾キーの並びは macOS の慣習に合わせる。
    var displayText: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    /// 修飾キーが1つも無い割り当ては、通常のタイピングを奪ってしまうため認めない
    var hasModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0
    }

    /// 記録の取り消しに使うキー。設定画面が Carbon を直接importせずに済むよう公開する。
    static let escapeKeyCode = UInt16(kVK_Escape)

    /// AppKit のイベントから作る（設定画面の記録ボタン用）
    static func from(event: NSEvent) -> HotkeyBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let label = Self.label(for: event)
        guard !label.isEmpty else { return nil }
        return HotkeyBinding(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: label
        )
    }

    /// 表示用のキー名。文字を持たない特殊キーだけ名前を当てる。
    private static func label(for event: NSEvent) -> String {
        if let named = specialKeyLabels[Int(event.keyCode)] { return named }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return ""
        }
        return characters.uppercased()
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Escape: "Esc",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "PageUp",
        kVK_PageDown: "PageDown",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

// MARK: - 割り当てられる操作

nonisolated enum HotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case toggleInput
    case showSessions
    case showActivity
    case jumpToTerminal
    case approveChoice
    case denyChoice
    case toggleMute

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleInput: return "プロンプト入力を開く／閉じる"
        case .showSessions: return "セッション一覧を開く"
        case .showActivity: return "アクティビティ履歴を開く"
        case .jumpToTerminal: return "対象のターミナルへ移動"
        case .approveChoice: return "承認する"
        case .denyChoice: return "拒否する"
        case .toggleMute: return "サウンドの消音を切り替える"
        }
    }

    var detail: String {
        switch self {
        case .toggleInput: return "どのアプリからでもノッチの入力欄を開きます"
        case .showSessions: return "検出中のAI CLIを一覧で表示します"
        case .showActivity: return "完了・エラー・回答待ちの履歴を開きます"
        case .jumpToTerminal: return "回答待ち、なければ送信先のセッションのタブへ移動します"
        case .approveChoice: return "回答待ちの承認リクエストに「はい」で答えます"
        case .denyChoice: return "回答待ちの承認リクエストに「いいえ」で答えます"
        case .toggleMute: return "アラート音を一時的に止めます"
        }
    }

    var category: String {
        switch self {
        case .toggleInput, .showSessions, .showActivity: return "ノッチを開く"
        case .jumpToTerminal: return "移動"
        case .approveChoice, .denyChoice: return "回答"
        case .toggleMute: return "サウンド"
        }
    }

    /// 未設定のときに使う既定値。既定を持たない操作は nil（＝無効）。
    ///
    /// 入力欄以外を既定で埋めないのは、他アプリのショートカットと衝突する余地を
    /// 増やさないため。必要な人だけが明示的に割り当てる。
    var defaultBinding: HotkeyBinding? {
        switch self {
        case .toggleInput:
            return HotkeyBinding(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: UInt32(optionKey),
                keyLabel: "Space"
            )
        default:
            return nil
        }
    }

    var userDefaultsKey: String { "hotkey.\(rawValue)" }

    /// 保存済みの割り当て。未保存なら既定値。
    var binding: HotkeyBinding? { binding(in: .standard) }

    func binding(in defaults: UserDefaults) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: userDefaultsKey) else {
            return defaultBinding
        }
        // 明示的に「無効」を保存した場合は空データを入れてある
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    func setBinding(_ binding: HotkeyBinding?, in defaults: UserDefaults = .standard) {
        guard let binding else {
            // 「既定に戻す」ではなく「無効」であることを区別するため空データを置く
            defaults.set(Data(), forKey: userDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    /// 保存を消して既定へ戻す
    func resetBinding(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// 画面に出す割り当て表示。未割り当てなら nil。
    var displayShortcut: String? { binding?.displayText }

    /// 案内文へ埋め込む用。未割り当てのときは操作名で代替する。
    var shortcutOrName: String { displayShortcut ?? "「\(displayName)」（未割り当て）" }
}

// MARK: - 旧設定からの移行

/// 以前は「⌥Space / ⌃Space / ⇧⌘Space」の3択だった。
/// 既存ユーザーの選択を、そのまま toggleInput の割り当てとして引き継ぐ。
nonisolated enum HotkeyPreset {
    static let userDefaultsKey = "globalHotkeyPreset"
    static let migratedKey = "hotkeyPresetMigrated"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        guard let stored = defaults.string(forKey: userDefaultsKey) else { return }
        let modifiers: UInt32
        switch stored {
        case "controlSpace": modifiers = UInt32(controlKey)
        case "commandShiftSpace": modifiers = UInt32(cmdKey | shiftKey)
        case "optionSpace": modifiers = UInt32(optionKey)
        default: return
        }
        // 既に新形式で割り当て済みなら上書きしない
        guard defaults.data(forKey: HotkeyAction.toggleInput.userDefaultsKey) == nil else { return }
        HotkeyAction.toggleInput.setBinding(
            HotkeyBinding(
                keyCode: UInt32(kVK_Space),
                carbonModifiers: modifiers,
                keyLabel: "Space"
            ),
            in: defaults
        )
    }
}

// MARK: - 登録

final class HotkeyManager {

    /// 押されたショートカットに対応する操作を通知する
    var onAction: ((HotkeyAction) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// EventHotKeyID.id → 操作 の対応表
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private static let signature = OSType(0x5355_4748)   // 'SUGH'

    func register() {
        HotkeyPreset.migrateIfNeeded()
        installHandlerIfNeeded()

        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let binding = action.binding, binding.hasModifier else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            // 他アプリが同じ組み合わせを先に押さえている場合は失敗する。
            // 残りの割り当ては生かしたいので、ここでは中断せず記録だけ残す。
            guard status == noErr, let ref else {
                NSLog("Subghost: ショートカット \(binding.displayText) を登録できませんでした"
                      + "（他のアプリが使用中の可能性があります）")
                continue
            }
            hotKeyRefs[id] = ref
            actionsByID[id] = action
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbonのイベントディスパッチはメインスレッドで行われる
            MainActor.assumeIsolated {
                guard let action = manager.actionsByID[hotKeyID.id] else { return }
                manager.onAction?(action)
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    func reload() {
        unregisterHotKeys()
        register()
    }

    func unregister() {
        unregisterHotKeys()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
    }
}
