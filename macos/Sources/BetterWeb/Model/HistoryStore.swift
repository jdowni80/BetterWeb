import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: String { "\(timestamp)-\(url)" }
    let url: String
    let title: String?
    let timestamp: Date
    let entryType: String // url | search | link
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let key = "betterweb.history.v1"
    private let limit = 500

    init() {
        load()
    }

    func add(url: String, title: String?, entryType: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup consecutive identical URLs; a late-arriving page title upgrades the entry.
        if let first = entries.first, first.url == trimmed {
            if let title, !title.isEmpty, first.title != title {
                entries[0] = HistoryEntry(url: trimmed, title: title, timestamp: first.timestamp, entryType: first.entryType)
                save()
            }
            return
        }
        entries.insert(
            HistoryEntry(url: trimmed, title: title, timestamp: Date(), entryType: entryType),
            at: 0
        )
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Local-only omnibox suggestions: history and bookmarks, never a remote suggest API.
    func suggestions(for query: String, bookmarks: [Bookmark], limit: Int = 6) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 1 else { return [] }
        var seen = Set<String>()
        var out: [Suggestion] = []
        func consider(_ s: Suggestion) {
            guard out.count < limit, !seen.contains(s.value) else { return }
            let hay = (s.title + " " + s.value).lowercased()
            guard hay.contains(q) else { return }
            seen.insert(s.value)
            out.append(s)
        }
        for b in bookmarks { consider(Suggestion(kind: .bookmark, title: b.title, value: b.url)) }
        for e in entries {
            let kind: Suggestion.Kind = e.entryType == "search" ? .search : .history
            consider(Suggestion(kind: kind, title: e.title ?? e.url, value: e.url))
        }
        return out
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
