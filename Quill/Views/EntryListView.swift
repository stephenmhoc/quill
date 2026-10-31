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
                if section == .outbox, !visible.isEmpty {
                    Button("Retry All") { Task { await publisher.retryAll() } }
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
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
                        }
                    }
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
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.vertical, 4)
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
