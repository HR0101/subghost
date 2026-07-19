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

    /// 状態ごとの2コマ。交互に描いて簡単なアニメーションにする。
    static func frames(for state: AIState) -> (PixelSprite, PixelSprite) {
        switch state {
        case .idle, .completed:
            return (idle, blink)
        case .thinking:
            return (idle, wave)
        case .awaitingApproval, .awaitingAnswer:
            return (alert, idle)
        case .error:
            return (idle, idle)
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
}

// MARK: - 描画

struct PixelGhostView: View {
    let state: AIState
    /// ドット1つの大きさ
    var pixelSize: CGFloat = 3

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
        let (first, second) = GhostSprite.frames(for: state)
        let duration = GhostSprite.frameDuration(for: state)

        // 2コマを交互に描く。状態が変わったらアニメーションを作り直す。
        PhaseAnimatorFrames(first: first, second: second, duration: duration) { frame in
            spriteView(frame)
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
