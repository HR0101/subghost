//
//  PixelGhost.swift
//  Subghost
//
//  設計書 追補: ドット絵キャラクター
//
//  アプリ名にちなんだ6×6のゴースト。画像ファイルは持たず、
//  ドットの配置を文字列で定義してその場で描画する。
//  8bit風のアラート音と同じ方針で、素材の持ち込みも権利処理も不要にしている。
//
//  文字の意味:
//    "." … 透明
//    "#" … body（状態に応じた色）
//    "o" … 目
//

import SwiftUI

// MARK: - スプライト定義

nonisolated struct PixelSprite: Equatable {
    let rows: [String]

    var height: Int { rows.count }
    var width: Int { rows.map(\.count).max() ?? 0 }

    /// (行, 列) の文字を返す。範囲外は透明扱い。
    func character(row: Int, column: Int) -> Character {
        guard row >= 0, row < rows.count else { return "." }
        let line = Array(rows[row])
        guard column >= 0, column < line.count else { return "." }
        return line[column]
    }
}

nonisolated enum GhostSprite {

    /// 通常。目は中央寄り。
    static let idle = PixelSprite(rows: [
        ".####.",
        "######",
        "#o##o#",
        "######",
        "######",
        "#.##.#",
    ])

    /// まばたき（目を閉じた状態）
    static let blink = PixelSprite(rows: [
        ".####.",
        "######",
        "######",
        "######",
        "######",
        "#.##.#",
    ])

    /// 裾が揺れた状態。生成中はこれと idle を往復させる。
    static let wave = PixelSprite(rows: [
        ".####.",
        "######",
        "#o##o#",
        "######",
        "######",
        ".#..#.",
    ])

    /// 応答待ち。目を大きく開いて注意を促す。
    static let alert = PixelSprite(rows: [
        ".####.",
        "#o##o#",
        "#o##o#",
        "######",
        "######",
        "#.##.#",
    ])

    /// 完了。目を細めた満足げな表情。
    /// 色（緑）だけに頼らず、形の違いだけでも待機中と区別できるようにする。
    static let happy = PixelSprite(rows: [
        ".####.",
        "######",
        "oo##oo",
        "######",
        "######",
        "#.##.#",
    ])

    /// エラー。口を開けた表情。
    /// 以前は待機中と同じ絵で色（赤）だけが差分だったため、色覚特性によっては
    /// 区別できなかった。口の有無という形の差を付けている。
    static let upset = PixelSprite(rows: [
        ".####.",
        "######",
        "#o##o#",
        "######",
        "##oo##",
        "#.##.#",
    ])

    /// 状態ごとの2コマ。交互に描いて簡単なアニメーションにする。
    static func frames(for state: AIState) -> (PixelSprite, PixelSprite) {
        switch state {
        case .idle:
            return (idle, blink)
        case .completed:
            return (happy, happy)
        case .thinking:
            return (idle, wave)
        case .awaitingApproval, .awaitingAnswer:
            return (alert, idle)
        case .error:
            return (upset, upset)
        }
    }

    /// 1コマの表示時間。状態によって速さを変える。
    static func frameDuration(for state: AIState) -> Double {
        switch state {
        case .thinking: return 0.35        // せわしなく揺れる
        case .awaitingApproval, .awaitingAnswer: return 0.5   // 点滅して気を引く
        default: return 2.2                // たまに瞬きするだけ
        }
    }

    /// 動きは「生成中」の合図として専用に使う。
    /// 待機中や監視可能というだけではキャラクターを動かさない。
    static func shouldAnimate(for state: AIState) -> Bool {
        state == .thinking
    }
}

// MARK: - 描画

struct PixelGhostView: View {
    let state: AIState
    /// ドット1つの大きさ
    var pixelSize: CGFloat = 3
    /// 外部（ホバーなど）から「覗き込み」を促す合図。値が変わるたびに一度だけ再生する。
    var peekTrigger: Int = 0

    /// 「視差効果を減らす」が有効なら、揺れ・弾み・震え・まばたきをすべて止める。
    /// 画面最上部に常駐するため、小さな動きでも動きに敏感なユーザーの負担になる。
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Subghost側の設定でも同じように止められる。
    /// システム全体の設定を変えずにゴーストだけ静止させたい場合があるため、
    /// どちらか一方でも「止める」ならアニメーションしない。
    @AppStorage(AppearancePreferences.ghostAnimationEnabledKey) private var ghostAnimation = true

    private var reduceMotion: Bool { systemReduceMotion || !ghostAnimation }

    /// 完了・エラーへ遷移した瞬間だけ再生するワンショット演出のトリガー。
    /// (値そのものに意味はなく、変化したことだけをPhaseAnimatorへの合図として使う)
    @State private var completionPulse = 0
    @State private var errorShake = 0
    /// アイドル中の低頻度なまばたきと、ホバー時の覗き込みは、
    /// どちらも「一瞬だけ別のスプライトを見せて戻す」という同じ仕組みを共有する。
    @State private var microExpressionTrigger = 0
    @State private var microExpressionSprite: PixelSprite = GhostSprite.blink

    private var bodyColor: Color {
        switch state {
        case .idle: return .gray
        case .thinking: return .blue
        case .awaitingApproval: return .orange
        case .awaitingAnswer: return .yellow
        case .completed: return .green
        case .error: return .red
        }
    }

