//
//  SubghostTests.swift
//  SubghostTests
//
//  状態判定ロジック（設計書 5）のユニットテスト
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Subghost

// MARK: - ノッチ表示設定

struct NotchPreferencesTests {
    @Test func 未保存の設定は指定した既定値を返す() {
        let suiteName = "SubghostTests.NotchPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotchPreferences.bool(
            forKey: "enabled", default: true, defaults: defaults))
        #expect(NotchPreferences.number(
            forKey: "duration", default: 5.0, defaults: defaults) == 5.0)
    }

    @Test func 保存済みの設定は既定値より優先される() {
        let suiteName = "SubghostTests.NotchPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "enabled")
        defaults.set(0.35, forKey: "delay")

        #expect(!NotchPreferences.bool(
            forKey: "enabled", default: true, defaults: defaults))
        #expect(NotchPreferences.number(
            forKey: "delay", default: 0.15, defaults: defaults) == 0.35)
    }

    /// ショートカットは3択のプリセットから任意のキー割り当てへ変わった。
    /// 未設定時に既定へ戻る性質と、不正な保存値を無視する性質は
    /// HotkeyBindingTests（SettingsPreferencesTests.swift）で引き続き担保している。
    @Test func ショートカットの未設定は既定値へ戻る() {
        let suiteName = "SubghostTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HotkeyAction.showSessions.binding(in: defaults)?.displayText == "⌥Space")

        // 壊れた値が入っていても既定へ倒れる（クラッシュしない）
        defaults.set(Data("not a binding".utf8), forKey: HotkeyAction.showSessions.userDefaultsKey)
        #expect(HotkeyAction.showSessions.binding(in: defaults) == nil)
    }

    @Test func 展開アニメーション時間を安全な範囲へ補正する() {
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(0) == 0.15)
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(0.65) == 0.65)
        #expect(NotchPreferences.normalizedExpansionAnimationDuration(3) == 1.20)
    }
}

struct NotchSurfaceShapeTests {
    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 400)
    private let compactWidth: CGFloat = 278
    private let compactHeight: CGFloat = 34

    @Test func 変形開始時は本体の外側に上部ショルダーを持つ() {
        let bounds = makeShape(progress: 0).path(in: canvas).boundingRect

        #expect(abs(bounds.width - NotchLayout.canvasWidth(for: compactWidth)) < 0.01)
        #expect(abs(bounds.height - compactHeight) < 0.01)
        #expect(abs(bounds.midX - canvas.midX) < 0.01)
        #expect(abs(bounds.minY - canvas.minY) < 0.01)
    }

    @Test func 変形完了時は展開領域全体に一致する() {
        let bounds = makeShape(progress: 1).path(in: canvas).boundingRect

        #expect(abs(bounds.width - canvas.width) < 0.01)
        #expect(abs(bounds.height - canvas.height) < 0.01)
    }

    @Test func 変形途中は横方向が下方向より先行する() {
        let bounds = makeShape(progress: 0.5).path(in: canvas).boundingRect
        let initialWidth = NotchLayout.canvasWidth(for: compactWidth)
        let horizontal = (bounds.width - initialWidth) / (canvas.width - initialWidth)
        let vertical = (bounds.height - compactHeight) / (canvas.height - compactHeight)

        #expect(horizontal > vertical)
    }

    private func makeShape(progress: CGFloat) -> NotchSurfaceShape {
        NotchSurfaceShape(
            progress: progress,
            compactWidth: compactWidth,
            compactHeight: compactHeight,
            canvasShoulderInset: NotchLayout.topShoulderWidth
        )
    }
}

struct PixelGhostAnimationTests {
    @Test func ゴーストは生成中だけ動く() {
        #expect(GhostSprite.shouldAnimate(for: .thinking))
        #expect(!GhostSprite.shouldAnimate(for: .idle))
        #expect(!GhostSprite.shouldAnimate(for: .completed))
        #expect(!GhostSprite.shouldAnimate(for: .error))
        #expect(!GhostSprite.shouldAnimate(for: .awaitingApproval))
        #expect(!GhostSprite.shouldAnimate(for: .awaitingAnswer))
    }
}

struct SessionsListLayoutTests {
    @Test func 少数のセッションでは行数に合わせた高さになる() {
        #expect(NotchLayout.sessionsListHeight(count: 0) == 0)
        #expect(NotchLayout.sessionsListHeight(count: 2) == 136)
    }

    @Test func 多数のセッションでも一覧の最大高を超えない() {
        #expect(NotchLayout.sessionsListHeight(count: 100) == NotchLayout.sessionsListMaxHeight)
    }
}

struct PromptDraftStoreTests {
    @Test func セッションを切り替えても下書きが混ざらない() {
        var drafts = PromptDraftStore()

        drafts.setText("Claudeへの質問", for: "101:/dev/ttys001")
        drafts.setText("Codexへの依頼\n二行目", for: "202:/dev/ttys002")

        #expect(drafts.text(for: "101:/dev/ttys001") == "Claudeへの質問")
        #expect(drafts.text(for: "202:/dev/ttys002") == "Codexへの依頼\n二行目")
    }

    @Test func 送信したセッションの下書きだけを消せる() {
        var drafts = PromptDraftStore()
        drafts.setText("送信する内容", for: "101:/dev/ttys001")
        drafts.setText("残す内容", for: "202:/dev/ttys002")

        drafts.setText("", for: "101:/dev/ttys001")

        #expect(drafts.text(for: "101:/dev/ttys001").isEmpty)
        #expect(drafts.text(for: "202:/dev/ttys002") == "残す内容")
    }
}

struct ActivityStoreTests {
    @Test func 履歴を新しい順に上限件数まで保存して復元する() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "history"
        let store = ActivityStore(defaults: defaults, storageKey: key, maximumCount: 2)

        let first = makeEntry(summary: "1")
        let second = makeEntry(summary: "2")
        let third = makeEntry(summary: "3")
        store.append(first)
        store.append(second)
        store.append(third)

        #expect(store.entries.map(\.summary) == ["3", "2"])
        #expect(store.unreadCount == 2)

        store.markRead(third.id)
        let restored = ActivityStore(defaults: defaults, storageKey: key, maximumCount: 2)
        #expect(restored.entries == store.entries)
        #expect(restored.unreadCount == 1)
    }

    @Test func 履歴をすべて既読にして消去できる() {
        let suiteName = "SubghostTests.Activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ActivityStore(defaults: defaults, storageKey: "history")
        store.append(makeEntry(summary: "完了"))

        store.markAllRead()
        #expect(store.unreadCount == 0)

        store.clear()
        #expect(store.entries.isEmpty)
    }

    private func makeEntry(summary: String) -> ActivityEntry {
        ActivityEntry(
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .completed,
            sessionTTY: "/dev/ttys004",
            sessionPID: 100,
            agentID: "codex",
            agentName: "Codex CLI",
            sessionName: "subghost",
            summary: summary
        )
    }
}

// MARK: - 通知のセッション紐付け

struct NotificationRoutingTests {

    @Test func 通知ペイロードからセッション情報を復元できる() {
        let original = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)

        let restored = NotificationSessionReference(userInfo: original.userInfo)

        #expect(restored == original)
    }

    @Test func 同じTTYでもPIDが違えば別セッションとして管理する() {
        let oldSession = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        let newSession = NotificationSessionReference(tty: "/dev/ttys004", pid: 200)

        #expect(oldSession != newSession)
    }

    @Test func 新しい質問通知を発行すると古いトークンは無効になる() {
        let session = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        var registry = ChoiceNotificationRegistry()

        let oldToken = registry.issue(for: session, token: "old")
        let newToken = registry.issue(for: session, token: "new")

        #expect(!registry.isCurrent(oldToken, for: session))
        #expect(registry.isCurrent(newToken, for: session))
    }

    @Test func 通知トークンは一度だけ使用できる() {
        let session = NotificationSessionReference(tty: "/dev/ttys004", pid: 100)
        var registry = ChoiceNotificationRegistry()
        let token = registry.issue(for: session, token: "single-use")

        let firstResult = registry.consume(token, for: session)
        let secondResult = registry.consume(token, for: session)

        #expect(firstResult)
        #expect(!secondResult)
    }
}

struct StateDetectorTests {

    private func makeDetector() -> StateDetector {
        var detector = StateDetector(profile: .claude)
        detector.stableInterval = 1.5
        detector.completedHoldInterval = 8.0
        return detector
    }

    @Test func 初回取り込みは基準値でありイベントを出さない() {
        var detector = makeDetector()
        let event = detector.ingest(rawText: "何らかの初期画面", at: Date(timeIntervalSince1970: 0))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }

