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

/// Split-view state shared by the sidebar, list and editor.
@Observable
final class Navigation {
    var sidebar: SidebarItem?
    var selectedEntry: Entry? {
        didSet { if oldValue != selectedEntry { oldValue?.leaveEdit() } }
    }
    var path: [Route] = [] {
        didSet {
            if !path.contains(.editor) {
                selectedEntry?.leaveEdit()
                isFocused = false
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
    /// Mac: ⌘R asks whichever site list is showing to fetch its posts again.
    var reloadRequest = 0
    var canReload: Bool { if case .site = sidebar { true } else { false } }
    var windowWidth: CGFloat = .infinity

    static let defaultSiteKey = "defaultSiteID"

    /// The site new entries go to: the chosen default, else the last-used private site.
    func defaultSiteID(in context: ModelContext) -> UUID? {
        let sites = (try? context.fetch(FetchDescriptor<Site>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let raw = UserDefaults.standard.string(forKey: Self.defaultSiteKey),
           let id = UUID(uuidString: raw), sites.contains(where: { $0.id == id }) {
            return id
        }
        let candidates = sites.contains { !$0.isPublic } ? sites.filter { !$0.isPublic } : sites
        return candidates.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id
    }

    /// Reuse an empty draft if there is one, so the app opens to a blank page without piling up blanks.
    /// Given a site, the entry goes there and back returns to that site's list.
    func openBlankEntry(in context: ModelContext, focus: Bool = true, site: UUID? = nil) {
        let editing = Entry.State.editing.rawValue
        let drafts = (try? context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.stateRaw == editing && $0.remotePostID == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let siteID = site ?? defaultSiteID(in: context)
        let entry: Entry
        if let blank = drafts.first(where: \.isBlank) {
            entry = blank
            entry.createdAt = .now
            entry.siteID = siteID
            entry.hiddenTitle = nil
        } else {
            entry = Entry(siteID: siteID)
            context.insert(entry)
        }
        try? context.save()
        focusNextEntry = focus
        selectedEntry = entry
        path = (site.map { [.list(.site($0))] } ?? []) + [.editor]
        closeSidebarOverlay()
    }

    /// Call before a site's data is deleted, while the selected entry can still be read.
    func leaveSite(_ id: UUID) {
        if selectedEntry?.siteID == id { selectedEntry = nil }
        if sidebar == .site(id) { sidebar = nil }
        path = []
    }

    func show(_ entry: Entry) {
        selectedEntry = entry
        if path.last != .editor { path.append(.editor) }
    }

    /// The stack that matches the columns, for when an iPad window narrows.
    func rebuildPath() {
        path = (sidebar.map { [.list($0)] } ?? []) + (selectedEntry == nil ? [] : [.editor])
    }

    func closeSidebarOverlay() {
        if sidebarOverlays { withAnimation { columnVisibility = .doubleColumn } }
    }

    func toggleFocus() {
        withAnimation {
            if isFocused {
                isFocused = false
                columnVisibility = columnsBeforeFocus
            } else {
                columnsBeforeFocus = columnVisibility == .detailOnly ? .all : columnVisibility
                columnVisibility = .detailOnly
                isFocused = true
            }
        }
    }
}
