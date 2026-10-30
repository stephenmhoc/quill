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

/// Split-view state shared by the sidebar, list and editor.
@Observable
final class Navigation {
    var sidebar: SidebarItem?
    var selectedEntry: Entry? {
        didSet { if oldValue != selectedEntry { oldValue?.cancelEdit() } }
    }
    var path: [Route] = [] {
        didSet { if !path.contains(.editor) { selectedEntry?.cancelEdit() } }
    }
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showingSettings = false
    var showingAddSite = false

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
    func openBlankEntry(in context: ModelContext) {
        let editing = Entry.State.editing.rawValue
        let drafts = (try? context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.stateRaw == editing && $0.remotePostID == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let entry: Entry
        if let blank = drafts.first(where: \.isBlank) {
            entry = blank
            entry.createdAt = .now
            entry.siteID = defaultSiteID(in: context)
        } else {
            entry = Entry(siteID: defaultSiteID(in: context))
            context.insert(entry)
        }
        try? context.save()
        selectedEntry = entry
        path = [.editor]
    }

    func show(_ entry: Entry) {
        selectedEntry = entry
        if path.last != .editor { path.append(.editor) }
    }

    func toggleFocus() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
        }
    }
}
