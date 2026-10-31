import AppKit
import SwiftData
import SwiftUI

struct MacRootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Query(sort: \Site.createdAt) private var sites: [Site]

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
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } content: {
                    MacContentColumn()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    MacDetailColumn()
                }
                .sheet(isPresented: $navigation.showingAddSite) { AddSiteView() }
                .task(id: lock.isUnlocked) { await runOutbox() }
                .task(id: lock.isUnlocked, priority: .utility) { await publisher.preloadPosts() }
                .onChange(of: sites.count) {
                    repairSidebar()
                    if navigation.selectedEntry == nil { navigation.openBlankEntry(in: context, focus: false) }
                }
                .onAppear {
                    repairSidebar()
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

    private func lockNow() {
        try? context.save()
        lock.lock()
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
