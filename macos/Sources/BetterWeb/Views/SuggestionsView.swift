import SwiftUI

/// Apheleia's suggestion dropdown, fed only from local history and bookmarks.
struct SuggestionsView: View {
    let suggestions: [Suggestion]
    let selected: Int?
    let onPick: (Suggestion) -> Void
    var onHover: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, s in
                HStack(spacing: 12) {
                    Image(systemName: icon(for: s.kind))
                        .font(.system(size: 13))
                        .foregroundStyle(ApheleiaTheme.suggestIcon)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title)
                            .font(.system(size: 14))
                            .foregroundStyle(ApheleiaTheme.suggestText)
                            .lineLimit(1)
                        if s.kind != .search, s.title != s.value {
                            Text(s.value)
                                .font(.system(size: 11))
                                .foregroundStyle(ApheleiaTheme.suggestIcon)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(index == selected ? ApheleiaTheme.suggestBorder : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { onPick(s) }
                .onHover { if $0 { onHover?(index) } }
            }
        }
        .padding(.vertical, 6)
        .background(ApheleiaTheme.suggestBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ApheleiaTheme.suggestBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    private func icon(for kind: Suggestion.Kind) -> String {
        switch kind {
        case .search: return "magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        case .bookmark: return "star"
        }
    }
}

/// Omnibox state machine shared by the top bar and the homepage search.
@MainActor
final class OmniboxController: ObservableObject {
    @Published var text = ""
    @Published var focused = false
    @Published var selection: Int?
    @Published private(set) var suggestions: [Suggestion] = []
    /// Only show suggestions after the user types, not when focus restores the URL.
    private var userEdited = false

    func edited(_ model: AppModel) {
        userEdited = true
        selection = nil
        suggestions = model.suggestions(for: text)
    }

    var showsSuggestions: Bool { focused && userEdited && !suggestions.isEmpty }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selection ?? -1) + delta
        selection = next < 0 ? nil : min(next, suggestions.count - 1)
    }

    func dismiss() {
        userEdited = false
        selection = nil
        suggestions = []
    }

    /// Value to submit: the highlighted suggestion, or the typed text.
    var submission: String {
        if let selection, suggestions.indices.contains(selection) {
            return suggestions[selection].value
        }
        return text
    }
}
