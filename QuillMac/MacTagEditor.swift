import AppKit
import GhostKit
import SwiftUI

/// Tags in a popover: a token field, as Mail and Finder use, completing from the site's tags.
struct MacTagEditor: View {
    @Bindable var entry: Entry
    let site: Site?

    @Environment(Publisher.self) private var publisher
    @State private var suggestions: [String] = []

    /// Tags starting with "#" are the site's own internal ones, kept but not shown.
    private var tags: Binding<[String]> {
        Binding {
            entry.tags.filter { !$0.hasPrefix("#") }
        } set: { visible in
            entry.tags = EntryBuilder.normalizedTags(entry.tags.filter { $0.hasPrefix("#") } + visible)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            TagTokenField(tags: tags, suggestions: suggestions)
                .frame(minHeight: 22)
            Text("Separate tags with commas.\(site.map { " Suggestions come from \($0.name)." } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300)
        .task { await loadSuggestions() }
    }

    private func loadSuggestions() async {
        guard let site, site.isLive, let backend = try? publisher.backend(for: site) else { return }
        suggestions = (try? await backend.tags())?.filter { !$0.hasPrefix("#") } ?? []
    }
}

private struct TagTokenField: NSViewRepresentable {
    @Binding var tags: [String]
    let suggestions: [String]

    func makeCoordinator() -> Coordinator { Coordinator(tags: $tags) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.completionDelay = 0
        field.placeholderString = "Add tags"
        field.objectValue = tags
        field.setAccessibilityIdentifier("tagField")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.tags = $tags
        context.coordinator.suggestions = suggestions
        if field.currentEditor() == nil, (field.objectValue as? [String]) != tags { field.objectValue = tags }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var tags: Binding<[String]>
        var suggestions: [String] = []

        init(tags: Binding<[String]>) { self.tags = tags }

        private func current(_ field: NSTokenField) -> [String] {
            (field.objectValue as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            tags.wrappedValue = current(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            tags.wrappedValue = current(field)
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let chosen = Set(current(tokenField).map { $0.lowercased() })
            return suggestions.filter {
                $0.range(of: substring, options: [.caseInsensitive, .anchored]) != nil && !chosen.contains($0.lowercased())
            }
        }
    }
}
