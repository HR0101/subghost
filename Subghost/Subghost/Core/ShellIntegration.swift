//
//  ShellIntegration.swift
//  Subghost
//
//  旧版が ~/.zshrc に追加した auto-tmux 設定を安全に取り除くための
//  移行専用コード。新規インストールやスクリプト生成は行わない。
//

import Foundation

nonisolated enum ShellIntegration {
    static let beginMarker = "# >>> subghost auto-tmux >>>"
    static let endMarker = "# <<< subghost auto-tmux <<<"

    static var scriptPath: String {
        HookInstaller.supportDirectory.appendingPathComponent("shell/auto-tmux.sh").path
    }

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    static var zshrcWriteURL: URL {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return zshrcURL }
        return zshrcURL.resolvingSymlinksInPath()
    }

    static func isInstalled() -> Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return contents.contains(beginMarker)
    }

    static func uninstall() throws {
        guard let current = try? String(contentsOf: zshrcURL, encoding: .utf8),
              current.contains(beginMarker) else { return }
        try backupZshrc()
        try removeBlock(from: current).write(to: zshrcWriteURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: scriptPath)
    }

    static func removeBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var inside = false
        for line in lines {
            if line.contains(beginMarker) { inside = true; continue }
            if line.contains(endMarker) { inside = false; continue }
            if !inside { result.append(line) }
        }

        var collapsed: [String] = []
        for line in result {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
    }

    private static func backupZshrc() throws {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = zshrcURL.deletingLastPathComponent()
            .appendingPathComponent(".zshrc.subghost-backup-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: zshrcURL, to: backup)
    }
}
