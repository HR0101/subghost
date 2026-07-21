//
//  SnippetStore.swift
//  Subghost
//
//  設計書 4.4: プロンプト履歴/スニペット（JSONで永続化）
//

import Foundation
import Observation

// MARK: - 送信履歴の設定

/// 送信したプロンプトは平文でディスクに残るため、残すかどうかと件数を選べるようにする。
nonisolated enum PromptHistoryPreferences {
    static let enabledKey = "promptHistoryEnabled"
    static let limitKey = "promptHistoryLimit"

    static let defaultLimit = 50
    static let limitRange: ClosedRange<Int> = 5...200

    static var isEnabled: Bool {
        NotchPreferences.bool(forKey: enabledKey, default: true)
    }

    static var limit: Int {
        let stored = Int(NotchPreferences.number(forKey: limitKey, default: Double(defaultLimit)))
        return min(max(stored, limitRange.lowerBound), limitRange.upperBound)
    }
}

// MARK: - 並べ替え

/// SwiftUI の `move(fromOffsets:toOffset:)` と同じ意味の並べ替え。
///
/// ストアにUIフレームワークを持ち込まないための自前実装で、
/// 添字のずれを間違えやすい箇所なので純粋関数として切り出してテストしている。
nonisolated enum Reordering {
    static func moved<Element>(
        _ items: [Element],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Element] {
        let moving = source.compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !moving.isEmpty else { return items }

        var result = items
        // 添字がずれないよう後ろから取り除く
        for index in source.sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }
        // destination は取り除く前の位置なので、前方で消えたぶんだけ詰める
        let removedBefore = source.filter { $0 < destination }.count
        let insertion = min(max(destination - removedBefore, 0), result.count)
        result.insert(contentsOf: moving, at: insertion)
        return result
    }
}

@Observable
final class SnippetStore {

    private(set) var snippets: [Snippet] = []
    private(set) var history: [String] = []   // 新しい順

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

    /// 設定画面の一覧から並べ替える（よく使うものを上へ持ってこられるように）
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let reordered = Reordering.moved(snippets, fromOffsets: source, toOffset: destination)
        guard reordered != snippets else { return }
        snippets = reordered
        save()
    }

    /// 既定のスニペットへ戻す
    func restoreDefaults() {
        snippets = Snippet.defaults
        save()
    }

    // MARK: - 履歴 (設計書 4.4: ⌥↑ で呼び出し)

    func recordHistory(_ prompt: String) {
        guard PromptHistoryPreferences.isEnabled else { return }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        history.removeAll { $0 == p }
        history.insert(p, at: 0)
        trimHistory()
        save()
    }

    /// 送信履歴だけを消す（スニペットは残す）
    func clearHistory() {
        guard !history.isEmpty else { return }
        history = []
        save()
    }

    /// 設定で件数を減らしたときに、その場で縮める
    func applyHistoryLimit() {
        let before = history.count
        trimHistory()
        if history.count != before { save() }
    }

    private func trimHistory() {
        let limit = PromptHistoryPreferences.limit
        guard history.count > limit else { return }
        history.removeLast(history.count - limit)
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