    @Test func 出力伸長でthinkingへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let event = detector.ingest(rawText: "画面A\n新しい出力", at: t0.addingTimeInterval(0.8))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func 静止しプロンプト記号が現れたらcompletedになる() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        _ = detector.ingest(rawText: "画面A\n応答本文です", at: t0.addingTimeInterval(0.8))
        // まだ静止時間が足りない
        let final = "画面A\n応答本文です\n╭──╮\n│ > │\n╰──╯"
        let early = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        #expect(early == .becameThinking || early == .none)  // テキスト変化→thinking維持
        // 1.5秒静止後
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(3.5))
        guard case .becameCompleted(let preview) = event else {
            Issue.record("completedにならなかった: \(event)")
            return
        }
        #expect(detector.state == .completed)
        #expect(preview.contains { $0.contains("応答本文です") })
    }

    @Test func busy表示が残っている間はthinkingを維持する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let busy = "画面A\n✻ Thinking… (esc to interrupt)\n│ > │"
        _ = detector.ingest(rawText: busy, at: t0.addingTimeInterval(0.8))
        let event = detector.ingest(rawText: busy, at: t0.addingTimeInterval(5.0))
        #expect(event == .none)
        #expect(detector.state == .thinking)
    }

    @Test func 過去のWorking表示が画面上部に残っていても入力待ちなら完了になる() {
        var detector = StateDetector(profile: .codex)
        detector.stableInterval = 1.5
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "初期画面", at: t0)

        // capture-paneの可視領域上部に以前の作業表示が残り、末尾は現在の入力待ち。
        // 画面全体へbusyPatternを当てると、先頭のWorkingを拾って永久にthinkingになる。
        let final = (["• Working (12s • Esc to interrupt)"]
            + (1...12).map { "完了した応答の行\($0)" }
            + ["›"])
            .joined(separator: "\n")

        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(0.8))
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(3.0))
        guard case .becameCompleted = event else {
            Issue.record("過去のWorking表示に引きずられた: \(event)")
            return
        }
        #expect(detector.state == .completed)
    }

    @Test func エラーパターンでerrorへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        _ = detector.ingest(rawText: "画面A\n出力中", at: t0.addingTimeInterval(0.8))
        let event = detector.ingest(rawText: "画面A\nAPI Error: rate limited", at: t0.addingTimeInterval(1.6))
        guard case .becameError = event else {
            Issue.record("errorにならなかった: \(event)")
            return
        }
        #expect(detector.state == .error)
    }

    @Test func completedは一定時間後にidleへ戻る() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        _ = detector.ingest(rawText: "A\n本文", at: t0.addingTimeInterval(0.8))
        let final = "A\n本文\n│ > │"
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(4.0))
        #expect(detector.state == .completed)
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(13.0))
        #expect(event == .becameIdle)
        #expect(detector.state == .idle)
    }

    /// 完了後の画面は、ステータス行やヒント行が差し替わるだけでも「変化」する。
    /// それを作業再開とみなして再び完了判定すると、1回の応答に対して通知が
    /// 何度も出てしまう（実機で確認した不具合）。
    @Test func 完了後の再描画で同じ応答を二度完了として知らせない() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        _ = detector.ingest(rawText: "A\n応答本文です", at: t0.addingTimeInterval(0.8))
        let final = "A\n応答本文です\n│ > │"
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        let first = detector.ingest(rawText: final, at: t0.addingTimeInterval(4.0))
        guard case .becameCompleted = first else {
            Issue.record("1回目が完了にならなかった: \(first)")
            return
        }

        // ステータス行だけが差し替わる（本文は同じ）。busy表示は出ない。
        let redrawn = "A\n応答本文です\n│ > │\n  ⏸ manual mode on · gh auth login for PR status"
        let resumed = detector.ingest(rawText: redrawn, at: t0.addingTimeInterval(5.0))
        #expect(resumed == .becameThinking)

        // 通常の静止時間では完了に戻さない
        #expect(detector.ingest(rawText: redrawn, at: t0.addingTimeInterval(7.0)) == .none)

        // 十分に静止しても、本文が同じなら完了としては知らせず待機へ戻すだけ
        let again = detector.ingest(rawText: redrawn, at: t0.addingTimeInterval(20.0))
        #expect(again == .becameIdle)
        #expect(detector.state == .idle)
    }

    /// 再描画ではなく本当に次の応答が来た場合は、通常どおり完了を知らせる。
    @Test func 完了後に新しい応答が来たら改めて完了を知らせる() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        _ = detector.ingest(rawText: "A\n1つ目の応答", at: t0.addingTimeInterval(0.8))
        let first = "A\n1つ目の応答\n│ > │"
        _ = detector.ingest(rawText: first, at: t0.addingTimeInterval(1.6))
        _ = detector.ingest(rawText: first, at: t0.addingTimeInterval(4.0))
        #expect(detector.state == .completed)

        // busy表示＝実際に作業している裏付けがあるので、再描画扱いにはしない
        let busy = "A\n1つ目の応答\n✻ Thinking… (esc to interrupt)\n│ > │"
        _ = detector.ingest(rawText: busy, at: t0.addingTimeInterval(5.0))
        #expect(detector.state == .thinking)

        let second = "A\n1つ目の応答\n2つ目の応答\n│ > │"
        _ = detector.ingest(rawText: second, at: t0.addingTimeInterval(6.0))
        let event = detector.ingest(rawText: second, at: t0.addingTimeInterval(8.0))
        guard case .becameCompleted(let preview) = event else {
            Issue.record("2つ目の応答が完了にならなかった: \(event)")
            return
        }
        #expect(preview.contains { $0.contains("2つ目の応答") })
    }

    @Test func プロンプト送信でthinkingへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        let event = detector.noteUserSentPrompt(at: t0.addingTimeInterval(1.0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func プロンプト記号が検出できなくても長時間静止でidleへ戻る() {
        var detector = makeDetector()
        detector.idleFallbackInterval = 30.0
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面A", at: t0)
        let stuck = "画面A\nプロンプト記号のない出力"
        _ = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(0.8))
        #expect(detector.state == .thinking)
        // 30秒未満はthinkingのまま
        let early = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(20.0))
        #expect(early == .none)
        #expect(detector.state == .thinking)
        // 30秒静止でidleへ
        let event = detector.ingest(rawText: stuck, at: t0.addingTimeInterval(31.0))
        #expect(event == .becameIdle)
        #expect(detector.state == .idle)
    }

    @Test func 新UIの山括弧プロンプトとステータスバーでも完了を検出する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "初期画面", at: t0)
        _ = detector.ingest(
            rawText: "初期画面\n✻ Baking… (esc to interrupt · 12s)",
            at: t0.addingTimeInterval(0.8))
        #expect(detector.state == .thinking)

        // 実機のClaude Code画面: ❯プロンプト＋横罫線＋ステータスバー
        let final = """
        ⏺ 修正が完了しました。
          テストも追加済みです。

        ✢ Worked for 6m 23s

        ──────────────────────────────
        ❯
        ──────────────────────────────
          Sonnet 5 · effort xhigh in subghost │ 5h [██████░░░░] 27% → 15:40
          ⏵⏵ auto mode on (shift+tab to cycle) · gh auth login for PR status
        """
        _ = detector.ingest(rawText: final, at: t0.addingTimeInterval(1.6))
        let event = detector.ingest(rawText: final, at: t0.addingTimeInterval(3.5))
        guard case .becameCompleted(let preview) = event else {
            Issue.record("completedにならなかった: \(event)")
            return
        }
        #expect(detector.state == .completed)
        #expect(preview.contains { $0.contains("修正が完了しました") })
        #expect(!preview.contains { $0.contains("Worked for") })
        #expect(!preview.contains { $0.contains("Sonnet") })
        #expect(!preview.contains { $0.contains("auto mode") })
    }

    /// 実機のClaude Codeの作業中画面（capture-paneの実出力）。
    /// 動詞はランダムで "esc to interrupt" は出ない。経過時間とトークン数だけが動くが、
    /// それらは clean() で除去されるため画面は静止して見える。
    private func 作業中画面(経過: String, トークン: String) -> String {
        """
        ⏺ Reading 1 file, running 2 shell commands · 2s…
          ⎿  $ for s in 0 1 2; do echo hi; done

        ✢ Drizzling… (\(経過) · ↓ \(トークン) tokens)
          ⎿  Tip: Use /btw to ask a quick side question without interrupting Claude's current work
                                                                 ◉ xhigh · /effort
        ─────────────────────────────────────────────
        ❯
        ─────────────────────────────────────────────
          Opus 4.8 · effort xhigh in subghost  │  5h [█░░░░░░░░░]  14% → 18:00
          ⏵⏵ auto mode on (shift+tab to cycle) · gh auth login for PR status
        """
    }

    @Test func ランダムな動詞の作業中表示でも完了と誤判定しない() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "初期画面", at: t0)
        _ = detector.ingest(rawText: 作業中画面(経過: "35s", トークン: "1.3k"), at: t0.addingTimeInterval(0.8))
        #expect(detector.state == .thinking)

        // ツール実行の待ち時間中は経過秒数しか動かず、cleanすると前回と同一のテキストになる。
        // ❯プロンプトは常時表示されているため、busyを取りこぼすと completed へ倒れてしまう。
        let 静止 = 作業中画面(経過: "58s", トークン: "1.3k")
        #expect(StateDetector.clean(静止, profile: .claude)
            == StateDetector.clean(作業中画面(経過: "35s", トークン: "1.3k"), profile: .claude))

        #expect(detector.ingest(rawText: 静止, at: t0.addingTimeInterval(3.0)) == .none)
        #expect(detector.ingest(rawText: 静止, at: t0.addingTimeInterval(8.0)) == .none)
        #expect(detector.state == .thinking)
    }

    @Test func 誤ってcompletedになっても作業中表示で生成中へ戻る() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "初期画面", at: t0)
        _ = detector.ingest(rawText: "初期画面\n応答本文です\n❯", at: t0.addingTimeInterval(0.8))
        _ = detector.ingest(rawText: "初期画面\n応答本文です\n❯", at: t0.addingTimeInterval(3.0))
        #expect(detector.state == .completed)

        let event = detector.ingest(
            rawText: 作業中画面(経過: "5s", トークン: "0.2k"), at: t0.addingTimeInterval(4.0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func 作業中の状態表示行はチラ見せに含めない() {
        let preview = StateDetector.extractPreview(
            from: 作業中画面(経過: "35s", トークン: "1.3k"), profile: .claude)
        #expect(!preview.contains { $0.contains("Drizzling") })
        #expect(!preview.contains { $0.contains("Tip:") })
        #expect(!preview.contains { $0.contains("/effort") })
    }

    @Test func Claudeの新規タスク案内を返信として表示しない() {
        let screen = """
        ⏺ 修正が完了しました。
          日本語の返信本文です。

        ─────────────────────────────────────────────
        new task? /clear to save 499.5k tokens
        ❯
        ─────────────────────────────────────────────
          Opus 4.8 · effort xhigh in subghost
        """
        let preview = StateDetector.extractPreview(from: screen, profile: .claude)
        #expect(preview.contains { $0.contains("修正が完了しました") })
        #expect(preview.contains { $0.contains("日本語の返信本文です") })
        #expect(!preview.contains { $0.contains("new task?") })
        #expect(!preview.contains { $0.contains("tokens") })
    }

    @Test func スピナーの変化だけではthinkingにならない() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "画面 ⠋", at: t0)
        let event = detector.ingest(rawText: "画面 ⠙", at: t0.addingTimeInterval(0.8))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }
}

struct TextProcessingTests {
    @Test func プレビューは枠線とプロンプト行を除いた本文を返す() {
        let raw = """
        古い出力

        これが応答の本文です。
        二行目の内容。

        ╭────────────╮
        │ >          │
        ╰────────────╯
          ? for shortcuts
        """
        let preview = StateDetector.extractPreview(from: raw, profile: .claude)
        #expect(!preview.isEmpty)
        #expect(preview.contains { $0.contains("これが応答の本文です") })
        #expect(!preview.contains { $0.contains("shortcuts") })
    }

}

// MARK: - ゼロコンフィグ検出

struct AgentDiscoveryTests {

    private let profiles = CLIProfile.builtins

    /// `ps -A -o pid=,tty=,comm=` を模した出力
    private let psOutput = """
      934 ??       /Applications/ChatGPT.app/Contents/Resources/codex
     3514 ttys003  claude
    41080 ttys004  claude
    68352 ttys004  /bin/zsh
    77001 ttys005  /opt/homebrew/bin/codex
    """

