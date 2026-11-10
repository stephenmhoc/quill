import Foundation
import GhostKit
import SwiftData
import SwiftUI

/// The kinds of site Quill can write to. To add one: add a case here, then the compiler points
/// at the rest, which is a `SiteBackend` in `Publisher.backend(for:)` and a form in `siteForm`.
enum SiteKind: String, CaseIterable, Identifiable {
    case ghost, microblog, local

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ghost: "Ghost"
        case .microblog: "Micro.blog"
        case .local: "Local"
        }
    }
    var summary: String {
        switch self {
        case .ghost: "Publish to a Ghost site with a staff access token."
        case .microblog: "Publish to your Micro.blog with an app token."
        case .local: "Keep everything on \(thisDevice). No account, no server."
        }
    }
    var systemImage: String {
        switch self {
        case .ghost: "network"
        case .microblog: "at"
        case .local: localDeviceIcon
        }
    }
    /// The send button for a new entry, and for an update.
    var publishLabel: String {
        switch self {
        case .ghost, .microblog: "Publish"
        case .local: "Save"
        }
    }
    var updateLabel: String {
        switch self {
        case .ghost, .microblog: "Update"
        case .local: "Save"
        }
    }
    /// ⌘S on a Mac: a local site's Publish is a save, so the key does what the button says.
    var sendsOnSave: Bool {
        switch self {
        case .ghost, .microblog: false
        case .local: true
        }
    }
    /// What removing a site from Quill does, shown before it happens.
    var removalNote: String {
        switch self {
        case .ghost: "Removes the site and its key from \(thisDevice). Nothing changes in Ghost."
        case .microblog: "Removes the site and its token from \(thisDevice). Nothing changes on Micro.blog."
        case .local: "Permanently deletes this site and every entry on it."
        }
    }
    /// How a finished entry describes itself.
    var doneLabel: String {
        switch self {
        case .ghost, .microblog: "Published"
        case .local: "Saved"
        }
    }
}

/// A site Quill can write to. A site's key lives in the Keychain (see `Vault`), never here.
@Model
final class Site {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String = SiteKind.ghost.rawValue
    /// Empty for kinds of site with no address.
    var urlString: String
    /// Public sites get a confirmation before an image is uploaded.
    var isPublic: Bool
    var colorRaw: String
    var createdAt: Date
    /// Where the site sits in every list, set by dragging. Ties, like sites from before there
    /// was an order, fall back to `createdAt`.
    var sortIndex: Int = 0
    var lastUsedAt: Date?
    /// The first page of posts as last seen, so the list can appear before the site answers.
    var cachedPosts: Data?
    var cachedStats: Data?
    var cachedTags: Data?

    init(name: String, url: URL, isPublic: Bool, color: SiteColor, kind: SiteKind = .ghost) {
        id = UUID()
        self.name = name
        kindRaw = kind.rawValue
        urlString = url.absoluteString
        self.isPublic = isPublic
        colorRaw = color.rawValue
        createdAt = .now
    }

    /// A site with no address, like a local one.
    init(name: String, kind: SiteKind, color: SiteColor) {
        id = UUID()
        self.name = name
        kindRaw = kind.rawValue
        urlString = ""
        isPublic = false
        colorRaw = color.rawValue
        createdAt = .now
    }

    /// The order every list of sites uses.
    static let order = [SortDescriptor(\Site.sortIndex), SortDescriptor(\Site.createdAt)]

    /// Inserts a new site after the others.
    static func add(_ site: Site, to context: ModelContext) {
        let sites = (try? context.fetch(FetchDescriptor<Site>(sortBy: order))) ?? []
        site.sortIndex = (sites.last?.sortIndex ?? -1) + 1
        context.insert(site)
    }

    /// Renumbers every site after a drag, so the new order is the only one.
    static func move(_ sites: [Site], from source: IndexSet, to destination: Int) {
        var ordered = sites
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, site) in ordered.enumerated() where site.sortIndex != index {
            site.sortIndex = index
        }
    }

    var kind: SiteKind { SiteKind(rawValue: kindRaw) ?? .ghost }
    var url: URL? { URL(string: urlString) }
    var color: SiteColor {
        get { SiteColor(rawValue: colorRaw) ?? .rust }
        set { colorRaw = newValue.rawValue }
    }
    var host: String { url?.host() ?? urlString }
    var stats: PostStats? {
        cachedStats.flatMap { try? JSONDecoder().decode(PostStats.self, from: $0) }
    }
    var cachedPostList: [SitePost] {
        cachedPosts.flatMap { try? JSONDecoder().decode([SitePost].self, from: $0) } ?? []
    }

    /// Kept with the posts, so the list has its final shape from the first frame.
    var cachedTagList: [SiteTag] {
        cachedTags.flatMap { try? JSONDecoder().decode([SiteTag].self, from: $0) } ?? []
    }

    /// Who can read this site, in words and as a symbol.
    var accessLabel: String { kind == .local ? "On \(thisDevice)" : isPublic ? "Public" : "Private" }
    var accessIcon: String { kind == .local ? localDeviceIcon : isPublic ? "globe" : "lock" }

    /// False once the site is deleted, when reading its properties would crash.
    var isLive: Bool { modelContext != nil && !isDeleted }
}

nonisolated private var localDeviceIcon: String {
    #if os(macOS)
    "desktopcomputer"
    #else
    "iphone"
    #endif
}

enum SiteColor: String, CaseIterable, Identifiable {
    case rust, ink, forest, ocean, plum, amber

    var id: String { rawValue }
    /// Each has a lighter version for dark mode, where the darker ones would disappear.
    var color: Color {
        switch self {
        case .rust: Self.adaptive(light: (0.71, 0.27, 0.17), dark: (0.88, 0.47, 0.37))
        case .ink: Self.adaptive(light: (0.25, 0.27, 0.33), dark: (0.66, 0.70, 0.79))
        case .forest: Self.adaptive(light: (0.20, 0.45, 0.30), dark: (0.42, 0.72, 0.52))
        case .ocean: Self.adaptive(light: (0.13, 0.40, 0.62), dark: (0.38, 0.64, 0.88))
        case .plum: Self.adaptive(light: (0.49, 0.25, 0.53), dark: (0.74, 0.53, 0.80))
        case .amber: Self.adaptive(light: (0.78, 0.53, 0.10), dark: (0.93, 0.71, 0.32))
        }
    }

    private typealias RGB = (Double, Double, Double)

    private static func adaptive(light: RGB, dark: RGB) -> Color {
        #if os(macOS)
        Color(NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    var label: String { rawValue.capitalized }
}
