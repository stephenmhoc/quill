import GhostKit
import SwiftUI

struct TagEditor: View {
    @Bindable var entry: Entry
    let site: Site?

    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var suggestions: [String] = []

    private var visibleTags: [String] { entry.tags.filter { !$0.hasPrefix("#") } }
    private var matches: [String] {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions.filter { s in
            !entry.tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                && (q.isEmpty || s.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Add a tag", text: $input)
                        .textInputAutocapitalization(.never)
                        .onSubmit(addInput)
                    ForEach(visibleTags, id: \.self) { tag in
                        Text(tag)
                    }
                    .onDelete { offsets in
                        let removing = offsets.map { visibleTags[$0] }
                        entry.tags.removeAll { removing.contains($0) }
                    }
                }
                if !matches.isEmpty {
                    Section("On \(site?.name ?? "this site")") {
                        ForEach(matches.prefix(30), id: \.self) { tag in
                            Button(tag) { add(tag) }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { addInput(); dismiss() }
                }
            }
            .task { await loadSuggestions() }
        }
        .presentationDetents([.medium, .large])
    }

    private func addInput() {
        for part in input.split(separator: ",") { add(String(part)) }
        input = ""
    }

    private func add(_ tag: String) {
        entry.tags = EntryBuilder.normalizedTags(entry.tags + [tag])
    }

    private func loadSuggestions() async {
        guard let site, let client = try? lock.client(for: site) else { return }
        suggestions = ((try? await client.tags()) ?? []).filter { !$0.isInternal }.map(\.name)
    }
}