    @Test func 実行ファイル名からAI_CLIを検出する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(found.count == 3)
        #expect(found.map(\.pid) == [3514, 41080, 77001])
        #expect(found.map(\.profile.id) == ["claude", "claude", "codex"])
    }

    @Test func 制御端末を持たないプロセスは除外する() {
        // ChatGPT.appが同梱するcodex（ttyが ??）を拾ってはいけない
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(!found.contains { $0.pid == 934 })
    }

    @Test func AI_CLI以外のプロセスは無視する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(!found.contains { $0.pid == 68352 })   // /bin/zsh
    }

    @Test func ttyはdev付きの絶対パスに正規化する() {
        let found = AgentDiscovery.parseAgentProcesses(psOutput, profiles: profiles)
        #expect(found.first?.tty == "/dev/ttys003")
    }

    @Test func Antigravityは実体名agyで検出する() {
        // "antigravity" というコマンドは存在せず、実体は "agy"（実測）
        let found = AgentDiscovery.parseAgentProcesses(
            "  84323 ttys005  /Users/me/.local/bin/agy", profiles: profiles)
        #expect(found.count == 1)
        #expect(found.first?.profile.id == "antigravity")
        #expect(found.first?.tty == "/dev/ttys005")
    }

    @Test func Codexはnode配下の実体パスでも検出する() {
        // 実測: node_modules配下の長いパスで動いている
        let path = "/Users/me/.nodebrew/node/v22.9.0/lib/node_modules/@openai/codex/"
            + "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        let found = AgentDiscovery.parseAgentProcesses("  39003 ttys010  \(path)", profiles: profiles)
        #expect(found.first?.profile.id == "codex")
    }

    @Test func 実行ファイル名は完全一致で判定する() {
        // "claude-helper" のような別物を拾わない
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude", profiles: profiles)?.id == "claude")
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude-helper", profiles: profiles) == nil)
        #expect(AgentDiscovery.matchProfile(commandPath: "/bin/zsh", profiles: profiles) == nil)
    }

    @Test func カスタムエイリアスを登録すると独自の実行ファイル名でも検出できる() {
        let alias = CustomAlias(name: "codexA", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/codexA", profiles: merged)?.id == "codex")
        // ビルトインの検出は壊れていないこと
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/claude", profiles: merged)?.id == "claude")
    }

    @Test func カスタムエイリアスは大文字小文字を無視して照合する() {
        // psのcomm列は小文字化して比較するため、登録名も揃える必要がある
        let alias = CustomAlias(name: "CodexA", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/codexa", profiles: merged)?.id == "codex")
    }

    @Test func 存在しないプロファイルIDのカスタムエイリアスは無視する() {
        let alias = CustomAlias(name: "mystery", baseProfileID: "no-such-profile")
        let merged = CLIProfile.withCustomAliases([alias])
        #expect(merged.count == CLIProfile.builtins.count)
        #expect(AgentDiscovery.matchProfile(commandPath: "/usr/local/bin/mystery", profiles: merged) == nil)
    }

    @Test func 既存の実行ファイル名と重複するカスタムエイリアスは二重登録しない() {
        let alias = CustomAlias(name: "codex", baseProfileID: "codex")
        let merged = CLIProfile.withCustomAliases([alias])
        let codexProfile = merged.first { $0.id == "codex" }
        #expect(codexProfile?.executableNames.filter { $0 == "codex" }.count == 1)
    }

    @Test func 英数字とハイフンアンダースコアのエイリアス名は妥当とみなす() {
        #expect(CustomAlias.isValidName("codexA"))
        #expect(CustomAlias.isValidName("my-agent_2"))
        #expect(CustomAlias.isValidName("_underscore"))
    }

    @Test(arguments: [
        "",                     // 空文字
        "2fast",                // 数字始まり
        "-dash",                // ハイフン始まり
        "my agent",             // 空白
        "codex; rm -rf ~",      // コマンド区切り
        "codex`whoami`",        // コマンド置換（バッククォート）
        "$(whoami)",            // コマンド置換（$構文）
        "codex&&ls",            // 論理演算子
        "codex|ls",             // パイプ
        String(repeating: "a", count: 65),   // 長すぎる
    ])
    func シェルへ危険な文字を含むエイリアス名は不正とみなす(_ name: String) {
        // シェルスクリプトへそのまま埋め込まれるため、これらを許すと
        // コマンドインジェクションが成立してしまう（実機レビューで指摘された脆弱性）
        #expect(!CustomAlias.isValidName(name))
    }

    // MARK: - 一覧に出すかどうか

    private func 表示判断入力(
        needsUserResponse: Bool = false,
        isActiveTarget: Bool = false,
        isMonitorable: Bool = true,
        activityAt: Date,
        hiddenAtActivity: Date? = nil
    ) -> SessionVisibility.Input {
        SessionVisibility.Input(
            needsUserResponse: needsUserResponse,
            isActiveTarget: isActiveTarget,
            isMonitorable: isMonitorable,
            activityAt: activityAt,
            hiddenAtActivity: hiddenAtActivity
        )
    }

    private var 既定ルール: SessionVisibility.Rules {
        SessionVisibility.Rules(
            revealAll: false,
            hideUnmonitorable: true,
            hideInactive: true,
            inactiveThreshold: 1_800
        )
    }

    @Test func 長時間動きの無いセッションは一覧から外す() {
        let now = Date(timeIntervalSince1970: 100_000)
        // 31分前が最終活動
        let stale = 表示判断入力(activityAt: now.addingTimeInterval(-1_860))
        let fresh = 表示判断入力(activityAt: now.addingTimeInterval(-60))
        #expect(!SessionVisibility.isVisible(stale, rules: 既定ルール, at: now))
        #expect(SessionVisibility.isVisible(fresh, rules: 既定ルール, at: now))
    }

    @Test func 監視できないセッションは一覧から外す() {
        let now = Date(timeIntervalSince1970: 100_000)
        let input = 表示判断入力(isMonitorable: false, activityAt: now)
        #expect(!SessionVisibility.isVisible(input, rules: 既定ルール, at: now))
    }

    /// 隠す設定より見逃し防止を優先する。答えるまでCLIが止まってしまうため。
    @Test func 回答待ちのセッションは放置扱いでも必ず表示する() {
        let now = Date(timeIntervalSince1970: 100_000)
        let input = 表示判断入力(
            needsUserResponse: true,
            isMonitorable: false,
            activityAt: now.addingTimeInterval(-100_000),
            hiddenAtActivity: now
        )
        #expect(SessionVisibility.isVisible(input, rules: 既定ルール, at: now))
    }

    @Test func 送信先に選んでいるセッションは必ず表示する() {
        let now = Date(timeIntervalSince1970: 100_000)
        let input = 表示判断入力(
            isActiveTarget: true,
            activityAt: now.addingTimeInterval(-100_000)
        )
        #expect(SessionVisibility.isVisible(input, rules: 既定ルール, at: now))
    }

    @Test func 手動で隠したセッションは新しい動きがあれば戻る() {
        let now = Date(timeIntervalSince1970: 100_000)
        let hiddenAt = now.addingTimeInterval(-600)

        // 隠した時点から動きが無い → 隠れたまま
        let quiet = 表示判断入力(activityAt: hiddenAt, hiddenAtActivity: hiddenAt)
        #expect(!SessionVisibility.isVisible(quiet, rules: 既定ルール, at: now))

        // 隠した後に動いた → また使い始めたとみなして表示
        let resumed = 表示判断入力(
            activityAt: now.addingTimeInterval(-10), hiddenAtActivity: hiddenAt)
        #expect(SessionVisibility.isVisible(resumed, rules: 既定ルール, at: now))
    }

    @Test func すべて表示中は絞り込みを行わない() {
        let now = Date(timeIntervalSince1970: 100_000)
        var rules = 既定ルール
        rules.revealAll = true
        let input = 表示判断入力(
            isMonitorable: false,
            activityAt: now.addingTimeInterval(-100_000),
            hiddenAtActivity: now
        )
        #expect(SessionVisibility.isVisible(input, rules: rules, at: now))
    }

    @Test func 隠す設定を切れば放置セッションも表示する() {
        let now = Date(timeIntervalSince1970: 100_000)
        var rules = 既定ルール
        rules.hideInactive = false
        rules.hideUnmonitorable = false
        let input = 表示判断入力(
            isMonitorable: false, activityAt: now.addingTimeInterval(-100_000))
        #expect(SessionVisibility.isVisible(input, rules: rules, at: now))
    }

    // MARK: - できることの区分

    private func セッション(hookID: String?) -> SessionInfo {
        var info = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys006", profile: .claude))
        info.hookSessionID = hookID
        return info
    }

    @Test func フック接続なら状態を監視できるが送信はできない() {
        let info = セッション(hookID: "abc")
        #expect(info.capability == .monitorOnly)
        #expect(!info.canSendPrompt)
        #expect(info.isMonitorable)
    }

    @Test func フックが無ければ検出のみ() {
        let info = セッション(hookID: nil)
        #expect(info.capability == .detectedOnly)
        #expect(!info.canSendPrompt)
        #expect(!info.isMonitorable)
    }

    @Test func 検出したセッションは端末に直接対応する() {
        let outside = SessionInfo(agent: DiscoveredAgent(
            pid: 2, tty: "/dev/ttys003", profile: .claude))

        #expect(!outside.isMonitorable)
        #expect(outside.displayName == "ttys003")

        // 作業ディレクトリが分かればフォルダ名を主体にする
        var withFolder = outside
        withFolder.workingDirectory = "/Users/me/Create App/subghost"
        #expect(withFolder.displayName == "subghost")
        #expect(withFolder.folderName == "subghost")
    }
}

struct SessionSelectionTests {

    @Test func 次のセッション名へ循環する() {
        let names = ["ai-claude", "ai-claude2", "ai-codex"]
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-claude") == "ai-claude2")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-claude2") == "ai-codex")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-codex") == "ai-claude")
    }

    @Test func 現在が未設定または消滅していたら先頭を返す() {
        let names = ["ai-claude", "ai-codex"]
        #expect(SessionWatcher.nextSessionName(in: names, after: nil) == "ai-claude")
        #expect(SessionWatcher.nextSessionName(in: names, after: "ai-gone") == "ai-claude")
    }

    @Test func セッションが空ならnilを返す() {
        #expect(SessionWatcher.nextSessionName(in: [], after: nil) == nil)
    }
}

// MARK: - ノッチパネルの重なり順・入力設定

@MainActor
struct NotchPanelConfigTests {

    private func makePanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
    }

    @Test func パネルはメニューバーより上のレベルに置かれる() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        // メニューバー(24)・ステータスバー(25)より上でないと、
        // 全画面アプリの上に出せずクリックも通らない
        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
        #expect(panel.level == NotchPanelController.panelLevel)
    }

    @Test func isFloatingPanelにレベルを上書きされていない() {
        // 不具合の再発防止:
        // isFloatingPanel = true は level を .floating(3) に上書きするため、
        // 設定順序を誤ると 26 が 3 に潰れる。実際にこれで表示もクリックも壊れた。
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(panel.isFloatingPanel)
        #expect(panel.level.rawValue != NSWindow.Level.floating.rawValue)
        #expect(panel.level.rawValue == 26)
    }

    @Test func 全画面スペースにも参加する設定になっている() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func マウス入力を受け取る設定になっている() {
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(!panel.ignoresMouseEvents)
    }

    @Test func キーウインドウになれる設定になっている() {
        // becomesKeyOnlyIfNeeded が true だと makeKeyAndOrderFront しても
        // 入力欄にフォーカスが渡らず、プロンプトを打てなくなる
        let panel = makePanel()
        NotchPanelController.configure(panel)

        #expect(!panel.becomesKeyOnlyIfNeeded)
    }
}

// MARK: - メニューバーの表示状態

struct MenuBarVisibilityTests {

    /// 実測のCG座標（原点はメインディスプレイ左上、y軸は下向き）
    private let dell = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let builtin = CGRect(x: 207, y: 1440, width: 1512, height: 982)

    private func window(layer: Int, _ rect: CGRect) -> MenuBarVisibility.WindowSummary {
        MenuBarVisibility.WindowSummary(layer: layer, bounds: rect)
    }

    @Test func 全画面アプリのある画面ではメニューバー無しと判定する() {
        // 実測: 全画面時、メニューバーのウインドウは内蔵側にしか存在しなかった
        let windows = [
            window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33)),   // 内蔵のメニューバー
            window(layer: 0, CGRect(x: 0, y: 38, width: 2560, height: 1402)),      // DELLの全画面アプリ
        ]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
        #expect(MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: builtin))
    }

    @Test func メニューバーが出ている画面では表示と判定する() {
        let windows = [window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 30))]
        #expect(MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 画面全体を覆うレイヤー24のオーバーレイは誤検出しない() {
        // 実測でスクリーンショットUIがレイヤー24・画面全体で存在していた
        let windows = [window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 別画面のメニューバーを拾わない() {
        // 内蔵のメニューバーだけがある状態でDELLを問い合わせる
        let windows = [window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 上端から離れた細長いウインドウは誤検出しない() {
        let windows = [window(layer: 24, CGRect(x: 0, y: 700, width: 2560, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func レイヤーが違えばメニューバーとみなさない() {
        let windows = [window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    @Test func 横方向の重なりが半分以下なら別画面とみなす() {
        // DELLの左端にわずかにかかるだけのウインドウ
        let windows = [window(layer: 24, CGRect(x: -2000, y: 0, width: 2100, height: 30))]
        #expect(!MenuBarVisibility.isMenuBarVisible(windows: windows, onScreen: dell))
    }

    // MARK: - ノッチを出すかどうかの総合判定

    /// 実測: DELLで全画面、メニューバーは内蔵側にのみ存在
    private var fullScreenOnDell: [MenuBarVisibility.WindowSummary] {
        [
            window(layer: 24, CGRect(x: 207, y: 1440, width: 1512, height: 33)),
            window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 38)),
            window(layer: 0, CGRect(x: 0, y: 38, width: 2560, height: 1402)),
        ]
    }

    @Test func 全画面に覆われた画面では隠す() {
        #expect(!MenuBarVisibility.shouldShowNotch(windows: fullScreenOnDell, onScreen: dell))
    }

    @Test func 別の画面が全画面でも対象画面のノッチは消さない() {
        // 不具合の再発防止:
        // メニューバーはフォーカスされた画面にしか描画されないため、
        // 「メニューバーが無い」だけを条件にすると対象画面のノッチまで消えていた。
        let windows = [
            // DELLが全画面。メニューバーはどこにも描画されていない状況
            window(layer: 0, CGRect(x: 0, y: 0, width: 2560, height: 1440)),
        ]
        // 内蔵は覆われていないので表示し続ける
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: builtin))
    }

    @Test func 全画面中でもメニューバーが現れたら表示する() {
        // 全画面でマウスを上端に運びメニューバーが出た状態
        let windows = fullScreenOnDell + [
            window(layer: 24, CGRect(x: 0, y: 0, width: 2560, height: 30)),
        ]
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: dell))
    }

    @Test func 通常のウインドウでは隠さない() {
        // メニューバーの下に配置された最大化ウインドウ
        let windows = [
            window(layer: 0, CGRect(x: 0, y: 30, width: 2560, height: 1410)),
        ]
        #expect(!MenuBarVisibility.isCoveredByFullScreenWindow(windows: windows, onScreen: dell))
        #expect(MenuBarVisibility.shouldShowNotch(windows: windows, onScreen: dell))
    }

    @Test func 幅の狭いウインドウが上端にあっても全画面とみなさない() {
        let windows = [
            window(layer: 0, CGRect(x: 0, y: 0, width: 800, height: 1440)),
        ]
        #expect(!MenuBarVisibility.isCoveredByFullScreenWindow(windows: windows, onScreen: dell))
    }

    @Test func ウインドウが1つも取れない場合は表示する() {
        // 権限や異常系で一覧が空でも、消えてしまうより出しておく
        #expect(MenuBarVisibility.shouldShowNotch(windows: [], onScreen: dell))
    }
}

// MARK: - ノッチの寸法・配置

struct NotchMetricsTests {

    /// 実測値: DELL S2725DC（外部モニタ、ノッチなし）
    @Test func 外部モニタでは画面の絶対上端に配置する() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1410),
            safeAreaTop: 0,
            auxiliaryWidths: nil
        )
        #expect(!metrics.hasNotch)
        // visibleFrame.maxY(1410)ではなくframe.maxY(1440)に置く。
        // 1410だとメニューバーのぶん下にずれてしまう。
        #expect(metrics.topY == 1440)
        // 高さは決め打ちではなく実測（1440 - 1410 = 30）
        #expect(metrics.topInset == 30)
    }

    /// 実測値: Built-in Retina Display（ノッチあり）
    @Test func ノッチ搭載画面ではノッチ幅と高さを使う() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: -982, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: -982, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryWidths: (left: 663.5, right: 663.5)
        )
        #expect(metrics.hasNotch)
        #expect(metrics.topY == 0)          // frame.maxY
        #expect(metrics.topInset == 32)     // safeAreaInsets.top
        #expect(metrics.notchWidth == 185)  // 1512 - 663.5 * 2
    }

    @Test func ノッチの有無によらず上端は同じ基準で決まる() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let withNotch = NotchMetrics.make(
            frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1048),
            safeAreaTop: 32, auxiliaryWidths: (left: 800, right: 800))
        let withoutNotch = NotchMetrics.make(
            frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050),
            safeAreaTop: 0, auxiliaryWidths: nil)

        #expect(withNotch.topY == withoutNotch.topY)
        #expect(withNotch.topY == frame.maxY)
    }

    @Test func メニューバーを測れない場合は既定値を使う() {
        // メニューバー自動非表示や、副画面にメニューバーが無い構成
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            auxiliaryWidths: nil
        )
        #expect(metrics.topInset == NotchMetrics.fallbackMenuBarHeight)
        #expect(metrics.topY == 1080)
    }

    @Test func safeAreaがあってもaux情報が無ければ擬似ノッチに倒す() {
        let metrics = NotchMetrics.make(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryWidths: nil
        )
        #expect(!metrics.hasNotch)
        #expect(metrics.notchWidth == NotchMetrics.pseudoNotchWidth)
        #expect(metrics.topY == 982)
    }
}

