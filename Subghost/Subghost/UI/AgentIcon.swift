//
//  AgentIcon.swift
//  Subghost
//
//  設計書 追補: 使用量に添えるAIアプリのアイコン
//
//  各CLIに対応する公式アプリがインストールされていれば、そのアプリのアイコンを
//  実行時に読み取って表示する（macOSがDockやFinderで行うのと同じ方法）。
//  画像素材を同梱しないため、他社ロゴを再配布することにならない。
//  アプリが見つからない場合は、コードで描くドット絵アイコンにフォールバックする。
//

import AppKit
import SwiftUI

@MainActor
enum AgentAppIcon {

    /// CLI種別 → 公式アプリのバンドルID候補（先に見つかったものを使う）
    private static let bundleIDs: [String: [String]] = [
        "claude": ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
        "codex": ["com.openai.codex", "com.openai.chat"],
        "antigravity": ["com.google.antigravity"],
    ]

    /// 一度解決したアイコンは使い回す（毎描画でディスク検索しない）
    private static var cache: [String: NSImage?] = [:]

    /// 公式アプリのアイコン。見つからなければ nil。
    static func image(for agentID: String) -> NSImage? {
        if let cached = cache[agentID] { return cached }

        let resolved = resolve(agentID: agentID)
        cache[agentID] = resolved
        return resolved
    }

    private static func resolve(agentID: String) -> NSImage? {
        guard let candidates = bundleIDs[agentID] else { return nil }
        let workspace = NSWorkspace.shared
        for bundleID in candidates {
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                continue
            }
            return workspace.icon(forFile: url.path)
        }
        return nil
    }
}

/// 公式アイコンがあればそれを、無ければドット絵を出す
struct AgentBadgeIcon: View {
    let agentID: String
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let icon = AgentAppIcon.image(for: agentID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                // 未インストールのCLI向けのフォールバック
                AgentIconView(agentID: agentID, pixelSize: max(2, size / 6))
            }
        }
        // CLI名は隣接するテキストが伝えるため、装飾として扱う。
        .accessibilityHidden(true)
    }
}
