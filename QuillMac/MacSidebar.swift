import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The source list: sites, then Drafts, and the Outbox when it needs attention.
struct MacSidebar: View {
    @Environment(Navigation.self) private var navigation
    @Environment(MacWindowState.self) private var window
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: Site.order) private var sites: [Site]
    @Query private var entries: [Entry]
    /// Ticks so a slow send shows up without anything else changing.
    @State private var now = Date.now
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var navigation = navigation
        @Bindable var window = window
        List(selection: $navigation.sidebar) {
            Section("Sites") {
                ForEach(sites) { site in
                    Label {
                        HStack {
                            Text(site.name)
                            Spacer()
                            Image(systemName: site.accessIcon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(site.accessLabel)
                        }
                    } icon: {
                        Circle().fill(site.color.color).frame(width: 10, height: 10)
                    }
                    .tag(SidebarItem.site(site.id))
                    .contextMenu {
                        Button("New Entry") { navigation.openBlankEntry(in: context, site: site.id) }
                        Divider()
                        Button("Edit Site…") { window.editingSite = site }
                        if let url = site.url, !site.urlString.isEmpty {
                            Button("Open in Browser") { openURL(url) }
                        }
                        Divider()
                        Button("Remove Site…", role: .destructive) { window.removingSite = site }
                    }
                }
                .onMove { Site.move(sites, from: $0, to: $1) }
            }
            // A row being looked at stays until something else is chosen, even once it's empty.
            if drafts > 0 || outbox != nil || navigation.sidebar == .drafts || navigation.sidebar == .outbox {
                Section("Writing") {
                    if drafts > 0 || navigation.sidebar == .drafts {
                        Label("Drafts", systemImage: "doc.text")
                            .badge(drafts)
                            .tag(SidebarItem.drafts)
                    }
                    if let count = outbox ?? (navigation.sidebar == .outbox ? 0 : nil) {
                        Label("Outbox", systemImage: "tray.and.arrow.up")
                            .badge(count)
                            .tag(SidebarItem.outbox)
                            .contextMenu {
                                Button("Retry All") { Task { await publisher.retryAll() } }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // In the sidebar, so the window's main actions keep the trailing end of the toolbar.
        .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: window.searchRequest) { searchFocused = true }
        .safeAreaInset(edge: .bottom) {
            Button { navigation.showingAddSite = true } label: {
                Label("Add Site", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
            .help("Add Site…")
            .accessibilityIdentifier("addSiteButton")
        }
        // Markdown files dropped here become drafts.
        .dropDestination(for: URL.self) { urls, _ in
            let made = MarkdownFile.makeDrafts(from: urls.filter(\.isFileURL), in: context, siteID: navigation.defaultSiteID(in: context))
            if let first = made.first { navigation.sidebar = .drafts; navigation.show(first) }
            return !made.isEmpty
        }
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

/// Site > Edit Site… and Remove Site…, from the menu bar or a sidebar row. On the split view
/// rather than the sidebar, so they still open while the sidebar is hidden.
struct SiteEditing: ViewModifier {
    @Environment(Navigation.self) private var navigation
    @Environment(MacWindowState.self) private var window
    @Environment(Publisher.self) private var publisher
    @Environment(AppLock.self) private var lock
    @State private var removeError: String?

    func body(content: Content) -> some View {
        @Bindable var window = window
        content
            .sheet(item: $window.editingSite) { EditSiteView(site: $0) }
            .onChange(of: lock.isUnlocked) { _, isUnlocked in if !isUnlocked { removeError = nil } }
            .confirmationDialog("Remove \(window.removingSite.flatMap { $0.isLive ? $0.name : nil } ?? "site")?",
                                isPresented: Binding(get: { window.removingSite != nil }, set: { if !$0 { window.removingSite = nil } }),
                                titleVisibility: .visible, presenting: window.removingSite) { site in
                Button("Remove", role: .destructive) { remove(site) }
            } message: { site in
                Text(site.isLive ? site.kind.removalNote : "")
            }
            .alert("Couldn't remove the site", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
                Button("OK") {}
            } message: { Text(removeError ?? "") }
    }

    private func remove(_ site: Site) {
        guard site.isLive else { return }
        navigation.leaveSite(site.id)
        do {
            try publisher.removeSite(site)
        } catch {
            removeError = error.localizedDescription
        }
    }
}
