//
//  CustomAliasStore.swift
//  Subghost
//
//  設計書 追補: ユーザー独自のCLI起動名（カスタムエイリアス）の永続化。
//
//  背景: シェルのエイリアス（alias codexA=...）自体は展開後の実行ファイル名で
//  検出できるため対応不要だが、独自のラッパースクリプトやシンボリックリンクなど
//  「実行ファイル名そのものが違う」場合は、そのCLIとして検出できない。
//  ここで登録した名前を CLIProfile.executableNames へ合成することで対応する。
//

import Foundation
import Observation

@Observable
final class CustomAliasStore {

    private(set) var aliases: [CustomAlias] = []

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subghost", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("custom-aliases.json")
    }

    init() {
        load()
    }

    /// 名前を追加する。空文字・重複（大文字小文字を区別しない）は無視する。
    @discardableResult
    func add(name: String, baseProfileID: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !aliases.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        aliases.append(CustomAlias(name: trimmed, baseProfileID: baseProfileID))
        save()
        return true
    }

    func remove(_ alias: CustomAlias) {
        aliases.removeAll { $0.id == alias.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([CustomAlias].self, from: data)
        else { return }
        aliases = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