    var body: some View {
        // 震え(error)・弾み(completed)はキャラクター全体の変形なので、
        // スプライト差し替え(id(state)でリセットされる部分)より外側で扱い、
        // state遷移をまたいで正しく1回だけ再生されるようにする。
        PhaseAnimator(Self.shakePhases, trigger: errorShake) { shakeOffset in
            PhaseAnimator(Self.pulsePhases, trigger: completionPulse) { scale in
                spriteContent
                    .scaleEffect(scale)
                    .offset(x: shakeOffset)
            } animation: { _ in
                .interpolatingSpring(stiffness: 380, damping: 9)
            }
        } animation: { _ in
            .easeInOut(duration: 0.045)
        }
        .onChange(of: state) { _, newValue in
            guard !reduceMotion else { return }
            if newValue == .completed { completionPulse += 1 }
            if newValue == .error { errorShake += 1 }
        }
        .onChange(of: peekTrigger) { _, _ in
            // 生成中は既にwaveアニメが動いているため、覗き込みで割り込まない。
            guard !reduceMotion, state != .thinking else { return }
            microExpressionSprite = GhostSprite.alert
            microExpressionTrigger += 1
        }
        // アイドルのあいだだけ、低頻度でまばたきを挟む。
        // state が変わると .task(id:) が自動的にキャンセル・再起動する。
        .task(id: state) {
            guard !reduceMotion, state == .idle else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: Self.idleBlinkIntervalRange)))
                guard !Task.isCancelled else { return }
                microExpressionSprite = GhostSprite.blink
                microExpressionTrigger += 1
            }
        }
        // 状態は囲んでいるコンテナ側がまとめて読み上げる（二重読み上げを避ける）。
        .accessibilityHidden(true)
    }

    /// エラー時の震え: 素早く左右へ数回振れて中央へ戻る
    private static let shakePhases: [CGFloat] = [0, -2.2, 2.2, -1.4, 1.4, 0]
    /// 完了時の弾み: 一瞬膨らんで元の大きさへ戻る
    private static let pulsePhases: [CGFloat] = [1.0, 1.22, 1.0]
    /// アイドル中にまばたきするまでの間隔（毎回ランダムに選び直す）
    private static let idleBlinkIntervalRange: ClosedRange<Double> = 4...9
    /// まばたき・覗き込みが「別スプライトを見せている」時間
    private static let microExpressionHold: Double = 0.1

    /// state に応じた通常表示（生成中の裾揺れ、それ以外は静止＋低頻度の微表情）
    private var spriteContent: some View {
        let (first, second) = GhostSprite.frames(for: state)
        let duration = GhostSprite.frameDuration(for: state)

        return Group {
            if GhostSprite.shouldAnimate(for: state), !reduceMotion {
                // 生成中だけ裾を揺らす。動いているキャラクター＝生成中に統一する。
                PhaseAnimatorFrames(first: first, second: second, duration: duration) { frame in
                    spriteView(frame)
                }
            } else {
                PhaseAnimator([false, true, false], trigger: microExpressionTrigger) { showAlt in
                    spriteView(showAlt ? microExpressionSprite : first)
                } animation: { _ in
                    .linear(duration: 0.01).delay(Self.microExpressionHold)
                }
            }
        }
        .id(state)
    }

    /// スプライト1枚をドットの集合として描く
    private func spriteView(_ sprite: PixelSprite) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<sprite.height, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<sprite.width, id: \.self) { column in
                        let character = sprite.character(row: row, column: column)
                        Rectangle()
                            .fill(color(for: character))
                            .frame(width: pixelSize, height: pixelSize)
                    }
                }
            }
        }
        .shadow(color: bodyColor.opacity(0.6), radius: 3)
    }

    private func color(for character: Character) -> Color {
        switch character {
        case "#": return bodyColor
        case "o": return .black.opacity(0.85)
        default: return .clear
        }
    }
}

/// 2コマを一定間隔で切り替える小さなヘルパー
private struct PhaseAnimatorFrames<Content: View>: View {
    let first: PixelSprite
    let second: PixelSprite
    let duration: Double
    @ViewBuilder let content: (PixelSprite) -> Content

    var body: some View {
        PhaseAnimator([false, true]) { showSecond in
            content(showSecond ? second : first)
        } animation: { _ in
            // ドット絵なので中間状態を作らず、パッと切り替える
            .linear(duration: 0.01).delay(duration)
        }
    }
}


// MARK: - CLIごとのアイコン

/// CLIを見分けるための小さなドット絵。
/// ゴーストと同じく画像を持たず、配置を文字列で定義する。
nonisolated enum AgentSprite {

    /// Claude: 放射状のきらめき
    static let claude = PixelSprite(rows: [
        "..#..",
        "#.#.#",
        ".###.",
        "#.#.#",
        "..#..",
    ])

    /// Codex: 環
    static let codex = PixelSprite(rows: [
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    ])

    /// Antigravity: 菱形
    static let antigravity = PixelSprite(rows: [
        "..#..",
        ".###.",
        "#####",
        ".###.",
        "..#..",
    ])

    static func sprite(for agentID: String) -> PixelSprite {
        switch agentID {
        case "claude": return claude
        case "codex": return codex
        default: return antigravity
        }
    }

    /// バッジの色分けと揃える
    static func color(for agentID: String) -> Color {
        switch agentID {
        case "claude": return .orange
        case "codex": return .blue
        default: return .green
        }
    }
}

struct AgentIconView: View {
    let agentID: String
    var pixelSize: CGFloat = 2

    var body: some View {
        let sprite = AgentSprite.sprite(for: agentID)
        let tint = AgentSprite.color(for: agentID)

        VStack(spacing: 0) {
            ForEach(0..<sprite.height, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<sprite.width, id: \.self) { column in
                        Rectangle()
                            .fill(sprite.character(row: row, column: column) == "#"
                                  ? tint : Color.clear)
                            .frame(width: pixelSize, height: pixelSize)
                    }
                }
            }
        }
        .shadow(color: tint.opacity(0.5), radius: 2)
        // CLI名は隣接するテキストが伝えるため、装飾として扱う。
        .accessibilityHidden(true)
    }
}
