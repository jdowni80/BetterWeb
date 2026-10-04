import Foundation

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var title: String
    let createdAt: Date
}

struct Suggestion: Identifiable, Equatable {
    enum Kind { case search, history, bookmark }
    var id: String { value }
    let kind: Kind
    let title: String
    let value: String
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private let key = "betterweb.bookmarks.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        }
    }

    func contains(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// Returns `true` if the URL is bookmarked after the call.
    @discardableResult
    func toggle(url: String, title: String) -> Bool {
        if let i = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: i)
            save()
            return false
        }
        bookmarks.insert(Bookmark(id: UUID(), url: url, title: title.isEmpty ? url : title, createdAt: Date()), at: 0)
        save()
        return true
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