// MARK: - 表示先ディスプレイの選択

struct DisplaySelectorTests {

    private let builtin = ScreenDescriptor(
        id: "uuid-builtin", name: "内蔵ディスプレイ", hasNotch: true,
        isPrimary: false, isActive: false)
    private let external = ScreenDescriptor(
        id: "uuid-studio", name: "Studio Display", hasNotch: false,
        isPrimary: true, isActive: false)
    private let third = ScreenDescriptor(
        id: "uuid-third", name: "サブモニタ", hasNotch: false,
        isPrimary: false, isActive: true)

    private var all: [ScreenDescriptor] { [builtin, external, third] }

    @Test func 自動ではノッチ搭載画面を優先する() {
        #expect(DisplaySelector.select(from: all, preference: .automatic) == builtin)
    }

    @Test func 自動でノッチ搭載画面が無ければ主ディスプレイを使う() {
        let noNotch = [external, third]
        #expect(DisplaySelector.select(from: noNotch, preference: .automatic) == external)
    }

    @Test func 主ディスプレイ指定はノッチ搭載画面より優先される() {
        #expect(DisplaySelector.select(from: all, preference: .primary) == external)
    }

    @Test func 追従指定では作業中の画面を選ぶ() {
        // 主ディスプレイでもノッチ搭載でもない画面が、フォーカスされていれば選ばれる
        #expect(DisplaySelector.select(from: all, preference: .followActive) == third)
    }

    @Test func 追従先が不明なら自動に倒す() {
        let noneActive = [builtin, external]
        #expect(DisplaySelector.select(from: noneActive, preference: .followActive) == builtin)
    }

    @Test func 特定のディスプレイを指定できる() {
        #expect(DisplaySelector.select(from: all, preference: .specific(id: "uuid-third")) == third)
    }

    @Test func 指定した画面を外すと自動にフォールバックする() {
        // 外部モニタを取り外した状況
        let remaining = [builtin]
        let selected = DisplaySelector.select(from: remaining, preference: .specific(id: "uuid-studio"))
        #expect(selected == builtin)
    }

    @Test func 画面が1枚も無ければnilを返す() {
        #expect(DisplaySelector.select(from: [], preference: .automatic) == nil)
        #expect(DisplaySelector.select(from: [], preference: .primary) == nil)
        #expect(DisplaySelector.select(from: [], preference: .followActive) == nil)
    }

    @Test func 設定値の保存と復元が往復する() {
        #expect(DisplayPreference(storedValue: "") == .automatic)
        #expect(DisplayPreference(storedValue: "main") == .primary)
        #expect(DisplayPreference(storedValue: "active") == .followActive)
        #expect(DisplayPreference(storedValue: "uuid-x") == .specific(id: "uuid-x"))

        #expect(DisplayPreference.automatic.storedValue == "")
        #expect(DisplayPreference.primary.storedValue == "main")
        #expect(DisplayPreference.followActive.storedValue == "active")
        #expect(DisplayPreference.specific(id: "uuid-x").storedValue == "uuid-x")
    }

    @Test func 主ディスプレイが見つからなければ自動に倒す() {
        let none = [builtin, third]
        #expect(DisplaySelector.select(from: none, preference: .primary) == builtin)
    }
}

// MARK: - フック方式

struct HookEventTests {

    private func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func 権限リクエストを解釈する() {
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "abc-123",
            "cwd": "/Users/me/Create App/subghost",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "ビルド成果物を削除"],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.kind == .permissionRequest)
        #expect(event.sessionID == "abc-123")
        #expect(event.projectName == "subghost")
        #expect(event.toolSummary == "rm -rf build")
        #expect(event.title.contains("Bash"))
        #expect(!event.kind.isBlocking)
        #expect(event.kind.resultingState == .thinking)
    }

    @Test func AskUserQuestionの権限リクエストから選択肢を取り出す() {
        // tool_input に questions/options が入っているため、記録を読まずに選択肢を作れる
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "どうしますか?",
                "options": [["label": "続ける"], ["label": "やめる"]],
            ]]],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.toolName == "AskUserQuestion")
        #expect(event.embeddedQuestion?.title == "どうしますか?")
        #expect(event.embeddedQuestion?.options.map(\.label) == ["続ける", "やめる"])
    }

    @Test func AskUserQuestionの複数の問いを全て取り出す() {
        // 1問目だけ取り出すと、2問目以降がノッチに出ないまま終わってしまう
        let data = payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "1問目", "options": [["label": "A"], ["label": "B"]]],
                ["question": "2問目",
                 "multiSelect": true,
                 "options": [["label": "C"], ["label": "D"]]],
            ]],
        ])
        guard let event = HookEventDecoder.decode(data) else {
            Issue.record("解釈できなかった"); return
        }
        #expect(event.embeddedQuestions.count == 2)
        #expect(event.embeddedQuestions.map(\.title) == ["1問目", "2問目"])
        #expect(event.embeddedQuestions[1].isMultiSelect)
        // 先頭を返す互換プロパティは1問目を指したまま
        #expect(event.embeddedQuestion?.title == "1問目")
    }

    @Test func 各イベントが状態に対応する() {
        #expect(HookEventKind.stop.resultingState == .completed)
        #expect(HookEventKind.stopFailure.resultingState == .completed)
        #expect(HookEventKind.notification.resultingState == .thinking)
        #expect(HookEventKind.preToolUse.resultingState == .thinking)
        // ブロックするのは権限リクエストだけ
        #expect(!HookEventKind.stop.isBlocking)
        #expect(!HookEventKind.notification.isBlocking)
    }

    @Test func イベント名の表記ゆれを吸収する() {
        // CodexのようにスネークケースでもPascalCaseでも解釈できること
        #expect(HookEventKind(normalizing: "PermissionRequest") == .permissionRequest)
        #expect(HookEventKind(normalizing: "permission_request") == .permissionRequest)
        #expect(HookEventKind(normalizing: "subagent_stop") == .subagentStop)
        #expect(HookEventKind(normalizing: "STOP") == .stop)
    }

    @Test func イベント名のキーが違っても解釈する() {
        let alternative = payload(["hookEventName": "Stop", "session_id": "s"])
        #expect(HookEventDecoder.decode(alternative)?.kind == .stop)
    }

    @Test func サブエージェント終了では完了扱いにしない() {
        // 親エージェントはまだ作業中のため、通知を出してはいけない
        #expect(HookEventKind.subagentStop.resultingState == .thinking)
    }

    @Test func 未知のイベント名は解釈しない() {
        let data = payload(["hook_event_name": "SomethingNew", "session_id": "x"])
        #expect(HookEventDecoder.decode(data) == nil)
    }

    @Test func 壊れたJSONは解釈しない() {
        #expect(HookEventDecoder.decode(Data("これはJSONではない".utf8)) == nil)
        #expect(HookEventDecoder.decode(Data()) == nil)
    }

    @Test func 長すぎる要約は切り詰める() {
        let long = String(repeating: "a", count: 300)
        let summary = HookEventDecoder.summarize(toolInput: ["command": long], maxLength: 50)
        #expect(summary?.count == 51)   // 50文字 + 省略記号
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test func 判定JSONを生成する() {
        #expect(HookDecision.passthrough.json == "{}")

        let allowData = Data(HookDecision.allow.json.utf8)
        let allowRoot = try? JSONSerialization.jsonObject(with: allowData) as? [String: Any]
        let allowOutput = allowRoot?["hookSpecificOutput"] as? [String: Any]
        let allowDecision = allowOutput?["decision"] as? [String: Any]
        #expect(allowDecision?["behavior"] as? String == "allow")
        #expect(allowOutput?["permissionDecision"] == nil)

        let denyData = Data(HookDecision.deny(reason: "危険").json.utf8)
        let denyRoot = try? JSONSerialization.jsonObject(with: denyData) as? [String: Any]
        let denyOutput = denyRoot?["hookSpecificOutput"] as? [String: Any]
        let denyDecision = denyOutput?["decision"] as? [String: Any]
        #expect(denyDecision?["behavior"] as? String == "deny")
        #expect(denyDecision?["message"] as? String == "危険")
    }
}

struct HookInstallerTests {

    @Test func フックを追記しても既存設定を壊さない() {
        let original: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/other-tool"]]]]],
        ]
        let patched = HookInstaller.addHooks(to: original, scriptPath: "/tmp/subghost-bridge")

