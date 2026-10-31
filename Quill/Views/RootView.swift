import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Site.createdAt) private var sites: [Site]

    var body: some View {
        @Bindable var navigation = navigation
        ZStack {
            if !lock.isUnlocked {
                LockView()
            } else if sites.isEmpty {
                AddSiteView(isRequired: true)
            } else {
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
                            if overlays { navigation.columnVisibility = .doubleColumn }
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
                .sheet(isPresented: $navigation.showingSettings) { SettingsView() }
                .sheet(isPresented: $navigation.showingAddSite) { AddSiteView() }
                .task(id: lock.isUnlocked) { await runOutbox() }
                .task(id: lock.isUnlocked, priority: .utility) { await publisher.preloadPosts() }
                .onReceive(NotificationCenter.default.publisher(for: .quillNewEntry)) { _ in
                    navigation.openBlankEntry(in: context)
                }
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
        }
        // Setting up the first site goes straight to writing on it.
        .onChange(of: sites.isEmpty) { _, isEmpty in
            if !isEmpty { navigation.openBlankEntry(in: context, focus: sizeClass != .regular) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.didEnterBackground()
                try? context.save()
            case .active:
                lock.didBecomeActive()
            default:
                break
            }
            // Only on background: an unfocused iPad Split View scene is merely inactive.
            PrivacyWindow.shared.setVisible(phase == .background)
        }
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

    var body: some View {
        if let entry = navigation.selectedEntry, entry.modelContext != nil, !entry.isDeleted {
            EditorView(entry: entry)
                .id(entry.id)
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

/// Covers everything, sheets included, in the app switcher snapshot.
/// It needs its own window because sheets sit above the root view.
final class PrivacyWindow {
    static let shared = PrivacyWindow()
    private var window: UIWindow?

    func setVisible(_ visible: Bool) {
        guard visible else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIHostingController(rootView: PrivacyCover())
        cover.isHidden = false
        window = cover
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Quill").font(.system(.title2, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}
