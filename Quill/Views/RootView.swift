import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: Site.order) private var sites: [Site]
    @State private var cover = SceneCover()
    /// Before the first unlock there's nothing to keep, so the lock stands in for everything.
    /// After it, locking covers the scene instead, and the writing underneath stays as it was.
    @State private var hasUnlocked = false

    var body: some View {
        ZStack {
            if !hasUnlocked {
                LockView()
            } else if sites.isEmpty {
                AddSiteView(isRequired: true)
            } else {
                columnsOrStack
            }
        }
        .accessibilityHidden(hasUnlocked && !lock.isUnlocked)
        .background(SceneWindowReader { cover.window = $0 })
        .onChange(of: lock.isUnlocked, initial: true) { _, unlocked in
            if unlocked { hasUnlocked = true }
            cover.setLocked(hasUnlocked && !unlocked, lock: lock)
            takeRequest()
        }
        // Setting up the first site goes straight to writing on it.
        .onChange(of: sites.isEmpty) { _, isEmpty in
            if !isEmpty { navigation.openBlankEntry(in: context, focus: sizeClass != .regular) }
            takeRequest()
        }
        .onChange(of: AppRequests.shared.newEntry) { takeRequest() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // The whole app, not this scene: another of its windows can still be on screen.
            lock.didEnterBackground()
            try? context.save()
        }
        .onChange(of: scenePhase) { _, phase in
            cover.phase = phase
            switch phase {
            case .background:
                try? context.save()
            case .active:
                // Before the privacy cover lifts, so a lapsed grace period never shows the page.
                lock.didBecomeActive()
                cover.setLocked(hasUnlocked && !lock.isUnlocked, lock: lock)
                takeRequest()
            default:
                break
            }
            // Only on background: an unfocused iPad Split View scene is merely inactive.
            cover.setPrivate(phase == .background)
        }
    }

    @ViewBuilder private var columnsOrStack: some View {
        @Bindable var navigation = navigation
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
                    SidebarView()
                } content: {
                    ContentColumn()
                } detail: {
                    DetailColumn()
                }
                .navigationSplitViewStyle(.balanced)
                .onGeometryChange(for: Bool.self) { $0.size.width < 1100 } action: { overlays in
                    navigation.sidebarOverlays = overlays
                    // Focus mode keeps its one column at any width.
                    guard !navigation.isFocused else { return }
                    navigation.columnVisibility = overlays ? .doubleColumn : .all
                }
            } else {
                NavigationStack(path: $navigation.path) {
                    SidebarView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .list(let item): SectionList(item: item)
                            case .editor: DetailColumn()
                            }
                        }
                }
            }
        }
        .environment(\.usesColumns, sizeClass == .regular)
        .opensLinksInChosenBrowser()
        .sheet(isPresented: $navigation.showingSettings) { SettingsView() }
        .sheet(isPresented: $navigation.showingAddSite) { AddSiteView() }
        .sheet(item: Binding(get: { sites.first { $0.id == navigation.editingSite } },
                             set: { navigation.editingSite = $0?.id })) { EditSiteView(site: $0) }
        .task(id: lock.isUnlocked) { await runOutbox() }
        .task(id: lock.isUnlocked, priority: .utility) { await publisher.preloadPosts() }
        .onChange(of: sizeClass) { _, size in
            if size != .regular { navigation.rebuildPath() }
        }
        .onChange(of: sites.count) {
            repairSidebar()
            if sizeClass == .regular, navigation.selectedEntry == nil {
                navigation.openBlankEntry(in: context, focus: false)
            }
        }
        .onAppear {
            repairSidebar()
            // iPhone opens on home. iPad's detail column always has a page in it.
            if sizeClass == .regular, !sites.contains(where: { $0.id == navigation.selectedEntry?.siteID }) {
                navigation.openBlankEntry(in: context, focus: false)
            }
        }
    }

    /// A quick action or shortcut's new entry, once this window can show it.
    private func takeRequest() {
        guard let request = AppRequests.shared.newEntry, lock.isUnlocked, !sites.isEmpty, scenePhase == .active else { return }
        if let scene = request.sceneID, scene != cover.window?.windowScene?.session.persistentIdentifier { return }
        AppRequests.shared.newEntry = nil
        navigation.openBlankEntry(in: context, text: request.text)
    }

    private func repairSidebar() {
        if case .site(let id)? = navigation.sidebar, sites.contains(where: { $0.id == id }) { return }
        if case .drafts? = navigation.sidebar { return }
        if case .outbox? = navigation.sidebar { return }
        navigation.sidebar = sites.first.map { .site($0.id) }
    }

    /// Retry queued entries every minute while unlocked and in the foreground.
    private func runOutbox() async {
        while lock.isUnlocked && !Task.isCancelled {
            await publisher.flushOutbox()
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

private struct ContentColumn: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        if let item = navigation.sidebar {
            SectionList(item: item)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

private struct SectionList: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .site(let id): SitePostsView(siteID: id).id(id)
        default: EntryListView(section: item)
        }
    }
}

private struct DetailColumn: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context
    @Environment(\.usesColumns) private var usesColumns

    var body: some View {
        page.toolbar {
            // The sidebar's button is out of sight while the sidebar is.
            if usesColumns, navigation.columnVisibility != .all, !navigation.isFocused {
                ToolbarItem(placement: .topBarLeading) {
                    Button { navigation.openBlankEntry(in: context) } label: {
                        Label("New Entry", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    @ViewBuilder private var page: some View {
        if let entry = navigation.selectedEntry, entry.modelContext != nil, !entry.isDeleted {
            EditorView(entry: entry)
                .id(entry.id)
        } else if let opening = navigation.openingPost {
            OpeningPostView(opening: opening)
        } else {
            ContentUnavailableView {
                Label("No entry selected", systemImage: "square.and.pencil")
            } actions: {
                Button("New Entry") { navigation.openBlankEntry(in: context) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A post that's been tapped, while it comes from its site.
private struct OpeningPostView: View {
    let opening: OpeningPost

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL
    @Environment(\.usesColumns) private var usesColumns
    @Query private var sites: [Site]

    private var site: Site? { sites.first { $0.id == opening.siteID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(opening.post.title)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .italic(opening.post.isUntitled)
                .foregroundStyle(.secondary)
            if opening.isUnsupported {
                StatusNote(text: "Quill can't edit this post. It has layouts Markdown can't hold, like galleries or embeds, and saving it here would remove them.",
                           icon: "exclamationmark.triangle", color: .orange)
                if let url = opening.post.url { Button("Open in Browser") { openURL(url) }.buttonStyle(.bordered) }
            } else if let failure = opening.failure {
                StatusNote(text: failure, icon: "exclamationmark.triangle", color: .red)
                HStack {
                    if let site { Button("Try Again") { navigation.retryOpening(publisher: publisher, site: site) } }
                    if let url = opening.post.url { Button("Open in Browser") { openURL(url) } }
                }
                .buttonStyle(.bordered)
            } else {
                ProgressView().accessibilityLabel("Loading post")
            }
            Spacer()
        }
        .tint(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, usesColumns ? 48 : 20)
        .padding(.top, 20)
        .background(Color.paper.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