        #expect(patched["model"] as? String == "opus")
        // 他ツールのフックが残っている
        let stop = patched["hooks"] as? [String: Any]
        let stopEntries = stop?["Stop"] as? [[String: Any]]
        #expect(stopEntries?.count == 2)
        #expect(String(describing: patched).contains("other-tool"))
        #expect(HookInstaller.containsMarker(in: patched))
    }

    @Test func 二重登録しない() {
        var root: [String: Any] = [:]
        root = HookInstaller.addHooks(to: root, scriptPath: "/tmp/subghost-bridge")
        root = HookInstaller.addHooks(to: root, scriptPath: "/tmp/subghost-bridge")

        let hooks = root["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
    }

    @Test func 解除すると自分の項目だけ消える() {
        let original: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/other-tool"]]]]],
        ]
        let patched = HookInstaller.addHooks(to: original, scriptPath: "/tmp/subghost-bridge")
        let cleaned = HookInstaller.removeHooks(from: patched)

        #expect(!HookInstaller.containsMarker(in: cleaned))
        #expect(String(describing: cleaned).contains("other-tool"))
        // Subghostだけが使っていたイベントはキーごと消える
        let hooks = cleaned["hooks"] as? [String: Any]
        #expect(hooks?["PermissionRequest"] == nil)
        #expect((hooks?["Stop"] as? [[String: Any]])?.count == 1)
    }

    @Test func CodexはCodex固有のイベントだけを登録する() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]

        #expect(hooks?["PermissionRequest"] == nil)
        #expect(hooks?["SubagentStop"] != nil)
        // CodexにはNotification / PreToolUse / SessionEnd が無い
        #expect(hooks?["Notification"] == nil)
        #expect(hooks?["PreToolUse"] == nil)
        #expect(hooks?["SessionEnd"] == nil)
        #expect(hooks?.count == HookTarget.codex.events.count)
    }

    @Test func CLIごとにsourceを渡し分ける() {
        // ブリッジは第1引数でどのCLI由来かを判別するため、渡し分けが必須
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "claude")
            .hasSuffix("subghost '/tmp/b' 'claude' '5' # subghost-bridge"))
        #expect(HookInstaller.hookCommand(scriptPath: "/tmp/b", source: "codex")
            .hasSuffix("subghost '/tmp/b' 'codex' '5' # subghost-bridge"))

        // 実際に登録されるコマンドにも反映されていること
        let codex = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = codex["hooks"] as? [String: Any]
        let inner = (hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect((inner?.first?["command"] as? String)?.contains("'codex'") == true)
    }

    @Test func パスに引用符が含まれてもコマンドが壊れない() {
        // ホームディレクトリ名にアポストロフィが入りうる。埋め込むと構文が壊れ、
        // 毎イベントでCLIがフックエラーを出すことになる。
        let command = HookInstaller.hookCommand(scriptPath: "/Users/o'brien/b", source: "claude")
        #expect(command.contains("'/Users/o'\\''brien/b'"))
        // 本文へは埋め込まず、引数として渡していること
        #expect(command.contains("[ -x \"$1\" ]"))
        #expect(!command.contains("[ -x \"/Users/"))
    }

    @Test func ブリッジへ渡す待ち時間は全イベントで短い() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .claude)
        let hooks = root["hooks"] as? [String: Any]

        func command(_ event: String) -> String? {
            let matchers = hooks?[event] as? [[String: Any]]
            let inner = matchers?.first?["hooks"] as? [[String: Any]]
            return inner?.first?["command"] as? String
        }
        #expect(command("PermissionRequest") == nil)
        #expect(command("SessionStart")?
            .contains("'\(HookInstaller.normalTimeoutSeconds)'") == true)
    }

    @Test func 形が違う既存フックは書き換えず残す() {
        // 想定外の形を空配列で置き換えると、ユーザーが自分で書いたフックを消してしまう
        let root: [String: Any] = ["hooks": ["SessionStart": "ユーザーが書いた想定外の値"]]
        let patched = HookInstaller.addHooks(to: root, scriptPath: "/tmp/b", target: .claude)
        let hooks = patched["hooks"] as? [String: Any]
        #expect(hooks?["SessionStart"] as? String == "ユーザーが書いた想定外の値")
        // 他のイベントには通常どおり追加されること
        #expect(hooks?["Stop"] != nil)
    }

    @Test func 既存のフックを残したまま追加する() {
        let root: [String: Any] = ["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": "echo ユーザーのフック"]]]],
        ]]
        let patched = HookInstaller.addHooks(to: root, scriptPath: "/tmp/b", target: .claude)
        let matchers = (patched["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        #expect(matchers?.count == 2)

        // 解除するとユーザーのフックだけが残る
        let cleaned = HookInstaller.removeHooks(from: patched)
        let remaining = (cleaned["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        let inner = remaining?.first?["hooks"] as? [[String: Any]]
        #expect(remaining?.count == 1)
        #expect(inner?.first?["command"] as? String == "echo ユーザーのフック")
    }

    @Test func 監視イベントは短いタイムアウトを設定する() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]

        func timeout(_ event: String) -> Int? {
            let matchers = hooks?[event] as? [[String: Any]]
            let inner = matchers?.first?["hooks"] as? [[String: Any]]
            return inner?.first?["timeout"] as? Int
        }
        #expect(timeout("PermissionRequest") == nil)
        #expect(timeout("Stop") == HookInstaller.normalTimeoutSeconds)
    }

    @Test func Codexのmatcherは空文字にする() {
        let root = HookInstaller.addHooks(to: [:], scriptPath: "/tmp/b", target: .codex)
        let hooks = root["hooks"] as? [String: Any]
        let postToolUse = (hooks?["PostToolUse"] as? [[String: Any]])?.first
        // Codexは空文字を全一致として扱う
        #expect(postToolUse?["matcher"] as? String == "")
        // matcherを取らないイベントには付けない
        let stop = (hooks?["Stop"] as? [[String: Any]])?.first
        #expect(stop?["matcher"] == nil)
    }

    @Test func 元がhooks無しなら解除後もhooks無しに戻る() {
        let patched = HookInstaller.addHooks(to: ["model": "opus"], scriptPath: "/tmp/b")
        let cleaned = HookInstaller.removeHooks(from: patched)
        #expect(cleaned["hooks"] == nil)
        #expect(cleaned["model"] as? String == "opus")
    }

    @Test func フックコマンドはスクリプトが無くても正常終了する形になっている() {
        let command = HookInstaller.hookCommand(scriptPath: "/tmp/subghost-bridge")
        // 存在確認と exit 0 が入っていること（CLIを壊さないための必須条件）
        #expect(command.contains("[ -x"))
        #expect(command.contains("exit 0"))
    }

    @Test func ブリッジスクリプトはソケットが無ければ即終了する() {
        let script = HookInstaller.bridgeScript(socketPath: "/tmp/x.sock")
        #expect(script.contains("[ -S \"$SOCK\" ] || exit 0"))
        #expect(script.contains("--unix-socket"))
    }
}

struct ConversationLocatorTests {

    @Test func lsofの出力から作業ディレクトリを取り出す() {
        let output = """
        p3514
        fcwd
        n/Users/Rhara/Create App/subghost
        """
        #expect(ConversationLocator.parseWorkingDirectory(output)
                == "/Users/Rhara/Create App/subghost")
    }

    @Test func パスでない行は無視する() {
        #expect(ConversationLocator.parseWorkingDirectory("p3514\nfcwd\n") == nil)
    }

    @Test func 作業ディレクトリをClaudeのプロジェクト名へ変換する() {
        // スラッシュと空白を "-" に置換する（実測の命名規則）
        #expect(ConversationLocator.claudeProjectDirName(cwd: "/Users/Rhara/Create App/subghost")
                == "-Users-Rhara-Create-App-subghost")
        #expect(ConversationLocator.claudeProjectDirName(cwd: "/tmp/x")
                == "-tmp-x")
    }
}

struct TranscriptReaderTests {

    /// 実際のセッション記録と同じ形
    private let jsonl = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"やって"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"どれから手をつけますか?","header":"次の作業","options":[{"label":"コミットする","description":"未コミットの変更を区切る"},{"label":"不具合を直す","description":"表示先の問題"},{"label":"検証する","description":"Codexで確認"}]}]}}]}}
    """

    @Test func 記録から質問と選択肢を復元する() {
        guard let choice = TranscriptReader.latestQuestion(inJSONLines: jsonl) else {
            Issue.record("復元できなかった"); return
        }
        #expect(choice.kind == .question)
        #expect(choice.title == "どれから手をつけますか?")
        #expect(choice.options.map(\.label) == ["コミットする", "不具合を直す", "検証する"])
        #expect(choice.options.map(\.keystroke) == ["1", "2", "3"])
    }

    @Test func 記録から応答本文を取り出す() {
        let text = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"やって"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"修正しました。\\n\\n\\nテストも通っています。"}]}}
        """
        let answer = TranscriptReader.latestAssistantText(inJSONLines: text)
        // ツール実行だけのレコードは飛ばし、本文を持つものを拾う
        #expect(answer.first == "修正しました。")
        #expect(answer.contains("テストも通っています。"))
        // 空行の連続は1行にまとめる
        #expect(answer.filter(\.isEmpty).count <= 1)
    }

    @Test func 本文が無ければ空を返す() {
        let toolOnly = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        """
        #expect(TranscriptReader.latestAssistantText(inJSONLines: toolOnly).isEmpty)
    }

    @Test func 長すぎる応答は行数を制限する() {
        let long = (1...200).map { "行\($0)" }.joined(separator: "\\n")
        let record = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"\(long)\"}]}}"
        let answer = TranscriptReader.latestAssistantText(inJSONLines: record)
        #expect(answer.count <= TranscriptReader.maxAnswerLines)
    }

    @Test func 回答済みの質問は復元しない() {
        // tool_use の後に、同じ tool_use_id の tool_result があれば回答済み
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"古い質問","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"回答しました"}]}}
        """
        #expect(TranscriptReader.latestQuestion(inJSONLines: jsonl) == nil)
    }

    @Test func 未回答の質問だけを返す() {
        // 古い質問は回答済み、新しい質問は未回答
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"古い質問","options":[{"label":"A"},{"label":"B"}]}]}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"回答済み"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q2","name":"AskUserQuestion","input":{"questions":[{"question":"新しい質問","options":[{"label":"はい"},{"label":"いいえ"}]}]}}]}}
        """
        let choice = TranscriptReader.latestQuestion(inJSONLines: jsonl)
        #expect(choice?.title == "新しい質問")
    }

    @Test func 質問が無ければnilを返す() {
        let plain = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"完了しました"}]}}
        """
        #expect(TranscriptReader.latestQuestion(inJSONLines: plain) == nil)
    }

    @Test func 選択肢が1つ以下なら質問とみなさない() {
        let input: [String: Any] = ["questions": [["question": "？", "options": [["label": "はい"]]]]]
        #expect(TranscriptReader.parseQuestion(input: input) == nil)
    }

    @Test func 壊れた行があっても他の行から復元する() {
        let broken = "これはJSONではない\n" + jsonl
        #expect(TranscriptReader.latestQuestion(inJSONLines: broken)?.options.count == 3)
    }

    @Test func 複数の問いを順番どおり全件取り出す() {
        // AskUserQuestion は複数の問いを1回にまとめる。1問目で打ち切らないこと。
        let input: [String: Any] = ["questions": [
            ["question": "1問目", "options": [["label": "A"], ["label": "B"]]],
            ["question": "2問目", "options": [["label": "C"], ["label": "D"]]],
            ["question": "3問目", "options": [["label": "E"], ["label": "F"]]],
        ]]
        let questions = TranscriptReader.parseQuestions(input: input)

        #expect(questions.map(\.title) == ["1問目", "2問目", "3問目"])
        #expect(questions.map(\.questionIndex) == [1, 2, 3])
        #expect(questions.allSatisfy { $0.questionCount == 3 })
        #expect(questions[1].progressLabel == "2 / 3")
    }

    @Test func 単一の問いには進捗表示を付けない() {
        let input: [String: Any] = ["questions": [
            ["question": "1問だけ", "options": [["label": "A"], ["label": "B"]]],
        ]]
        #expect(TranscriptReader.parseQuestions(input: input).first?.progressLabel == nil)
    }

    @Test func 複数選択の問いを見分けて確定キーを分ける() {
        let input: [String: Any] = ["questions": [
            ["question": "複数選べます",
             "multiSelect": true,
             "options": [["label": "A"], ["label": "B"], ["label": "C"]]],
        ]]
        guard let choice = TranscriptReader.parseQuestions(input: input).first else {
            Issue.record("解釈できなかった"); return
        }
        #expect(choice.isMultiSelect)
        // 複数選択では番号キーはトグルなので、選択肢ごとにEnterを送ってはいけない
        #expect(choice.options.allSatisfy { !$0.needsEnter })
    }

    @Test func 単一選択は番号のあとにEnterを送る() {
        let input: [String: Any] = ["questions": [
            ["question": "1つ選んでください", "options": [["label": "A"], ["label": "B"]]],
        ]]
        guard let choice = TranscriptReader.parseQuestions(input: input).first else {
            Issue.record("解釈できなかった"); return
        }
        #expect(!choice.isMultiSelect)
        #expect(choice.options.allSatisfy { $0.needsEnter })
    }

    @Test func 選択肢が1つ以下の問いだけ除いて残りを返す() {
        let input: [String: Any] = ["questions": [
            ["question": "不正", "options": [["label": "はい"]]],
            ["question": "正しい", "options": [["label": "A"], ["label": "B"]]],
        ]]
        // 除外しても、元の並びに基づく問番号は保つ
        let questions = TranscriptReader.parseQuestions(input: input)
        #expect(questions.map(\.title) == ["正しい"])
        #expect(questions.first?.questionIndex == 2)
    }
}

struct ShellIntegrationTests {

    @Test func 目印で囲んだブロックだけを取り除く() {
        let zshrc = """
        export PATH=/usr/bin
        \(ShellIntegration.beginMarker)
        [ -f "x" ] && . "x"
        \(ShellIntegration.endMarker)
        alias ll='ls -la'
        """
        let cleaned = ShellIntegration.removeBlock(from: zshrc)
        #expect(cleaned.contains("export PATH=/usr/bin"))
        #expect(cleaned.contains("alias ll='ls -la'"))
        // Subghostのブロックは消える
        #expect(!cleaned.contains("subghost"))
        #expect(!cleaned.contains("_subghost"))
    }

    @Test func 既存の内容を壊さない() {
        let original = "line1\nline2"
        let cleaned = ShellIntegration.removeBlock(from: original)
        #expect(cleaned.contains("line1"))
        #expect(cleaned.contains("line2"))
    }
}

struct UsageParserTests {

