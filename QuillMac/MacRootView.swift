import AppKit
import SwiftData
import SwiftUI

struct MacRootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]
    /// Only an ID: the app's own state stays in its own locked-down store.
    @SceneStorage("selectedEntry") private var restoredEntry = ""

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if !lock.isUnlocked {
                LockView()
            } else if sites.isEmpty {
                AddSiteView(isRequired: true)
            } else {
                NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
                    MacSidebar()
                        .frame(minWidth: 230)
                        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 340)
                        .toolbar(removing: .sidebarToggle)
                } content: {
                    MacContentColumn()
                        .frame(minWidth: 320)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
                } detail: {
                    MacDetailColumn()
                }
                .background {
                    TitlebarButtons(toggleSidebar: toggleSidebar) { navigation.openBlankEntry(in: context) }
                }
                .sheet(isPresented: $navigation.showingAddSite) { AddSiteView() }
                .task(id: lock.isUnlocked) { await runOutbox() }
                .task(id: lock.isUnlocked, priority: .utility) { await publisher.preloadPosts() }
                .onChange(of: sites.count) {
                    repairSidebar()
                    if navigation.selectedEntry == nil { navigation.openBlankEntry(in: context, focus: false) }
                }
                .onChange(of: navigation.selectedEntry) { _, entry in
                    restoredEntry = entry?.id.uuidString ?? ""
                }
                .onAppear {
                    repairSidebar()
                    restoreEntry()
                    if !sites.contains(where: { $0.id == navigation.selectedEntry?.siteID }) {
                        navigation.openBlankEntry(in: context)
                    }
                }
            }
        }
        .onChange(of: sites.isEmpty) { _, isEmpty in
            if !isEmpty { navigation.openBlankEntry(in: context) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            lock.didResignActive()
            try? context.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lock.didBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            try? context.save()
        }
        // Stepping away from the Mac is a stronger signal than switching apps, so no grace here.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            lockNow()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            lockNow()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))) { _ in
            lockNow()
        }
    }

    private func toggleSidebar() {
        withAnimation { navigation.columnVisibility = navigation.columnVisibility == .all ? .doubleColumn : .all }
    }

    private func lockNow() {
        try? context.save()
        lock.lock()
    }

    /// Back to the entry that was open when Quill last quit.
    private func restoreEntry() {
        guard navigation.selectedEntry == nil, let id = UUID(uuidString: restoredEntry) else { return }
        navigation.selectedEntry = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })).first
    }

    private func repairSidebar() {
        if case .site(let id)? = navigation.sidebar, sites.contains(where: { $0.id == id }) { return }
        if case .drafts? = navigation.sidebar { return }
        if case .outbox? = navigation.sidebar { return }
        navigation.sidebar = sites.first.map { .site($0.id) }
    }

    /// Retry queued entries every minute while unlocked.
    private func runOutbox() async {
        while lock.isUnlocked && !Task.isCancelled {
            await publisher.flushOutbox()
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

/// The sidebar and new entry buttons, in the title bar beside the traffic lights: a toolbar item
/// would follow the sidebar's edge, and move when it closes.
private struct TitlebarButtons: NSViewRepresentable {
    let toggleSidebar: () -> Void
    let newEntry: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.toggleSidebar = toggleSidebar
        coordinator.newEntry = newEntry
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { coordinator.install(in: window) }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var toggleSidebar: () -> Void = {}
        var newEntry: () -> Void = {}
        private var accessory: NSTitlebarAccessoryViewController?

        func install(in window: NSWindow) {
            guard accessory == nil else { return }
            let buttons = HStack(spacing: 8) {
                button("sidebar.left", label: "Toggle Sidebar", help: "Show or hide the sidebar", id: "sidebarToggle") { [weak self] in
                    self?.toggleSidebar()
                }
                button("square.and.pencil", label: "New Entry", help: "New Entry (⌘N)", id: "newEntryButton") { [weak self] in
                    self?.newEntry()
                }
            }
            .padding(.horizontal, 6)
            let controller = NSTitlebarAccessoryViewController()
            let host = NSHostingView(rootView: buttons)
            host.frame.size = host.fittingSize
            controller.view = host
            controller.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller
        }

        private func button(_ icon: String, label: String, help: String, id: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
        }

        func remove() {
            accessory?.removeFromParent()
            accessory = nil
        }
    }
}

private struct MacContentColumn: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        switch navigation.sidebar {
        case .site(let id): SitePostsView(siteID: id).id(id)
        case let item?: EntryListView(section: item)
        case nil: ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

private struct MacDetailColumn: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context

    var body: some View {
        if let entry = navigation.selectedEntry, entry.modelContext != nil, !entry.isDeleted {
            MacEditorView(entry: entry)
                .id(entry.id)
        } else {
            ContentUnavailableView {
                Label("No entry selected", systemImage: "square.and.pencil")
            } actions: {
                Button("New Entry") { navigation.openBlankEntry(in: context) }
            }
        }
    }
}
