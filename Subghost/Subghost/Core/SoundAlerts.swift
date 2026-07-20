//
//  SoundAlerts.swift
//  Subghost
//
//  設計書 追補: サウンドアラート
//  イベントごとに異なる8bit風の短いモチーフを合成して鳴らす。
//  音源ファイルを持たず矩形波をその場で生成するため、アプリサイズが増えない。
//

import AVFoundation
import AppKit

// MARK: - 音の定義

/// モチーフを構成する1音（周波数0で無音＝休符）
nonisolated struct ToneStep: Sendable {
    let frequency: Double
    let duration: Double
}

nonisolated enum AlertSound: String, CaseIterable, Sendable {
    // セッション
    case sessionStart       // 新しいCLIセッションを検出
    case completed          // AIがターンを完了
    case error              // ツールエラー / APIエラー

    // インタラクション
    case approval           // 権限の承認待ち
    case question           // 質問への回答待ち
    case promptSent         // ノッチからプロンプトを送信

    // システム
    case contextLimit       // コンテキストがもうすぐ満杯

    var displayName: String {
        switch self {
        case .sessionStart: return "セッション開始"
        case .completed: return "タスク完了"
        case .error: return "タスクエラー"
        case .approval: return "承認が必要"
        case .question: return "入力待ち"
        case .promptSent: return "プロンプト送信"
        case .contextLimit: return "コンテキスト制限"
        }
    }

    var detail: String {
        switch self {
        case .sessionStart: return "新しい Claude / Codex / Antigravity セッション"
        case .completed: return "AI がターンを完了しました"
        case .error: return "ツールエラーまたは API エラー"
        case .approval: return "権限の承認待ち"
        case .question: return "AI が入力を待っています"
        case .promptSent: return "プロンプトを送信しました"
        case .contextLimit: return "コンテキストウィンドウがもうすぐ満杯"
        }
    }

    /// 設定画面での並び（参考にした分類に合わせる）
    var category: String {
        switch self {
        case .sessionStart, .completed, .error: return "セッション"
        case .approval, .question, .promptSent: return "インタラクション"
        case .contextLimit: return "システム"
        }
    }

    /// 個別に鳴らすかどうかの設定キー
    var enabledKey: String { "sound.\(rawValue).enabled" }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// 8bit風モチーフ（音名はおおよそ C5=523Hz を基準）
    ///
    /// 意味と音形を対応させている:
    ///   上行=良い知らせ / 下行=悪い知らせ / 反復=注意を引く / 単発=軽い確認
    var steps: [ToneStep] {
        switch self {
        case .sessionStart:
            // 起動音。低→高へ駆け上がる明るい和音進行
            return [ToneStep(frequency: 523, duration: 0.05),     // C5
                    ToneStep(frequency: 659, duration: 0.05),     // E5
                    ToneStep(frequency: 784, duration: 0.12)]     // G5

        case .completed:
            // 完了。完全4度の上行で「収まった」感じ
            return [ToneStep(frequency: 784, duration: 0.07),     // G5
                    ToneStep(frequency: 1046, duration: 0.11)]    // C6

        case .error:
            // エラー。下行させて不穏さを出す
            return [ToneStep(frequency: 415, duration: 0.09),     // G#4
                    ToneStep(frequency: 311, duration: 0.16)]     // D#4

        case .approval:
            // 承認待ち。反復で気を引き、最後に上げて「待っている」ことを示す
            return [ToneStep(frequency: 880, duration: 0.06),     // A5
                    ToneStep(frequency: 0, duration: 0.04),
                    ToneStep(frequency: 880, duration: 0.06),
                    ToneStep(frequency: 0, duration: 0.04),
                    ToneStep(frequency: 1174, duration: 0.12)]    // D6

        case .question:
            // 質問。語尾を上げる問いかけ調
            return [ToneStep(frequency: 659, duration: 0.08),     // E5
                    ToneStep(frequency: 988, duration: 0.13)]     // B5

        case .promptSent:
            // 送信。邪魔にならないよう短い単発
            return [ToneStep(frequency: 1046, duration: 0.04)]    // C6

        case .contextLimit:
            // 警告。低音の反復で他と明確に区別する
            return [ToneStep(frequency: 392, duration: 0.09),     // G4
                    ToneStep(frequency: 0, duration: 0.05),
                    ToneStep(frequency: 392, duration: 0.09),
                    ToneStep(frequency: 0, duration: 0.05),
                    ToneStep(frequency: 294, duration: 0.16)]     // D4
        }
    }
}