    private func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test func statuslineのJSONから使用量を取り出す() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let data = payload([
            "rate_limits": [
                "five_hour": ["used_percentage": 68, "resets_at": 1_000_000 + 48 * 60],
                "seven_day": ["used_percentage": 40.5,
                              "resets_at": 1_000_000 + 6 * 3600 + 48 * 60],
            ],
            "context_window": ["used_percentage": 40],
        ])
        guard let usage = UsageParser.parse(data, now: now) else {
            Issue.record("解析できなかった"); return
        }
        #expect(usage.fiveHour?.usedPercent == 68)
        #expect(usage.fiveHour?.remainingText(now: now) == "48m")
        #expect(usage.sevenDay?.remainingText(now: now) == "6h48m")
        #expect(usage.contextUsedPercent == 40)
    }

    @Test func ミリ秒のリセット時刻も解釈する() {
        // 秒とミリ秒は桁数で見分けるため、現実的な値（2026年相当）で確認する
        let base = 1_770_000_000.0
        let now = Date(timeIntervalSince1970: base)
        let data = payload(["rate_limits": [
            "five_hour": ["used_percentage": 10, "resets_at": (base + 600) * 1000],
        ]])
        #expect(UsageParser.parse(data, now: now)?.fiveHour?.remainingText(now: now) == "10m")
    }

    @Test func 秒のリセット時刻も解釈する() {
        let base = 1_770_000_000.0
        let now = Date(timeIntervalSince1970: base)
        let data = payload(["rate_limits": [
            "five_hour": ["used_percentage": 10, "resets_at": base + 600],
        ]])
        #expect(UsageParser.parse(data, now: now)?.fiveHour?.remainingText(now: now) == "10m")
    }

    @Test func Codexの記録からレート制限を取り出す() {
        // 実測の形式: event_msg の token_count に rate_limits が入る。
        // キーは used_percent、枠は window_minutes で判別する。
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1785069709},\
        "secondary":{"used_percent":42.0,"window_minutes":300,"resets_at":1785000000}}}}
        """
        guard let usage = UsageParser.parseCodexRateLimits(inJSONLines: jsonl) else {
            Issue.record("解析できなかった"); return
        }
        #expect(usage.agentID == "codex")
        // window_minutes で振り分ける（300分=5時間枠、10080分=7日枠）
        #expect(usage.fiveHour?.usedPercent == 42.0)
        #expect(usage.sevenDay?.usedPercent == 6.0)
    }

    @Test func Codexで片方の枠しか無くても取り出す() {
        // 実測データは primary のみで secondary が null だった
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1785069709},\
        "secondary":null}}}
        """
        let usage = UsageParser.parseCodexRateLimits(inJSONLines: jsonl)
        #expect(usage?.sevenDay?.usedPercent == 6.0)
        #expect(usage?.fiveHour == nil)
    }

    @Test func Codexのレート制限が無い記録では何も返さない() {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"agent_message","message":"やあ"}}
        """
        #expect(UsageParser.parseCodexRateLimits(inJSONLines: jsonl) == nil)
    }

    @Test func 使用量が無ければnilを返す() {
        #expect(UsageParser.parse(payload(["foo": "bar"])) == nil)
        #expect(UsageParser.parse(Data("壊れている".utf8)) == nil)
    }

    @Test func 一日以上残っていれば日で表す() {
        // 7日枠は「150h」のような表示になりやすく、日に直さないと読み取れない
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            usedPercent: 6,
            resetsAt: now.addingTimeInterval(TimeInterval(6 * 86_400 + 6 * 3600 + 30 * 60)))
        #expect(window.remainingText(now: now) == "6d6h")
    }

    @Test func 一日未満なら時分のまま表す() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(
            usedPercent: 6, resetsAt: now.addingTimeInterval(TimeInterval(23 * 3600 + 59 * 60)))
        #expect(window.remainingText(now: now) == "23h59m")
    }

    @Test func リセット済みなら残り時間を出さない() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = UsageWindow(usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 999_000))
        #expect(window.remainingText(now: now) == nil)
    }

    @Test func 消費率に応じて警戒度が変わる() {
        #expect(UsageWindow(usedPercent: 95, resetsAt: nil).isCritical)
        #expect(UsageWindow(usedPercent: 75, resetsAt: nil).isWarning)
        #expect(!UsageWindow(usedPercent: 30, resetsAt: nil).isWarning)
    }

    @Test func statuslineの包みは元のコマンドへ渡し直す() {
        let script = HookInstaller.statuslineScript(
            socketPath: "/tmp/s.sock", next: "bash /Users/me/.claude/statusline-command.sh")
        // 標準入力は一度しか読めないため、読み切ってから元のコマンドへ渡す
        #expect(script.contains("PAY=$(cat)"))
        #expect(script.contains("statusline-command.sh"))
        #expect(script.contains("/usage"))
    }

    @Test func 元のstatuslineが無ければ何も呼ばない() {
        let script = HookInstaller.statuslineScript(socketPath: "/tmp/s.sock", next: nil)
        #expect(!script.contains("NEXT="))
    }

    @Test func 元コマンドの引用符を安全に埋め込む() {
        // シングルクォートを含むコマンドでスクリプトが壊れないこと
        let script = HookInstaller.statuslineScript(
            socketPath: "/tmp/s.sock", next: "echo 'hello world'")
        #expect(script.contains("'\\''"))
    }

    @Test func statuslineは包みが消えても元のコマンドへ落ちる() {
        // ~/.subghost を手で消されても、settings.json だけで元へ戻れること。
        // パスをそのまま書くと、存在しないコマンドが残りstatuslineが死んだままになる。
        let command = HookInstaller.statuslineCommand(
            scriptPath: "/tmp/subghost-statusline", previous: "bash ~/.claude/statusline.sh")
        #expect(command.contains("[ -x \"$1\" ] && exec \"$1\""))
        #expect(command.contains("[ -n \"$2\" ] && exec /bin/sh -c \"$2\""))
        #expect(command.contains("exit 0"))
        #expect(command.hasSuffix("# \(HookInstaller.marker)"))
    }

    @Test func 元のstatuslineが無ければフォールバックも何もしない() {
        let command = HookInstaller.statuslineCommand(
            scriptPath: "/tmp/subghost-statusline", previous: nil)
        // 空文字なので [ -n "$2" ] が偽になり、そのまま exit 0 する
        #expect(command.contains("subghost '/tmp/subghost-statusline' ''"))
    }

    @Test func 埋め込んだ元コマンドを読み戻せる() {
        // 解除時に保存ファイルが失われていても、これがあれば元へ戻せる
        for original in ["bash ~/.claude/statusline.sh", "echo 'hello world'", "a\"b$c"] {
            let command = HookInstaller.statuslineCommand(
                scriptPath: "/tmp/s", previous: original)
            #expect(HookInstaller.embeddedPreviousStatusline(in: command) == original)
        }
    }

    @Test func 元コマンドが無い場合は読み戻しもnilになる() {
        let command = HookInstaller.statuslineCommand(scriptPath: "/tmp/s", previous: nil)
        #expect(HookInstaller.embeddedPreviousStatusline(in: command) == nil)
        // 目印の無い（ユーザー自身の）コマンドは対象外
        #expect(HookInstaller.embeddedPreviousStatusline(in: "bash statusline.sh") == nil)
    }

    @Test func 読み返せない設定は書き込まずに弾く() {
        // 壊れた settings.json はCLIの起動そのものを妨げる。書く前に必ず確かめる。
        // JSONSerialization.data はこの入力に対して Swift の error ではなく NSException を
        // 投げるため、事前に isValidJSONObject で弾かないとアプリごと落ちる。
        #expect(throws: HookInstallError.self) {
            // JSONにできない値（Date）が混じった設定
            try HookInstaller.encodedSettings(["statusLine": Date()], fileName: "settings.json")
        }
        // 正常な設定はそのまま読み返せること
        let data = try? HookInstaller.encodedSettings(
            HookInstaller.addHooks(to: ["model": "opus"], scriptPath: "/tmp/b"),
            fileName: "settings.json")
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        #expect(root?["model"] as? String == "opus")
        #expect(root?["hooks"] != nil)
    }

    @Test func 引用符を含む引数列を読み戻せる() {
        let quoted = ["a", "o'brien", "", "空白 と \"引用符\""]
            .map(HookInstaller.shellQuoted).joined(separator: " ")
        #expect(HookInstaller.singleQuotedArguments(in: quoted) == ["a", "o'brien", "", "空白 と \"引用符\""])
    }
}

struct HookRequestTests {

    @Test func ttyの表記ゆれを吸収する() {
        // ブリッジは "ttys003" 形式、セッション側は "/dev/ttys003" 形式で保持している。
        // 正規化しないと永久に一致せず、イベントが捨てられ続ける。
        #expect(HookRequest.normalizeTTY("ttys003") == "/dev/ttys003")
        #expect(HookRequest.normalizeTTY("/dev/ttys003") == "/dev/ttys003")
    }

    @Test func ttyが取れなかった場合はnilにする() {
        #expect(HookRequest.normalizeTTY("??") == nil)
        #expect(HookRequest.normalizeTTY("unknown") == nil)
        #expect(HookRequest.normalizeTTY("") == nil)
        #expect(HookRequest.normalizeTTY(nil) == nil)
    }

    @Test func ブリッジは祖先をたどってCLI本体を探す() {
        let script = HookInstaller.bridgeScript(socketPath: "/tmp/x.sock")
        // フックの親シェルは制御端末を持たないため、$PPIDだけでは特定できない
        #expect(script.contains("while"))
        #expect(script.contains("X-Subghost-Pid"))
        // ttyは/dev/付きで送る
        #expect(script.contains("/dev/$term"))
    }
}

struct HTTPParserTests {

    @Test func リクエストを解析する() {
        let raw = Data("""
        POST /hook?source=claude HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        X-Subghost-Tty: /dev/ttys004\r
        Content-Length: 13\r
        \r
        {"hello":"a"}
        """.utf8)

        guard let parsed = HTTPRequestParser.parse(raw) else {
            Issue.record("解析できなかった"); return
        }
        #expect(parsed.path == "/hook")
        #expect(parsed.query["source"] == "claude")
        #expect(parsed.headers["x-subghost-tty"] == "/dev/ttys004")
        #expect(String(decoding: parsed.body, as: UTF8.self) == "{\"hello\":\"a\"}")
    }

    @Test func ヘッダ終端が無ければ解析しない() {
        #expect(HTTPRequestParser.parse(Data("POST /hook HTTP/1.1".utf8)) == nil)
    }
}

// MARK: - ターミナルへの移動 (Jump)

struct TerminalJumpTests {

    @Test func Ghosttyのタイトルでセッションを照合する() {
        var info = SessionInfo(agent: DiscoveredAgent(
            pid: 1, tty: "/dev/ttys003", profile: .claude))
        info.hookSessionID = "dd7867b0-0cbc-4857-8ae6-e36e2fc2e292"
        info.workingDirectory = "/Users/me/Create App/subghost"

        // セッションIDの先頭が含まれれば一致
        #expect(TerminalActivator.titleMatches("チャット · dd7867b0-0cbc-48", session: info))
        // フォルダ名が含まれれば一致
        #expect(TerminalActivator.titleMatches("subghost — zsh", session: info))
        // どちらも含まれなければ不一致（別タブへの誤送信を防ぐ）
        #expect(!TerminalActivator.titleMatches("別のプロジェクト — vim", session: info))
    }

    @Test func 正常なttyパスを受け入れる() {
        #expect(TerminalActivator.isValidTTY("/dev/ttys004"))
        #expect(TerminalActivator.isValidTTY("/dev/ttys000"))
    }

    @Test func 不正なttyパスを弾く() {
        // AppleScriptへ埋め込むため、引用符やスペースを含むものは通さない
        #expect(!TerminalActivator.isValidTTY("/dev/ttys004\" & do shell script \"echo"))
        #expect(!TerminalActivator.isValidTTY("/dev/tty s004"))
        #expect(!TerminalActivator.isValidTTY("ttys004"))
        #expect(!TerminalActivator.isValidTTY(""))
        #expect(!TerminalActivator.isValidTTY("/dev/" + String(repeating: "a", count: 40)))
    }

    @Test func psの出力から親子関係を読む() {
        let output = """
          501     1
          610   501
          742   610
        """
        let parents = ProcessTree.parseParentMap(output)
        #expect(parents[501] == 1)
        #expect(parents[610] == 501)
        #expect(parents[742] == 610)
    }

    @Test func psの出力からpidを読む() {
        #expect(ProcessTree.parsePIDs("  610\n  742\n") == [610, 742])
        #expect(ProcessTree.parsePIDs("") == [])
    }

    @Test func 祖先をたどってターミナルを特定する() {
        // 742(tmuxクライアント) → 610(シェル) → 501(ターミナル.app)
        let parents: [Int32: Int32] = [742: 610, 610: 501, 501: 1]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 742, in: terminals, parents: parents) == .terminal)
    }

    @Test func 祖先にターミナルがなければnilを返す() {
        let parents: [Int32: Int32] = [742: 610, 610: 1]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 742, in: terminals, parents: parents) == nil)
    }

    @Test func 親子関係が循環していても停止する() {
        // 異常系: 相互に親を指し合っていても無限ループにしない
        let parents: [Int32: Int32] = [10: 11, 11: 10]
        let terminals: [Int32: TerminalApp] = [501: .terminal]

        #expect(ProcessTree.findAncestor(of: 10, in: terminals, parents: parents) == nil)
    }

    @Test func タブ単位で移動できるのはターミナルappのみ() {
        #expect(TerminalApp.terminal.supportsTabJump)
        #expect(!TerminalApp.ghostty.supportsTabJump)
    }

    @Test func エディタの内蔵ターミナルもヘルパー経由で特定できる() {
        // 実測値: 36186(tmux) → 34224(zsh) → 16536(Code Helper) → 16270(VS Code)
        // 内蔵ターミナルのシェルはヘルパープロセスの子であり、本体は祖先にしか現れない
        let parents: [Int32: Int32] = [36186: 34224, 34224: 16536, 16536: 16270, 16270: 1]
        let terminals: [Int32: TerminalApp] = [16270: .vscode]

        #expect(ProcessTree.findAncestor(of: 36186, in: terminals, parents: parents) == .vscode)
    }

    @Test func エディタは移動先ターミナルとして起動しない() {
        // 内蔵ターミナルは「セッションの所在」を示すだけで、単独の移動先にはならない
        #expect(TerminalApp.terminal.isLaunchable)
        #expect(TerminalApp.ghostty.isLaunchable)
        #expect(!TerminalApp.vscode.isLaunchable)
        #expect(!TerminalApp.cursor.isLaunchable)
        #expect(!TerminalApp.windsurf.isLaunchable)
    }
}

// MARK: - 承認/質問の検出 (Approve / Ask)

struct ChoicePromptTests {

    /// Claude Codeの権限リクエストを模したcapture-pane出力
    private let approvalScreen = """
    ● foo.swift を編集します

    ╭──────────────────────────────────────────────╮
    │ Edit file                                    │
    │                                              │
    │ Do you want to make this edit to foo.swift?  │
    │ ❯ 1. Yes                                     │
    │   2. Yes, allow all edits this session       │
    │   3. No, and tell Claude what to do (esc)    │
    ╰──────────────────────────────────────────────╯
      ? for shortcuts
    """

    @Test func 権限リクエストを承認リクエストとして検出する() {
        guard let choice = ChoicePrompt.detect(in: approvalScreen, profile: .claude) else {
            Issue.record("選択肢を検出できなかった")
            return
        }
        #expect(choice.kind == .approval)
        #expect(choice.title == "Do you want to make this edit to foo.swift?")
        #expect(choice.options.map(\.label) == [
            "今回だけ許可", "このセッション中は許可", "拒否する",
        ])
        #expect(choice.options.map(\.keystroke) == ["1", "2", "3"])
        #expect(choice.options.map(\.screenLabel) == [
            "Yes", "Yes, allow all edits this session", "No, and tell Claude what to do (esc)",
        ])
        #expect(choice.options[0].isAffirmative)
        #expect(choice.options[1].isAffirmative)
        #expect(choice.options[2].isNegative)
        #expect(choice.options.allSatisfy { !$0.needsEnter })
    }

    @Test func Codex固有の承認項目を省略せず実際の番号を保つ() {
        let codexApprovalScreen = """
        Would you like to run this command?
        ❯ 1. Yes, proceed
          2. Yes, and don't ask again for commands that start with `git status`
          3. No, and tell Codex what to do differently
        """
        guard let choice = ChoicePrompt.detect(in: codexApprovalScreen, profile: .codex) else {
            Issue.record("Codexの承認項目を検出できなかった")
            return
        }
        #expect(choice.kind == .approval)
        #expect(choice.options.map(\.label) == [
            "今回だけ許可", "今後この種類の操作を許可", "拒否する",
        ])
        #expect(choice.options.map(\.keystroke) == ["1", "2", "3"])
        #expect(choice.options.map(\.screenLabel) == [
            "Yes, proceed",
            "Yes, and don't ask again for commands that start with `git status`",
            "No, and tell Codex what to do differently",
        ])
    }

    @Test func Codexの補足情報付き承認画面から実際の三つのキーを取得する() {
        let screen = """
        Would you like to run the following command?

        Environment: local

        Reason: Subghostの承認項目をテストします

        $ date

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `date` (p)
          3. No, and tell Codex what to do differently (esc)
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .codex) else {
            Issue.record("Codexの補足情報付き承認画面を検出できなかった")
            return
        }
        // PermissionRequest Hook側ではこの実キーを使うため、画面分類の種類には依存しない。
        #expect(choice.options.map(\.keystroke) == ["1", "2", "3"])
        #expect(choice.options.map(\.screenLabel) == [
            "Yes, proceed (y)",
            "Yes, and don't ask again for commands that start with `date` (p)",
            "No, and tell Codex what to do differently (esc)",
        ])
    }

    @Test func 承認以外の問いかけは質問として分類する() {
        let screen = """
        どの方針で進めますか?
        ❯ 1. 既存の実装を拡張する
          2. 新しく書き直す
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .claude) else {
            Issue.record("選択肢を検出できなかった")
            return
        }
        #expect(choice.kind == .question)
        #expect(choice.options.count == 2)
    }

    @Test func yn形式のプロンプトを検出する() {
        let screen = """
        既存のファイルを上書きします
        Do you want to continue? (y/n)
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .codex) else {
            Issue.record("y/n形式を検出できなかった")
            return
        }
        #expect(choice.kind == .approval)
        #expect(choice.options.map(\.label) == ["今回だけ許可", "拒否する"])
        #expect(choice.options.map(\.keystroke) == ["y", "n"])
        // y/n形式は入力確定にEnterが必要
        #expect(choice.options.allSatisfy { $0.needsEnter })
    }

    @Test func 通常の応答画面では選択肢を検出しない() {
        let screen = """
        処理が完了しました。変更点は以下です。
        - foo.swift を修正
        - bar.swift を追加
        ╭────────────╮
        │ >          │
        ╰────────────╯
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    @Test func 番号が1から始まらない列挙は選択肢とみなさない() {
        let screen = """
        参考:
        2. 二番目の項目
        3. 三番目の項目
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    /// 実際に起きた不具合の再現: 説明文中の番号付き箇条書き（項目ごとの説明行を挟まない
    /// 単純な連番）が、会話が先へ進んだ後も画面に残っていると選択待ちと誤検出されていた。
    /// (Subghost起動直後、フックがまだ繋がっていない一瞬に画面解析が走ると
    /// この文面を拾ってしまい、選んだつもりが数字だけ誤送信される不具合につながっていた)
    @Test func 説明文中の番号付き箇条書きを選択待ちと誤認しない() {
        let screen = """
        状況をまとめます.

        1. 複数選択のトグルは正しく動作しています
        2. Submit直後に確認画面が挟まることが分かりました
        3. 確認画面では改めて1を送る必要があります

        修正を実装します.
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) == nil)
    }

    @Test func ヒント行だけで終わる生きたメニューは引き続き検出する() {
        // 選択肢の後に操作ヒントだけがあり、それ以降に何も続かない（＝画面の最後）なら生きている
        let screen = """
        【複数選択の検証】

        ❯ 1. [ ] 項目A
          2. [ ] 項目B
             Submit

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        guard let choice = ChoicePrompt.detect(in: screen, profile: .claude) else {
            Issue.record("生きたメニューを検出できなかった")
            return
        }
        #expect(choice.options.count == 2)
    }

    @Test func 選択肢の直後で画面が終わっていれば生きていると判定する() {
        // ヒント行すら無く、選択肢の直後で画面がそのまま終わる（＝末尾）なら生きている
        let screen = """
        どちらにしますか?
        ❯ 1. こちら
          2. あちら
        """
        #expect(ChoicePrompt.detect(in: screen, profile: .claude) != nil)
    }

    // MARK: - 送信直前の再照合（フールプルーフ）

    @Test func 選択肢のラベルが画面に残っていれば送信前照合を通す() {
        let paneText = """
        ❯ 1. [ ] 項目A
          2. [✔] 項目B
             Submit
        """
        #expect(ChoicePrompt.matchesCurrentScreen(optionLabels: ["項目A", "項目B"], in: paneText))
    }

    @Test func 画面が先へ進んでいれば送信前照合を弾く() {
        // 表示から回答までの間に会話が進み、選択肢のラベルがもう画面に無い場合
        let paneText = """
        修正を実装しました. 次の作業に移ります.
        """
        #expect(!ChoicePrompt.matchesCurrentScreen(optionLabels: ["項目A", "項目B"], in: paneText))
    }

    @Test func 選択肢が空なら送信前照合を通さない() {
        #expect(!ChoicePrompt.matchesCurrentScreen(optionLabels: [], in: "何かの画面"))
    }

    @Test func 画面幅で折り返された長いラベルでも送信前照合を通す() {
        // 実機で確認した不具合: 長いラベルはターミナルの画面幅で複数行に折り返され、
        // 日本語は単語境界と無関係に任意の文字位置で改行されるため、
        // 改行を挟んだ状態のままだと単純な contains では一致しなくなっていた。
        let longLabel = "非常に長い説明文が付いた選択肢を含むパターンで、ノッチ側で折り返しや省略がどう表示されるかを見たいケース"
        let paneText = """
        ❯ 2. 非常に長い説明文が付いた選択肢を含むパターンで、ノッチ側で折
             り返しや省略がどう表示されるかを見たいケース
             Submit
        """
        #expect(ChoicePrompt.matchesCurrentScreen(optionLabels: [longLabel], in: paneText))
    }
}

