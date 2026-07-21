//
//  SettingsPreferencesTests.swift
//  SubghostTests
//
//  設定として切り出した判断ロジックのユニットテスト。
//  いずれも副作用のない純粋関数か、テスト専用のUserDefaultsスイートを使う。
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Subghost

// MARK: - 静穏時間

struct QuietHoursTests {

    /// 分数を時刻に見立てたDateを作る
    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 21
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    @Test func 同じ日で完結する時間帯を判定する() {
        // 13:00〜15:00
        let start = 13 * 60
        let end = 15 * 60

        #expect(QuietHours.isQuiet(at: date(hour: 13, minute: 0), start: start, end: end))
        #expect(QuietHours.isQuiet(at: date(hour: 14, minute: 30), start: start, end: end))
        #expect(!QuietHours.isQuiet(at: date(hour: 12, minute: 59), start: start, end: end))
        // 終了時刻ちょうどは含まない
        #expect(!QuietHours.isQuiet(at: date(hour: 15, minute: 0), start: start, end: end))
    }

    @Test func 日付をまたぐ時間帯を判定する() {
        // 22:00〜翌7:00
        let start = 22 * 60
        let end = 7 * 60

        #expect(QuietHours.isQuiet(at: date(hour: 23, minute: 0), start: start, end: end))
        #expect(QuietHours.isQuiet(at: date(hour: 2, minute: 0), start: start, end: end))
        #expect(QuietHours.isQuiet(at: date(hour: 22, minute: 0), start: start, end: end))
        #expect(!QuietHours.isQuiet(at: date(hour: 7, minute: 0), start: start, end: end))
        #expect(!QuietHours.isQuiet(at: date(hour: 12, minute: 0), start: start, end: end))
    }

    /// 開始と終了が同じとき「一日中」にしてしまうと、誤設定で全通知が消えて
    /// 原因に気づきにくい。何も起きないほうを選んでいる。
    @Test func 開始と終了が同じなら静穏時間を適用しない() {
        let same = 9 * 60
        #expect(!QuietHours.isQuiet(at: date(hour: 9, minute: 0), start: same, end: same))
        #expect(!QuietHours.isQuiet(at: date(hour: 21, minute: 0), start: same, end: same))
    }

    @Test func 分数を時刻の文字列にする() {
        #expect(QuietHours.text(forMinutes: 0) == "00:00")
        #expect(QuietHours.text(forMinutes: 22 * 60) == "22:00")
        #expect(QuietHours.text(forMinutes: 7 * 60 + 30) == "07:30")
        // 範囲外の値でも一日の中へ丸める
        #expect(QuietHours.text(forMinutes: 24 * 60) == "00:00")
        #expect(QuietHours.text(forMinutes: -60) == "23:00")
    }
}

// MARK: - 通知イベント

struct NotificationEventTests {

    @Test func 状態から対応する通知イベントを求める() {
        #expect(NotificationEvent.from(state: .completed) == .completed)
        #expect(NotificationEvent.from(state: .error) == .error)
        #expect(NotificationEvent.from(state: .awaitingApproval) == .approval)
        #expect(NotificationEvent.from(state: .awaitingAnswer) == .question)
        // 知らせる必要のない状態には対応するイベントが無い
        #expect(NotificationEvent.from(state: .idle) == nil)
        #expect(NotificationEvent.from(state: .thinking) == nil)
    }

    /// 回答するまでCLIが止まるイベントだけが、静穏時間や集中モードの例外になる
    @Test func 回答待ちのイベントだけをブロッキングとして扱う() {
        #expect(NotificationEvent.approval.isBlocking)
        #expect(NotificationEvent.question.isBlocking)
        #expect(!NotificationEvent.completed.isBlocking)
        #expect(!NotificationEvent.error.isBlocking)
    }

    @Test func サウンドと通知イベントが対応する() {
        #expect(AlertSound.completed.notificationEvent == .completed)
        #expect(AlertSound.approval.notificationEvent == .approval)
        // セッションに紐づかない音には対になる通知が無い
        #expect(AlertSound.appLaunched.notificationEvent == nil)
        #expect(AlertSound.promptSent.notificationEvent == nil)
    }
}

// MARK: - ショートカット

struct HotkeyBindingTests {

    @Test func 修飾キーの並びを表示用に組み立てる() {
        let binding = HotkeyBinding(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "Space"
        )
        #expect(binding.displayText == "⇧⌘Space")
    }