// MARK: - 再生

@MainActor
final class SoundAlerts {

    static let shared = SoundAlerts()

    /// 音量設定の既定値
    static let defaultVolume: Float = 0.6

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var format: AVAudioFormat?
    private var isEngineRunning = false
    /// 生成済みバッファのキャッシュ（モチーフは固定なので使い回せる）
    private var buffers: [AlertSound: AVAudioPCMBuffer] = [:]

    private init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            NSLog("Subghost: オーディオフォーマットの生成に失敗しました")
            return
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// 状態に対応するアラート音を鳴らす。無効な状態では何もしない。
    func play(for state: AIState) {
        switch state {
        case .completed: play(.completed)
        case .error: play(.error)
        case .awaitingApproval: play(.approval)
        case .awaitingAnswer: play(.question)
        case .idle, .thinking: return
        }
    }

    func play(_ sound: AlertSound) {
        // 全体設定と、イベントごとの設定の両方を見る
        guard Self.isEnabled, sound.isEnabled else { return }
        guard let buffer = buffer(for: sound) else { return }

        do {
            if !isEngineRunning {
                try engine.start()
                isEngineRunning = true
            }
            if !player.isPlaying { player.play() }
            player.volume = Self.volume
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        } catch {
            // オーディオデバイスが使えない環境ではシステムビープで代替する
            NSLog("Subghost: アラート音の再生に失敗しました: \(error.localizedDescription)")
            isEngineRunning = false
            NSSound.beep()
        }
    }

    // MARK: - 設定

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    }

    static var volume: Float {
        let stored = UserDefaults.standard.object(forKey: "soundVolume") as? Double
        return Float(stored ?? Double(defaultVolume))
    }

    // MARK: - 波形生成

    private func buffer(for sound: AlertSound) -> AVAudioPCMBuffer? {
        if let cached = buffers[sound] { return cached }
        guard let generated = makeBuffer(steps: sound.steps) else { return nil }
        buffers[sound] = generated
        return generated
    }

    /// モチーフを矩形波のPCMバッファへ変換する
    private func makeBuffer(steps: [ToneStep]) -> AVAudioPCMBuffer? {
        guard let format else { return nil }

        let totalDuration = steps.reduce(0) { $0 + $1.duration }
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else {
            NSLog("Subghost: アラート音バッファの確保に失敗しました")
            return nil
        }
        buffer.frameLength = frameCount

        // クリック音を防ぐためのフェード長（1音あたり最大3ms）
        let fadeFrames = Int(0.003 * sampleRate)
        var cursor = 0

        for step in steps {
            let stepFrames = min(Int(step.duration * sampleRate), Int(frameCount) - cursor)
            guard stepFrames > 0 else { break }

            if step.frequency <= 0 {
                // 休符
                for offset in 0..<stepFrames { channel[cursor + offset] = 0 }
                cursor += stepFrames
                continue
            }

            let period = sampleRate / step.frequency
            for offset in 0..<stepFrames {
                // 矩形波：周期の前半を+、後半を−にする
                let phase = Double(offset).truncatingRemainder(dividingBy: period) / period
                var sample: Float = phase < 0.5 ? 0.22 : -0.22

                // 音の切れ目でプチノイズが出ないよう前後をフェードする
                let fade = min(fadeFrames, stepFrames / 2)
                if fade > 0 {
                    if offset < fade {
                        sample *= Float(offset) / Float(fade)
                    } else if offset >= stepFrames - fade {
                        sample *= Float(stepFrames - offset) / Float(fade)
                    }
                }
                channel[cursor + offset] = sample
            }
            cursor += stepFrames
        }

        // 端数フレームを無音で埋める
        while cursor < Int(frameCount) {
            channel[cursor] = 0
            cursor += 1
        }
        return buffer
    }
}