// MARK: - 起動時に既存セッションの状態を引き継ぐ

struct InitialAdoptionTests {

    @Test func 起動前から承認待ちで止まっているセッションを拾う() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        // 初回の取り込みは候補として保持するだけで、まだ確定しない
        // (フールプルーフ: 起動直後の一瞬は誤検出のリスクが最も高いため、
        // 1回見ただけでは確定させず、次のポーリングでの再確認を待つ)
        let first = detector.adoptCurrentState(rawText: screen, at: t0)
        #expect(first == .none)

        // 次のポーリングでも同じ内容が見えて初めて確定する
        let event = detector.ingest(rawText: screen, at: t0.addingTimeInterval(1))
        guard case .becameAwaitingChoice(let choice) = event else {
            Issue.record("承認待ちを拾えなかった: \(event)")
            return
        }
        #expect(detector.state == .awaitingApproval)
        #expect(choice.options.count == 2)
    }

    @Test func 起動直後の候補が次のポーリングで消えていれば確定しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        _ = detector.adoptCurrentState(rawText: screen, at: t0)

        // 次のポーリングで別の画面（選択メニューではない）に変わっていれば、
        // 一過性の誤検出だったとみなして確定しない
        _ = detector.ingest(rawText: "通常の会話が続いています", at: t0.addingTimeInterval(1))
        #expect(detector.state != .awaitingApproval)
        #expect(detector.state != .awaitingAnswer)
        #expect(detector.pendingChoice == nil)
    }

    @Test func 起動時に生成中なら生成中として引き継ぐ() {
        var detector = StateDetector(profile: .claude)
        let screen = "✻ Thinking… (esc to interrupt)"
        let event = detector.adoptCurrentState(rawText: screen, at: Date(timeIntervalSince1970: 0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
    }

    @Test func 起動前に完了していた応答で完了通知を出さない() {
        var detector = StateDetector(profile: .claude)
        let screen = """
        処理が完了しました。
        ╭────────────╮
        │ >          │
        ╰────────────╯
        """
        // 起動前に終わっていた作業を「今完了した」と誤報してはいけない
        let event = detector.adoptCurrentState(rawText: screen, at: Date(timeIntervalSince1970: 0))
        #expect(event == .none)
        #expect(detector.state == .idle)
    }

    @Test func 引き継ぎ後は通常の差分判定に戻る() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(detector.needsInitialAdoption)

        _ = detector.adoptCurrentState(rawText: "待機中の画面", at: t0)
        #expect(!detector.needsInitialAdoption)

        // 以降は出力の伸長で生成中になる
        let event = detector.ingest(rawText: "待機中の画面\n新しい出力", at: t0.addingTimeInterval(1))
        #expect(event == .becameThinking)
    }

    @Test func 引き継ぎ直後に同じ承認画面でも二重通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        let screen = """
        Do you want to run this command?
        ❯ 1. Yes
          2. No
        """
        _ = detector.adoptCurrentState(rawText: screen, at: t0)
        // 次のポーリングで候補が確定する
        _ = detector.ingest(rawText: screen, at: t0.addingTimeInterval(1))
        #expect(detector.state == .awaitingApproval)

        // 確定後、同じ画面が続いても二重通知しない
        let repeated = detector.ingest(rawText: screen, at: t0.addingTimeInterval(2))
        #expect(repeated == .none)
        #expect(detector.state == .awaitingApproval)
    }
}

struct ChoiceStateTests {

    private let approvalScreen = """
    Do you want to run this command?
    ❯ 1. Yes
      2. No
    """