    @Test func 修飾キーの有無を判定する() {
        let withModifier = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(optionKey),
            keyLabel: "K"
        )
        // 修飾キーなしの割り当ては通常のタイピングを奪うため認めない
        let without = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: 0,
            keyLabel: "K"
        )
        #expect(withModifier.hasModifier)
        #expect(!without.hasModifier)
    }

    @Test func 未設定の操作は既定の割り当てを返す() {
        let suiteName = "SubghostTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // プロンプト入力だけが既定を持ち、残りは未割り当てで始まる
        #expect(HotkeyAction.toggleInput.binding(in: defaults)?.displayText == "⌥Space")
        #expect(HotkeyAction.approveChoice.binding(in: defaults) == nil)
    }

    /// 「既定に戻す」と「無効にする」は別の状態として保存し分ける必要がある
    @Test func 明示的な解除と既定への復帰を区別する() {
        let suiteName = "SubghostTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyAction.toggleInput.setBinding(nil, in: defaults)
        #expect(HotkeyAction.toggleInput.binding(in: defaults) == nil)

        HotkeyAction.toggleInput.resetBinding(in: defaults)
        #expect(HotkeyAction.toggleInput.binding(in: defaults)?.displayText == "⌥Space")
    }

    @Test func 保存した割り当てを読み戻せる() {
        let suiteName = "SubghostTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let binding = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(controlKey | optionKey),
            keyLabel: "J"
        )
        HotkeyAction.jumpToTerminal.setBinding(binding, in: defaults)
        #expect(HotkeyAction.jumpToTerminal.binding(in: defaults) == binding)
    }

    /// 3択のプリセットだった頃の選択を、新しい割り当てとして引き継ぐ
    @Test func 旧プリセットの設定を移行する() {
        let suiteName = "SubghostTests.HotkeyMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("commandShiftSpace", forKey: HotkeyPreset.userDefaultsKey)
        HotkeyPreset.migrateIfNeeded(defaults: defaults)

        #expect(HotkeyAction.toggleInput.binding(in: defaults)?.displayText == "⇧⌘Space")
        #expect(defaults.bool(forKey: HotkeyPreset.migratedKey))
    }

    @Test func 移行は一度だけ行う() {
        let suiteName = "SubghostTests.HotkeyMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("controlSpace", forKey: HotkeyPreset.userDefaultsKey)
        HotkeyPreset.migrateIfNeeded(defaults: defaults)

        // 移行後にユーザーが変更した割り当てを、二度目の移行で戻してしまわない
        let chosen = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(cmdKey),
            keyLabel: "P"
        )
        HotkeyAction.toggleInput.setBinding(chosen, in: defaults)
        HotkeyPreset.migrateIfNeeded(defaults: defaults)

        #expect(HotkeyAction.toggleInput.binding(in: defaults) == chosen)
    }
}

// MARK: - 並べ替え

struct ReorderingTests {

    @Test func 要素を後ろへ移動する() {
        let items = ["a", "b", "c", "d"]
        // SwiftUIのonMoveは「移動先＝取り除く前の添字」で渡してくる
        let moved = Reordering.moved(items, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(moved == ["b", "c", "a", "d"])
    }

    @Test func 要素を前へ移動する() {
        let items = ["a", "b", "c", "d"]
        let moved = Reordering.moved(items, fromOffsets: IndexSet(integer: 3), toOffset: 1)
        #expect(moved == ["a", "d", "b", "c"])
    }

    @Test func 複数の要素をまとめて移動する() {
        let items = ["a", "b", "c", "d", "e"]
        let moved = Reordering.moved(items, fromOffsets: IndexSet([0, 2]), toOffset: 5)
        #expect(moved == ["b", "d", "e", "a", "c"])
    }

    @Test func 範囲外の指定でも壊れない() {
        let items = ["a", "b", "c"]
        #expect(Reordering.moved(items, fromOffsets: IndexSet(integer: 9), toOffset: 0) == items)
        // 移動先が末尾を超えても末尾へ収める
        #expect(
            Reordering.moved(items, fromOffsets: IndexSet(integer: 0), toOffset: 99)
                == ["b", "c", "a"]
        )
    }
}

// MARK: - アクティビティ履歴

struct ActivityRetentionTests {

    private func entry(_ summary: String) -> ActivityEntry {
        ActivityEntry(
            kind: .completed,
            sessionTTY: "/dev/ttys001",
            sessionPID: 100,
            agentID: "claude",
            agentName: "Claude Code",
            sessionName: "work",
            summary: summary
        )
    }

    @Test func 保持件数を超えたら古いものから捨てる() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ActivityStore(defaults: defaults, storageKey: "history", maximumCount: 3)
        for index in 0..<5 { store.append(entry("\(index)")) }

        #expect(store.entries.count == 3)
        // 新しい順に並ぶので、最後に入れたものが先頭に残る
        #expect(store.entries.first?.summary == "4")
        #expect(store.entries.last?.summary == "2")
    }

    @Test func 未読件数を数える() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ActivityStore(defaults: defaults, storageKey: "history", maximumCount: 10)
        store.append(entry("a"))
        store.append(entry("b"))
        #expect(store.unreadCount == 2)

        store.markAllRead()
        #expect(store.unreadCount == 0)
    }
}
