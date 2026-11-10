import Foundation
import Observation
import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case drafts, outbox
    case site(UUID)
}

/// iPhone only: a stack with home at the root, so back from a new entry goes home.
enum Route: Hashable {
    case list(SidebarItem)
    case editor
}

extension EnvironmentValues {
    /// Whether the app is showing columns. Use this rather than the size class inside them:
    /// a split view reports its sidebar column as compact, even on a big iPad.
    @Entry var usesColumns = false
}

/// A listed post on its way into the editor, which shows it loading until it arrives.
struct OpeningPost: Equatable {
    let post: SitePost
    let siteID: UUID
    var failure: String?
    /// It has content Markdown can't hold, so Quill won't edit it.
    var isUnsupported = false
}

/// One window's state, shared by its sidebar, list and editor. Each iPad window has its own.
@Observable
final class Navigation {
    var sidebar: SidebarItem?
    var selectedEntry: Entry? {
        didSet {
            if oldValue != selectedEntry { oldValue?.leaveEdit() }
            if selectedEntry != nil { openingPost = nil }
        }
    }
    private(set) var openingPost: OpeningPost?
    var path: [Route] = [] {
        didSet {
            if !path.contains(.editor) {
                selectedEntry?.leaveEdit()
                isFocused = false
                openingPost = nil
            }
            if case .list(let item)? = path.first { sidebar = item }
        }
    }
    var columnVisibility: NavigationSplitViewVisibility = .all {
        // iPad's sidebar can be swiped back in.
        didSet {
            #if os(iOS)
            if columnVisibility != .detailOnly { isFocused = false }
            #endif
        }
    }
    /// Nothing on screen but the words: no columns, bars or buttons.
    private(set) var isFocused = false
    private var columnsBeforeFocus = NavigationSplitViewVisibility.all
    /// Narrow iPad: the sidebar floats over the list, so it closes once it's been used.
    var sidebarOverlays = false
    var showingSettings = false
    /// A blank page opened on request takes the keyboard. One opened at launch doesn't on iPad,
    /// where the keyboard would take half the screen before anyone asked to write.
    var focusNextEntry = false
    var showingAddSite = false
    /// A site whose settings are open from outside its own list, like a context menu.
    var editingSite: UUID?
    /// Mac: ⌘R asks whichever site list is showing to fetch its posts again.
    var reloadRequest = 0
    var canReload: Bool { if case .site = sidebar { true } else { false } }
    var windowWidth: CGFloat = .infinity
    #if os(iOS)
    /// The open page's text view, kept across a change between columns and a stack so its
    /// caret, scroll position, keyboard and undo survive.
    @ObservationIgnored let editorReuse = EditorReuse()
    #endif

    static let defaultSiteKey = "defaultSiteID"

    private struct Window { weak var navigation: Navigation? }
    /// Every window's navigation, so two windows don't both take the same blank page.
    private static var windows: [Window] = []

    init() {
        Self.windows.removeAll { $0.navigation == nil }
        Self.windows.append(Window(navigation: self))
    }

    private func isOpenElsewhere(_ entry: Entry) -> Bool {
        Self.windows.contains { $0.navigation !== self && $0.navigation?.selectedEntry == entry }
    }

    /// The site new entries go to: the chosen default, else the last-used private site.
    func defaultSiteID(in context: ModelContext) -> UUID? {
        let sites = (try? context.fetch(FetchDescriptor<Site>(sortBy: Site.order))) ?? []
        if let raw = UserDefaults.standard.string(forKey: Self.defaultSiteKey),
           let id = UUID(uuidString: raw), sites.contains(where: { $0.id == id }) {
            return id
        }
        let candidates = sites.contains { !$0.isPublic } ? sites.filter { !$0.isPublic } : sites
        return candidates.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id
    }

