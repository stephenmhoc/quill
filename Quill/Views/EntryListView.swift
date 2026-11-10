import SwiftData
import SwiftUI

/// Middle column for Drafts / Outbox.
struct EntryListView: View {
    let section: SidebarItem

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.usesColumns) private var usesColumns
    @Query(sort: \Entry.updatedAt, order: .reverse) private var entries: [Entry]
    @Query private var sites: [Site]
    #if os(macOS)
    @Environment(\.undoManager) private var undoManager
    @Query(sort: Site.order) private var orderedSites: [Site]
    @State private var selection: Set<UUID> = []
    @Environment(\.listQuery) private var query
    @Environment(\.isCovered) private var isCovered
    @Environment(\.hidesTitle) private var hidesTitle
    #endif

    private var visible: [Entry] {
        #if os(macOS)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return unfiltered }
        return unfiltered.filter { $0.title.localizedStandardContains(q) || $0.body.localizedStandardContains(q) }
        #else
        unfiltered
        #endif
    }

    private var unfiltered: [Entry] {
        switch section {
        case .drafts:
            entries.filter { $0.state == .editing && !$0.isBlank }
        case .outbox:
            entries.filter { [.queued, .sending, .failed].contains($0.state) }
        case .site:
            []
        }
    }

    private var title: String {
        switch section {
        case .drafts: "Drafts"
        case .outbox: "Outbox"
        case .site: ""
        }
    }

    var body: some View {
        list
            .overlay {
                if visible.isEmpty { emptyState }
            }
            .paperList()
            #if os(macOS)
            .navigationTitle(isCovered ? "Quill" : hidesTitle ? "" : title)
            #else
            .navigationTitle(title)
            #endif
            .largeTitle()
            .toolbar {
                if section == .outbox, !visible.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Retry All") { Task { await publisher.retryAll() } }
                    }
                }
            }
    }

    @ViewBuilder private var list: some View {
        #if os(macOS)
        List(selection: $selection) {
            ForEach(visible) { entry in
                EntryRow(entry: entry, site: sites.first { $0.id == entry.siteID })
                    .tag(entry.id)
                    .draggable(MarkdownFile(entry: entry))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in contextMenu(for: entries(ids)) }
        .onDeleteCommand { delete(entries(selection)) }
        // One row is the one that's open; several are only chosen, for deleting or exporting.
        .onChange(of: selection) { _, ids in
            if ids.count == 1, let entry = entries(ids).first, entry != navigation.selectedEntry { navigation.show(entry) }
        }
        .onChange(of: navigation.selectedEntry, initial: true) { _, entry in
            if let entry, visible.contains(entry) {
                if !selection.contains(entry.id) { selection = [entry.id] }
            } else if selection.count <= 1 {
                selection = []
            }
        }
        #else
        List {
            ForEach(visible) { entry in
                Button { navigation.show(entry) } label: {
                    EntryRow(entry: entry, site: sites.first { $0.id == entry.siteID })
                }
                .buttonStyle(.plain)
                .cardRow(isSelected: entry == navigation.selectedEntry && usesColumns)
                .swipeActions(edge: .trailing) {
                    if entry.state != .sending {
                        Button(role: .destructive) { delete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder private var emptyState: some View {
        switch section {
        case .drafts: ContentUnavailableView("No drafts", systemImage: "doc.text",
                                             description: Text("Unsent writing is kept here, on \(thisDevice) only."))
        case .outbox: ContentUnavailableView("Outbox empty", systemImage: "tray",
                                             description: Text("Entries that couldn't be sent wait here and retry automatically."))
        case .site: EmptyView()
        }
    }

    private func delete(_ entry: Entry) {
        if navigation.selectedEntry == entry { navigation.selectedEntry = nil }
        context.delete(entry)
        try? context.save()
    }

    #if os(macOS)
    private func entries(_ ids: Set<UUID>) -> [Entry] { visible.filter { ids.contains($0.id) } }

    @ViewBuilder private func contextMenu(for chosen: [Entry]) -> some View {
        let deletable = chosen.filter { $0.modelContext != nil && !$0.isDeleted && $0.state != .sending }
        if !chosen.isEmpty {
            Button(chosen.count == 1 ? "Export as Markdown…" : "Export \(chosen.count) Entries as Markdown…") {
                MarkdownFile.export(chosen)
            }
            if chosen.allSatisfy({ $0.state == .editing && $0.remotePostID == nil && $0.uploadedToSiteID == nil }) {
                Menu("Move to Site") {
                    ForEach(orderedSites) { site in
                        Button(site.name) { for entry in chosen { entry.siteID = site.id }; try? context.save() }
                    }
                }
            }
            if section == .outbox {
                Divider()
                // Any of them can be deleted while an earlier one sends.
                Button("Retry") {
                    Task { for entry in chosen where entry.modelContext != nil && !entry.isDeleted { await publisher.publish(entry) } }
                }
                Button("Retry All") { Task { await publisher.retryAll() } }
            }
            if !deletable.isEmpty {
                Divider()
                Button(deletable.count == 1 ? "Delete" : "Delete \(deletable.count) Entries", role: .destructive) { delete(deletable) }
            }
        }
    }

    private func delete(_ chosen: [Entry]) {
        EntryDeletion.delete(chosen, in: context, navigation: navigation, undoManager: undoManager)
        selection = []
    }
    #endif
}

struct EntryRow: View {
    let entry: Entry
    let site: Site?

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(spacing: 6) {
                if let site {
                    Circle().fill(site.color.color).frame(width: 7, height: 7)
                    Text(site.name.uppercased())
                }
                Spacer()
                Text(entry.sentAt ?? entry.updatedAt, format: .relative(presentation: .named))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(entry.isBlank ? "New entry" : entry.displayTitle)
                .font(.system(.headline, design: .serif))
                .lineLimit(2)
                .foregroundStyle(entry.isBlank ? .secondary : .primary)

            if !entry.body.isEmpty, !entry.title.isEmpty {
                Text(entry.body)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            status
        }
        #if os(macOS)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        #else
        .padding(.vertical, 4)
        #endif
    }

    private var rowSpacing: CGFloat {
        #if os(macOS)
        7
        #else
        4
        #endif
    }

    @ViewBuilder private var status: some View {
        switch entry.state {
        case .queued:
            Label(entry.lastError == nil ? "Waiting to send" : "Will retry", systemImage: "clock")
                .font(.caption).foregroundStyle(.orange)
        case .sending:
            Label("Sending…", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label(entry.lastError ?? "Failed", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case .sent, .editing:
            EmptyView()
        }
    }
}
