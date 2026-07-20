//
//  HotkeyManager.swift
//  Subghost
//
//  設計書 4.3: グローバルショートカット（デフォルト ⌥Space）
//  Carbon RegisterEventHotKey を使用（アクセシビリティ権限が不要）。
//

import AppKit
import Carbon.HIToolbox

nonisolated enum HotkeyPreset: String, CaseIterable, Identifiable, Sendable {
    case optionSpace
    case controlSpace
    case commandShiftSpace

    static let userDefaultsKey = "globalHotkeyPreset"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionSpace: return "⌥Space"
        case .controlSpace: return "⌃Space"
        case .commandShiftSpace: return "⇧⌘Space"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlSpace: return UInt32(controlKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }

    static var current: HotkeyPreset {
        resolve(storedValue: UserDefaults.standard.string(forKey: userDefaultsKey))
    }

    static func resolve(storedValue: String?) -> HotkeyPreset {
        storedValue.flatMap(HotkeyPreset.init(rawValue:)) ?? .optionSpace
    }
}

final class HotkeyManager {

    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbonのイベントディスパッチはメインスレッドで行われる
            MainActor.assumeIsolated {
                manager.onHotkey?()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5355_4748), id: 1) // 'SUGH'
        let preset = HotkeyPreset.current
        RegisterEventHotKey(
            UInt32(kVK_Space),
            preset.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    func reload() {
        unregister()
        register()
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}