    /// Reuse an empty draft if there is one, so the app opens to a blank page without piling up blanks.
    /// Given a site, the entry goes there and back returns to that site's list. Given text, the
    /// page starts with it.
    func openBlankEntry(in context: ModelContext, focus: Bool = true, site: UUID? = nil, text: String? = nil) {
        let editing = Entry.State.editing.rawValue
        let drafts = (try? context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.stateRaw == editing && $0.remotePostID == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let siteID = site ?? defaultSiteID(in: context)
        let entry: Entry
        if let blank = drafts.first(where: { $0.isBlank && !isOpenElsewhere($0) }) {
            entry = blank
            entry.createdAt = .now
            entry.siteID = siteID
            entry.hiddenTitle = nil
        } else {
            entry = Entry(siteID: siteID)
            context.insert(entry)
        }
        if let text, !text.isEmpty { entry.body = text }
        try? context.save()
        focusNextEntry = focus
        selectedEntry = entry
        path = (site.map { [.list(.site($0))] } ?? []) + [.editor]
        closeSidebarOverlay()
    }

    /// Call before a site's data is deleted, while the selected entry can still be read. Every
    /// window lets go of it, not only this one.
    func leaveSite(_ id: UUID) {
        for window in Self.windows.compactMap(\.navigation) {
            let wasShowing = window.selectedEntry?.siteID == id || window.sidebar == .site(id)
                || window.path.contains(.list(.site(id)))
            if window.selectedEntry?.siteID == id { window.selectedEntry = nil }
            if window.sidebar == .site(id) { window.sidebar = nil }
            if window === self || wasShowing { window.path = [] }
        }
    }

    /// Call before an entry is deleted, so no window is left showing it.
    func forget(_ entry: Entry) {
        for window in Self.windows.compactMap(\.navigation) where window.selectedEntry == entry {
            window.selectedEntry = nil
        }
    }

    func show(_ entry: Entry) {
        selectedEntry = entry
        if path.last != .editor { path.append(.editor) }
    }

    /// A listed post opens at once: Quill's copy if there is one, brought up to date behind it,
    /// else a page that fills in when the post arrives.
    func open(_ post: SitePost, on site: Site, publisher: Publisher) {
        if let entry = try? Entry.copy(of: post.id, on: site.id, in: publisher.context) {
            show(entry)
            Task { await publisher.refresh(entry, site: site) }
            return
        }
        let request = OpeningPost(post: post, siteID: site.id)
        selectedEntry = nil
        openingPost = request
        if path.last != .editor { path.append(.editor) }
        closeSidebarOverlay()
        Task { await load(request, site: site, publisher: publisher) }
    }

    func retryOpening(publisher: Publisher, site: Site) {
        guard var request = openingPost else { return }
        request.failure = nil
        openingPost = request
        Task { await load(request, site: site, publisher: publisher) }
    }

    private func load(_ request: OpeningPost, site: Site, publisher: Publisher) async {
        do {
            let entry = try await publisher.importPost(id: request.post.id, site: site)
            // Someone who moved on while this loaded stays where they went.
            guard openingPost?.post.id == request.post.id, openingPost?.siteID == request.siteID else { return }
            if let entry { selectedEntry = entry } else { openingPost?.isUnsupported = true }
        } catch {
            guard openingPost?.post.id == request.post.id, openingPost?.siteID == request.siteID else { return }
            openingPost?.failure = error.localizedDescription
        }
    }

    /// The stack as it was when columns took over, while nothing has been chosen since.
    private var stackBeforeColumns: (path: [Route], sidebar: SidebarItem?, entry: Entry?)?

    func enterColumns() {
        stackBeforeColumns = (path, sidebar, selectedEntry)
    }

    /// The stack that matches the columns, for when an iPad window narrows. A big iPhone turned
    /// sideways and back without choosing anything comes back to the screen it left, even home.
    func rebuildPath() {
        defer { stackBeforeColumns = nil }
        if let saved = stackBeforeColumns, saved.sidebar == sidebar, saved.entry == selectedEntry {
            path = saved.path
            return
        }
        path = (sidebar.map { [.list($0)] } ?? []) + (selectedEntry == nil ? [] : [.editor])
    }

    func closeSidebarOverlay() {
        if sidebarOverlays { withAnimation { columnVisibility = .doubleColumn } }
    }

    func toggleFocus() {
        withAnimation {
            if isFocused {
                isFocused = false
                // The window may have narrowed meanwhile, and a narrow one floats its sidebar.
                let restored = sidebarOverlays && columnsBeforeFocus == .all ? .doubleColumn : columnsBeforeFocus
                columnVisibility = restored
                // Coming back from one column, the split view sets itself to two straight after,
                // so the sidebar stays hidden. Ask again once it has.
                #if os(iOS)
                guard restored == .all else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !isFocused, !sidebarOverlays, columnVisibility == .doubleColumn else { return }
                    withAnimation { columnVisibility = .all }
                }
                #endif
            } else {
                columnsBeforeFocus = columnVisibility == .detailOnly ? .all : columnVisibility
                columnVisibility = .detailOnly
                isFocused = true
            }
        }
    }
}
