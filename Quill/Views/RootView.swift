import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Site.createdAt) private var sites: [Site]

    var body: some View {
        @Bindable var navigation = navigation
        ZStack {
            if lock.isUnlocked {
                NavigationSplitView(columnVisibility: $navigation.columnVisibility,
                                    preferredCompactColumn: $navigation.preferredCompactColumn) {
                    SidebarView()
                } content: {
                    ContentColumn()
                } detail: {
                    DetailColumn()
                }
                .navigationSplitViewStyle(.balanced)
                .sheet(isPresented: $navigation.showingSettings) { SettingsView() }
                .sheet(isPresented: $navigation.showingAddSite) { SiteFormView(site: nil) }
                .overlay(alignment: .top) { ResultBanner() }
                .task(id: lock.isUnlocked) { await runOutbox() }
                .onReceive(NotificationCenter.default.publisher(for: .quillNewEntry)) { _ in
                    navigation.openBlankEntry(in: context)
                }
                .onAppear {
                    if navigation.selectedEntry == nil { navigation.openBlankEntry(in: context) }
                    if sites.isEmpty { navigation.showingAddSite = true }
                }
            } else {
                LockView()
            }

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
            PrivacyWindow.shared.setVisible(phase != .active)
        }
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
        switch navigation.sidebar {
        case .site(let id): SitePostsView(siteID: id)
        case .some(let item): EntryListView(section: item)
        case nil: ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

private struct DetailColumn: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context

    var body: some View {
        if let entry = navigation.selectedEntry, entry.modelContext != nil {
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

/// Covers everything, sheets included, in the app switcher snapshot and while Face ID is up.
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
