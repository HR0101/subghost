//
//  SnippetStore.swift
//  Subghost
//
//  設計書 4.4: プロンプト履歴/スニペット（JSONで永続化）
//

import Foundation
import Observation

@Observable
final class SnippetStore {

    private(set) var snippets: [Snippet] = []
    private(set) var history: [String] = []   // 新しい順

    private let maxHistory = 50

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subghost", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("store.json")
    }

    private struct Persisted: Codable {
        var snippets: [Snippet]
        var history: [String]
    }

    init() {
        load()
    }

    // MARK: - スニペット

    func add(title: String, body: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        let b = body.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        snippets.append(Snippet(title: t.isEmpty ? String(b.prefix(10)) : t, body: b))
        save()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    // MARK: - 履歴 (設計書 4.4: 上矢印キーで呼び出し)

    func recordHistory(_ prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        history.removeAll { $0 == p }
        history.insert(p, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        save()
    }

    // MARK: - 永続化

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            snippets = persisted.snippets
            history = persisted.history
        } else {
            snippets = Snippet.defaults
        }
    }

    private func save() {
        let persisted = Persisted(snippets: snippets, history: history)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
