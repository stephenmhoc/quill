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
    @State private var pendingDelete: Entry?

    private var visible: [Entry] {
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
            .navigationTitle(title)
            .largeTitle()
            .toolbar {
                #if os(macOS)
                // Empty, but without an item in this column the editor's toolbar loses its left edge.
                ToolbarItem(placement: .primaryAction) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
                #endif
                if section == .outbox, !visible.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Retry All") { Task { await publisher.retryAll() } }
                    }
                }
            }
    }

    @ViewBuilder private var list: some View {
        #if os(macOS)
        List(selection: Binding(get: { navigation.selectedEntry }, set: { if let entry = $0 { navigation.show(entry) } })) {
            ForEach(visible) { entry in
                EntryRow(entry: entry, site: sites.first { $0.id == entry.siteID })
                    .tag(entry)
                    .contextMenu {
                        if entry.state != .sending {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                        }
                    }
            }
        }
        .onDeleteCommand {
            if let entry = navigation.selectedEntry, visible.contains(entry), entry.state != .sending { pendingDelete = entry }
        }
        // Nothing else keeps a copy of a draft.
        .confirmationDialog("Delete “\(pendingDelete?.displayTitle ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
        } message: { _ in
            Text("This can't be undone.")
        }
        #else
        // Selection lets a keyboard and pointer move through the list. On iPhone a row pushes.
        if usesColumns {
            List(selection: Binding(get: { navigation.selectedEntry }, set: { if let entry = $0 { navigation.show(entry) } })) {
                ForEach(visible) { entry in
                    rowActions(EntryRow(entry: entry, site: sites.first { $0.id == entry.siteID }).tag(entry), entry)
                        .cardRow(isSelected: entry == navigation.selectedEntry)
                }
            }
        } else {
            List {
                ForEach(visible) { entry in
                    rowActions(Button { navigation.show(entry) } label: {
                        EntryRow(entry: entry, site: sites.first { $0.id == entry.siteID })
                    }.buttonStyle(.plain), entry)
                    .cardRow()
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private func rowActions(_ row: some View, _ entry: Entry) -> some View {
        row
        // Not a destructive role, which would take the row away before the question is answered.
        .swipeActions(edge: .trailing) {
            if entry.state != .sending {
                Button { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "doc.text") { navigation.show(entry) }
            if entry.state != .sending {
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = entry }
            }
        }
        // On the row, so on iPad it points at what it would delete.
        .confirmationDialog("Delete “\(entry.displayTitle)”?",
                            isPresented: Binding(get: { pendingDelete == entry }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(entry) }
        } message: {
            Text("Nothing else keeps a copy of it, so this can't be undone.")
        }
    }
    #endif

    @ViewBuilder private var emptyState: some View {
        switch section {
        case .drafts: ContentUnavailableView("No drafts", systemImage: "doc.text",
                                             description: Text("Unsent writing is kept here, on this device only."))
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
