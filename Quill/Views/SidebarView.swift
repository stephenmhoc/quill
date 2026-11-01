import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.usesColumns) private var usesColumns
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @Query private var entries: [Entry]
    /// Ticks so a slow send shows up without anything else changing.
    @State private var now = Date.now
    /// Where each site's row is, so the new entry button can be dropped on one.
    @State private var siteFrames: [UUID: CGRect] = [:]
    @State private var dropSite: UUID?

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            // Selection plus NavigationLink pushes twice on iPhone.
            if usesColumns {
                // Grey, because the accent's fill would hide a rust site's dot, and shouts.
                List(selection: selection) { rows }
                    .tint(Color(white: 0.45))
            } else {
                List { rows.listRowBackground(Color.card) }
                    .listSectionSpacing(12)
            }
        }
        // iPad keeps the system's sidebar surface, so it stands apart from the list beside it.
        .scrollContentBackground(usesColumns ? .automatic : .hidden)
        .background((usesColumns ? Color.clear : Color.paper).ignoresSafeArea())
        .newEntryButton(isShown: !usesColumns, dropTargets: siteFrames.filter { frame in sites.contains { $0.id == frame.key } },
                        dropSite: $dropSite)
        // Nothing else reloads the home page's posts, and a new one should be on it straight away.
        .onChange(of: publisher.sentCount) { Task { await refreshPosts() } }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
            }
        }
        // The system's toggle sits on the right of an open sidebar, where Settings goes. It's still
        // the way back once the sidebar is closed.
        .toolbar(removing: navigation.columnVisibility == .all ? .sidebarToggle : nil)
        .toolbar {
            if usesColumns {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { navigation.columnVisibility = .doubleColumn } } label: {
                        Label("Hide Sidebar", systemImage: "sidebar.left")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigation.showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            if usesColumns {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { navigation.openBlankEntry(in: context) } label: {
                        Label("New Entry", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    /// Tapping the selected row deselects it, which would empty the list column beside it.
    private var selection: Binding<SidebarItem?> {
        Binding(get: { navigation.sidebar }, set: { if let item = $0 { navigation.sidebar = item } })
    }

    @ViewBuilder private var rows: some View {
        if usesColumns {
            Section("Sites") {
                ForEach(sites) { site in
                    link(.site(site.id)) {
                        Label {
                            HStack {
                                Text(site.name)
                                Spacer()
                                Image(systemName: site.accessIcon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Circle().fill(site.color.color).frame(width: 10, height: 10)
                        }
                    }
                }
                addSite
            }
        } else {
            ForEach(sites) { site in
                Section {
                    link(.site(site.id)) { SiteCard(site: site) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { siteFrames[site.id] = $0 }
                        .listRowBackground(cardBackground(site))
                } header: {
                    if site.id == sites.first?.id {
                        Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.system(.subheadline, design: .monospaced))
                            .textCase(nil)
                            .accessibilityIdentifier("homeDate")
                    }
                }
            }
            Section { addSite }
        }

        // Only when something needs attention.
        if let outbox = outboxCount {
            Section {
                row("Outbox", "tray.and.arrow.up", .outbox, count: outbox,
                    alert: entries.contains { $0.state == .failed })
            }
        }

        if drafts > 0 {
            Section {
                row("Drafts", "doc.text", .drafts, count: drafts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if !usesColumns, !recentPosts.isEmpty {
            Section {
                ForEach(recentPosts) { RecentPostRow(post: $0.post, site: $0.site) }
            } header: {
                Text("Recent")
                    .font(.system(.subheadline, design: .monospaced))
                    .textCase(nil)
            }
        }
    }

    private var addSite: some View {
        Button {
            navigation.showingAddSite = true
        } label: {
            Label("Add Site", systemImage: "plus")
        }
    }

    private func cardBackground(_ site: Site) -> some View {
        Color.card.overlay(site.color.color.opacity(dropSite == site.id ? 0.4 : 0.12))
    }

    /// The last to change across every site, as last seen. Drafts and scheduled posts aren't out yet.
    private var recentPosts: [RecentPost] {
        let posts = sites.flatMap { site in
            site.cachedPostList.filter { $0.badge == nil }.map { RecentPost(post: $0, site: site) }
        }
        return Array(posts.sorted { ($0.post.lastChanged ?? .distantPast) > ($1.post.lastChanged ?? .distantPast) }.prefix(5))
    }

    private func refreshPosts() async {
        for site in sites where site.modelContext != nil && !site.isDeleted {
            _ = try? await publisher.loadPosts(of: site)
        }
    }

    private var drafts: Int {
        entries.filter { $0.state == .editing && !$0.isBlank }.count
    }

    /// Nil while sends are going normally: the outbox only matters on an error or a slow send.
    private var outboxCount: Int? {
        let waiting = entries.filter { [.queued, .sending, .failed].contains($0.state) }
        let needsAttention = waiting.contains {
            $0.state == .failed || $0.lastError != nil || now.timeIntervalSince($0.updatedAt) > 30
        }
        return needsAttention ? waiting.count : nil
    }

    /// In the iPad sidebar a row selects; on iPhone it pushes onto the stack.
    @ViewBuilder private func link(_ item: SidebarItem, @ViewBuilder label: () -> some View) -> some View {
        if usesColumns {
            // The gesture takes over from the List's selection, and also sees the selected row
            // being tapped again, which has to close the floating sidebar too.
            NavigationLink(value: item, label: label)
                .simultaneousGesture(TapGesture().onEnded {
                    navigation.sidebar = item
                    navigation.closeSidebarOverlay()
                })
        } else {
            NavigationLink(value: Route.list(item), label: label)
        }
    }

    private func row(_ title: String, _ icon: String, _ item: SidebarItem, count: Int, alert: Bool = false) -> some View {
        link(item) {
            Label {
                HStack {
                    Text(title)
                    Spacer()
                    if alert {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }
}

/// A site on the iPhone home page, with the latest post from its list.
private struct SiteCard: View {
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(site.color.color).frame(width: 10, height: 10)
                Text(site.name).font(.headline)
                Spacer()
                Image(systemName: site.accessIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let latest = site.cachedPostList.first {
                Text(latest.title)
                    .font(.system(.subheadline, design: .serif))
                    .italic(latest.isUntitled)
                    .lineLimit(2)
                if let date = latest.lastChanged {
                    Text(date.formatted(.relative(presentation: .named)).uppercased())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RecentPost: Identifiable {
    let post: SitePost
    let site: Site

    /// Two sites can use the same post ID.
    var id: String { "\(site.id)/\(post.id)" }
}

/// A post on the iPhone home page. A small dot is the only color, because the site's name does the
/// work and these sit under the tinted cards.
private struct RecentPostRow: View {
    let post: SitePost
    let site: Site

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL
    @State private var opening = false
    @State private var unsupported = false
    @State private var failure: String?

    var body: some View {
        if site.modelContext != nil, !site.isDeleted {
            Button { Task { await open() } } label: { label }
                .buttonStyle(.plain)
                .disabled(opening)
                .alert("Quill can't edit this post", isPresented: $unsupported) {
                    if let url = post.url { Button("Open in Browser") { openURL(url) } }
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("It has layouts Markdown can't hold, like galleries or embeds, and saving it here would remove them.")
                }
                .alert("Couldn't open this post", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(failure ?? "")
                }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(site.color.color).frame(width: 6, height: 6)
                Text(site.name.uppercased()).lineLimit(1)
                Spacer()
                if opening {
                    ProgressView().controlSize(.mini)
                } else if let date = post.lastChanged {
                    Text(date.formatted(.relative(presentation: .named)).uppercased())
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(post.title)
                .font(.system(.subheadline, design: .serif))
                .italic(post.isUntitled)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func open() async {
        opening = true
        defer { opening = false }
        let shownPath = navigation.path
        do {
            let entry = try await publisher.entry(for: post, on: site)
            // Someone who moved on while this loaded stays where they went.
            guard navigation.path == shownPath else { return }
            if let entry { navigation.show(entry) } else { unsupported = true }
        } catch {
            failure = error.localizedDescription
        }
    }
}
