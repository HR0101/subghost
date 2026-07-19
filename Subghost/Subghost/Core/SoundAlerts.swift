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
    case completed          // 応答完了：上行する明るい2音
    case error              // エラー：下行する低音
    case approval           // 承認待ち：注意を引く3連符
    case question           // 質問：問いかけ調の2音

    var displayName: String {
        switch self {
        case .completed: return "応答完了"
        case .error: return "エラー"
        case .approval: return "承認待ち"
        case .question: return "質問"
        }
    }

    /// 8bit風モチーフ（音名はおおよそ C5=523Hz を基準）
    var steps: [ToneStep] {
        switch self {
        case .completed:
            return [ToneStep(frequency: 784, duration: 0.07),    // G5
                    ToneStep(frequency: 1046, duration: 0.11)]   // C6
        case .error:
            return [ToneStep(frequency: 415, duration: 0.09),    // G#4
                    ToneStep(frequency: 311, duration: 0.16)]    // D#4
        case .approval:
            return [ToneStep(frequency: 880, duration: 0.06),    // A5
                    ToneStep(frequency: 0, duration: 0.04),
                    ToneStep(frequency: 880, duration: 0.06),
                    ToneStep(frequency: 0, duration: 0.04),
                    ToneStep(frequency: 1174, duration: 0.12)]   // D6
        case .question:
            return [ToneStep(frequency: 659, duration: 0.08),    // E5
                    ToneStep(frequency: 988, duration: 0.13)]    // B5
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
        guard Self.isEnabled else { return }
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
