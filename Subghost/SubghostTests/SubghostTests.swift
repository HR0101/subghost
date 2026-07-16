//
//  SubghostTests.swift
//  SubghostTests
//
//  状態判定ロジック（設計書 5）のユニットテスト
//

import Foundation
import Testing
@testable import Subghost

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

    @Test func プロンプト送信でthinkingへ遷移する() {
        var detector = makeDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.ingest(rawText: "A", at: t0)
        let event = detector.noteUserSentPrompt(at: t0.addingTimeInterval(1.0))
        #expect(event == .becameThinking)
        #expect(detector.state == .thinking)
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

    @Test func sanitizeは改行を空白にし制御文字を除去する() {
        let input = "行1\n行2\r\n行3\t終わり\u{1B}[31m"
        let output = TmuxClient.sanitize(input)
        #expect(!output.contains("\n"))
        #expect(!output.contains("\u{1B}"))
        #expect(output.contains("行1"))
        #expect(output.contains("行2"))
    }

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

    @Test func セッション名からプロファイルを推定する() {
        #expect(CLIProfile.match(sessionName: "ai-claude").id == "claude")
        #expect(CLIProfile.match(sessionName: "ai-codex").id == "codex")
        #expect(CLIProfile.match(sessionName: "ai-antigravity").id == "antigravity")
    }
}
