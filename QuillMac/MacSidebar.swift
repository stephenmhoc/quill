import SwiftData
import SwiftUI

/// The source list: sites, then Drafts, and the Outbox when it needs attention.
struct MacSidebar: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @Query private var entries: [Entry]
    /// Ticks so a slow send shows up without anything else changing.
    @State private var now = Date.now
    @State private var editing: Site?

    var body: some View {
        @Bindable var navigation = navigation
        List(selection: $navigation.sidebar) {
            Section("Sites") {
                ForEach(sites) { site in
                    Label {
                        Text(site.name)
                    } icon: {
                        Circle().fill(site.color.color).frame(width: 10, height: 10)
                    }
                    .tag(SidebarItem.site(site.id))
                    .contextMenu {
                        Button("New Entry") { navigation.openBlankEntry(in: context, site: site.id) }
                        Button("Edit Site…") { editing = site }
                    }
                }
            }
            if drafts > 0 || outbox != nil {
                Section("Writing") {
                    if drafts > 0 {
                        Label("Drafts", systemImage: "doc.text")
                            .badge(drafts)
                            .tag(SidebarItem.drafts)
                    }
                    if let outbox {
                        Label("Outbox", systemImage: "tray.and.arrow.up")
                            .badge(outbox)
                            .tag(SidebarItem.outbox)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { navigation.showingAddSite = true } label: {
                Label("Add Site", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .sheet(item: $editing) { EditSiteView(site: $0) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
            }
        }
    }

    private var drafts: Int {
        entries.filter { $0.state == .editing && !$0.isBlank }.count
    }

    /// Nil while sends are going normally: the outbox only matters on an error or a slow send.
    private var outbox: Int? {
        let waiting = entries.filter { [.queued, .sending, .failed].contains($0.state) }
        let needsAttention = waiting.contains {
            $0.state == .failed || $0.lastError != nil || now.timeIntervalSince($0.updatedAt) > 30
        }
        return needsAttention ? waiting.count : nil
    }
}