    @Test func 選択待ちを検出したらawaitingApprovalへ遷移する() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)

        let event = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))
        guard case .becameAwaitingChoice(let choice) = event else {
            Issue.record("承認待ちにならなかった: \(event)")
            return
        }
        #expect(detector.state == .awaitingApproval)
        #expect(choice.options.count == 2)
    }

    @Test func 同じ選択肢が出続けても再通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        let repeated = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(2))
        #expect(repeated == .none)
        #expect(detector.state == .awaitingApproval)
    }

    @Test func 選択待ちの間はcompletedと判定しない() {
        var detector = StateDetector(profile: .claude)
        detector.stableInterval = 1.5
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        // 静止時間が十分経過してもcompletedにはしない
        let later = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(30))
        #expect(later == .none)
        #expect(detector.state == .awaitingApproval)
    }

    @Test func ターミナル側で回答されたら選択待ちが解消する() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        let resolved = detector.ingest(rawText: "コマンドを実行しています…", at: t0.addingTimeInterval(2))
        #expect(resolved == .choiceResolved)
        #expect(detector.state == .thinking)
        #expect(detector.pendingChoice == nil)
    }

    @Test func ノッチから回答した直後は同じ選択肢を再通知しない() {
        var detector = StateDetector(profile: .claude)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "作業中の画面", at: t0)
        _ = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(1))

        // 回答を送信（画面はまだ更新されていない）
        _ = detector.noteUserAnsweredChoice(at: t0.addingTimeInterval(2))
        let afterAnswer = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(2.5))
        #expect(afterAnswer == .none)
        #expect(detector.state == .thinking)

        // 抑制時間を過ぎてもまだ同じ画面なら、答えが届いていないので再通知する
        let renotified = detector.ingest(rawText: approvalScreen, at: t0.addingTimeInterval(10))
        guard case .becameAwaitingChoice = renotified else {
            Issue.record("抑制時間経過後に再通知されなかった: \(renotified)")
            return
        }
    }
}

// MARK: - タスク完了後のスリープ

/// スリープは取り消せず、しかも席を外している前提で起きる。
/// 「寝てよい」と判断する条件はここで固定値のまま網羅しておく。
struct SleepConditionTests {

    private func セッション(
        tty: String = "/dev/ttys001",
        pid: Int32 = 100,
        profileID: String = "claude",
        state: AIState
    ) -> SleepSessionSnapshot {
        SleepSessionSnapshot(tty: tty, pid: pid, profileID: profileID, state: state)
    }

    @Test func 予約したCLIの完了でスリープへ進む() {
        let finished = セッション(state: .completed)
        #expect(SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: finished,
            sessions: [finished],
            includesError: true
        ))
    }

    @Test func 予約していないCLIの完了では進まない() {
        let finished = セッション(profileID: "codex", state: .completed)
        #expect(!SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: finished,
            sessions: [finished],
            includesError: true
        ))
    }

    /// 同じCLIをタブ違いで並行して使っている場合、まだ動いている方が本命かもしれない
    @Test func 同じCLIの別セッションが作業中なら進まない() {
        let finished = セッション(state: .completed)
        let working = セッション(tty: "/dev/ttys002", pid: 200, state: .thinking)
        #expect(!SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: finished,
            sessions: [finished, working],
            includesError: true
        ))
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")], sessions: [finished, working]) == .targetBusy)
    }

    /// 答えるまでCLIは止まったまま。そこで寝ると、戻ってきても何も進んでいない。
    @Test func 予約の対象外でも回答待ちがあれば進まない() {
        let finished = セッション(state: .completed)
        let waiting = セッション(
            tty: "/dev/ttys003", pid: 300, profileID: "codex", state: .awaitingApproval)
        #expect(!SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: finished,
            sessions: [finished, waiting],
            includesError: true
        ))
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")], sessions: [finished, waiting]) == .awaitingResponse)
    }

    @Test func 質問待ちも回答待ちとして扱う() {
        let finished = セッション(state: .completed)
        let asking = セッション(tty: "/dev/ttys004", pid: 400, state: .awaitingAnswer)
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")], sessions: [finished, asking]) == .awaitingResponse)
    }

    @Test func エラー終了を終了に含めるかは設定で決まる() {
        let failed = セッション(state: .error)
        #expect(SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: failed,
            sessions: [failed],
            includesError: true
        ))
        #expect(!SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude")],
            finished: failed,
            sessions: [failed],
            includesError: false
        ))
    }

    /// 予約した直後、何も動いていないだけで寝てしまってはいけない
    @Test func 待機中や生成中は終了とみなさない() {
        #expect(!SleepCondition.isFinished(.idle, includesError: true))
        #expect(!SleepCondition.isFinished(.thinking, includesError: true))
        #expect(!SleepCondition.isFinished(.awaitingApproval, includesError: true))
        #expect(!SleepCondition.isFinished(.awaitingAnswer, includesError: true))
        #expect(SleepCondition.isFinished(.completed, includesError: false))
    }

    @Test func 対象のセッションが見当たらなければ待たせる() {
        let other = セッション(profileID: "codex", state: .idle)
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")], sessions: [other]) == .targetMissing)
        #expect(SleepCondition.hold(
            targets: [.agent(profileID: "claude")], sessions: []) == .targetMissing)
    }

    /// ttyは使い回されるため、PIDまで一致しなければ別のセッション
    @Test func セッション指定はPIDまで一致しないと対象外() {
        let session = セッション(state: .completed)
        #expect(SleepCondition.covers(.session(tty: "/dev/ttys001", pid: 100), session))
        #expect(!SleepCondition.covers(.session(tty: "/dev/ttys001", pid: 999), session))
        #expect(!SleepCondition.covers(.session(tty: "/dev/ttys009", pid: 100), session))
    }

    @Test func セッション指定では他のセッションの作業中は妨げにならない() {
        let finished = セッション(state: .completed)
        let otherWorking = セッション(tty: "/dev/ttys002", pid: 200, state: .thinking)
        #expect(SleepCondition.shouldStartCountdown(
            targets: [.session(tty: "/dev/ttys001", pid: 100)],
            finished: finished,
            sessions: [finished, otherWorking],
            includesError: true
        ))
    }

    /// 複数を予約したときは「最後の1つが終わるまで待つ」
    @Test func 複数予約では片方が残っている間は進まない() {
        let claudeDone = セッション(state: .completed)
        let codexWorking = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .thinking)
        let targets: [SleepTarget] = [.agent(profileID: "claude"), .agent(profileID: "codex")]

        #expect(!SleepCondition.shouldStartCountdown(
            targets: targets,
            finished: claudeDone,
            sessions: [claudeDone, codexWorking],
            includesError: true
        ))
        #expect(SleepCondition.hold(
            targets: targets, sessions: [claudeDone, codexWorking]) == .targetBusy)
    }

    @Test func 複数予約は最後の1つが終わった時点で進む() {
        let claudeDone = セッション(state: .completed)
        let codexDone = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .completed)

        #expect(SleepCondition.shouldStartCountdown(
            targets: [.agent(profileID: "claude"), .agent(profileID: "codex")],
            finished: codexDone,
            sessions: [claudeDone, codexDone],
            includesError: true
        ))
    }

    /// 消えた予約を数え続けると、残りが終わっても永久に寝られなくなる
    @Test func 対象が消えた予約は判断から外す() {
        let claudeDone = セッション(state: .completed)
        let targets: [SleepTarget] = [.agent(profileID: "claude"), .agent(profileID: "codex")]

        #expect(SleepCondition.liveTargets(targets, sessions: [claudeDone])
                == [.agent(profileID: "claude")])
        #expect(SleepCondition.hold(targets: targets, sessions: [claudeDone]) == .none)
        // ただし1つも残っていなければ、狙う相手がいないので進めない
        #expect(SleepCondition.hold(targets: targets, sessions: []) == .targetMissing)
    }

    @Test func 猶予秒数を安全な範囲へ補正する() {
        #expect(SleepPreferences.normalizedCountdown(0) == 5)
        #expect(SleepPreferences.normalizedCountdown(30) == 30)
        #expect(SleepPreferences.normalizedCountdown(10_000) == 300)
    }
}

/// 猶予の消化とスリープの実行。
/// 実際に寝かせるわけにはいかないので、実行は差し替え、時間は tick() で手動に進める。
@MainActor
final class SleepTestProbe {
    /// スリープを実行した回数
    var sleepCount = 0
    /// 判定へ渡すセッション一覧（テストの途中で差し替える）
    var sessions: [SleepSessionSnapshot] = []
    /// ノッチで入力中か
    var isInteracting = false
}

@MainActor
struct SleepSchedulerTests {

    private func セッション(
        tty: String = "/dev/ttys001",
        pid: Int32 = 100,
        profileID: String = "claude",
        state: AIState
    ) -> SleepSessionSnapshot {
        SleepSessionSnapshot(tty: tty, pid: pid, profileID: profileID, state: state)
    }

    private func 用意する(_ sessions: [SleepSessionSnapshot]) -> (SleepScheduler, SleepTestProbe) {
        let probe = SleepTestProbe()
        probe.sessions = sessions
        let scheduler = SleepScheduler()
        scheduler.automaticTicking = false
        scheduler.sessionsProvider = { probe.sessions }
        scheduler.isUserInteracting = { probe.isInteracting }
        scheduler.sleepAction = { probe.sleepCount += 1 }
        return (scheduler, probe)
    }

    /// 猶予ぶん進めるのに要する回数（設定値に追随させる）
    private var 猶予の秒数: Int { Int(SleepPreferences.countdown) }

    @Test func 猶予を数え終えたらスリープする() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown != nil)

        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
        #expect(scheduler.countdown == nil)
        // 既定では1回で予約を解除する
        #expect(!scheduler.isReserved)
    }

    @Test func 予約していなければ完了しても何も起きない() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown == nil)
        #expect(probe.sleepCount == 0)
    }

    /// 目の前で入力している最中に寝るのは明らかな誤り
    @Test func ノッチへ入力中は猶予を数えない() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)

        probe.isInteracting = true
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 0)
        #expect(scheduler.countdown?.pausedByUser == true)
        #expect(scheduler.countdown?.remaining == SleepPreferences.countdown)

        // 入力を終えれば、その続きから数え直す
        probe.isInteracting = false
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
    }

    /// 猶予の途中で承認待ちが現れたら、答えるまで寝てはいけない
    @Test func 途中で回答待ちが現れたら猶予を止める() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)

        probe.sessions = [
            finished,
            セッション(tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .awaitingApproval),
        ]
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 0)
        #expect(scheduler.countdown?.hold == .awaitingResponse)

        // 回答が済めば残りを数え直して寝る
        probe.sessions = [finished]
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
    }

    /// 取り消しても予約は残す。次に完了したときは改めて確認する。
    @Test func 猶予の取り消しでは予約が残る() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.noteFinished(finished)
        scheduler.cancelCountdown(message: nil)

        #expect(scheduler.countdown == nil)
        #expect(scheduler.isReserved)
        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 0)

        // 次の完了で改めて猶予に入る
        scheduler.noteFinished(finished)
        #expect(scheduler.countdown != nil)
    }

    /// 複数のCLIを予約したときは、最後の1つが終わってから寝る
    @Test func 複数予約は最後の1つが終わるまでスリープしない() async {
        let claudeDone = セッション(state: .completed)
        let codexWorking = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .thinking)
        let (scheduler, probe) = 用意する([claudeDone, codexWorking])
        scheduler.reserve(.agent(profileID: "claude"), label: "Claude Code")
        scheduler.reserve(.agent(profileID: "codex"), label: "Codex CLI")

        // Claudeが終わってもCodexが動いている間は猶予にすら入らない
        scheduler.noteFinished(claudeDone)
        #expect(scheduler.countdown == nil)

        let codexDone = セッション(
            tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .completed)
        probe.sessions = [claudeDone, codexDone]
        scheduler.noteFinished(codexDone)
        #expect(scheduler.countdown?.targetCount == 2)

        for _ in 0..<猶予の秒数 { await scheduler.tick() }
        #expect(probe.sleepCount == 1)
    }

    /// 予約の途中で片方のCLIが終了しても、残りを待ち続ける
    @Test func 片方のセッションが終了しても残りの予約は待ち続ける() async {
        let claude = セッション(state: .completed)
        let codex = セッション(tty: "/dev/ttys002", pid: 200, profileID: "codex", state: .thinking)
        let (scheduler, probe) = 用意する([claude, codex])
        scheduler.reserve(.session(tty: "/dev/ttys001", pid: 100), label: "Claude Code（a）")
        scheduler.reserve(.session(tty: "/dev/ttys002", pid: 200), label: "Codex CLI（b）")

        probe.sessions = [codex]   // Claude側のCLIが終了した
        await scheduler.tick()

        #expect(scheduler.reservations.count == 1)
        #expect(scheduler.isReservedSession(tty: "/dev/ttys002", pid: 200))
        #expect(probe.sleepCount == 0)
    }

    /// 対象のCLIが終了してしまったら、狙う相手がいない。黙って残さず解除する。
    @Test func セッション指定の対象が消えたら予約を解除する() async {
        let finished = セッション(state: .completed)
        let (scheduler, probe) = 用意する([finished])
        scheduler.reserve(.session(tty: "/dev/ttys001", pid: 100), label: "Claude Code")

        probe.sessions = []
        await scheduler.tick()
        #expect(!scheduler.isReserved)
        #expect(scheduler.statusMessage != nil)
        #expect(probe.sleepCount == 0)
    }
}
