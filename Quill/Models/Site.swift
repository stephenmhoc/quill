import Foundation
import SwiftData
import SwiftUI

/// The kinds of site Quill can write to. To add one: add a case here, then the compiler points
/// at the rest, which is a `SiteBackend` in `Publisher.backend(for:)` and a form in `siteForm`.
enum SiteKind: String, CaseIterable, Identifiable {
    case ghost, local

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ghost: "Ghost"
        case .local: "Local"
        }
    }
    var summary: String {
        switch self {
        case .ghost: "Publish to a Ghost site with a staff access token."
        case .local: "Keep everything on this device. No account, no server."
        }
    }
    var systemImage: String {
        switch self {
        case .ghost: "network"
        case .local: "iphone"
        }
    }
    /// The send button for a new entry, and for an update.
    var publishLabel: String {
        switch self {
        case .ghost: "Publish"
        case .local: "Saved"
        }
    }
    var updateLabel: String {
        switch self {
        case .ghost: "Update"
        case .local: "Saved"
        }
    }
    /// How a finished entry describes itself.
    var doneLabel: String {
        switch self {
        case .ghost: "Published"
        case .local: "Saved"
        }
    }
}

/// A site Quill can write to. A Ghost site's key lives in the Keychain (see `Vault`), never here.
@Model
final class Site {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String = SiteKind.ghost.rawValue
    /// Empty for kinds of site with no address.
    var urlString: String
    /// Public sites get a confirmation before publishing.
    var isPublic: Bool
    var colorRaw: String
    var createdAt: Date
    var lastUsedAt: Date?

    init(name: String, url: URL, isPublic: Bool, color: SiteColor) {
        id = UUID()
        self.name = name
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

    var kind: SiteKind { SiteKind(rawValue: kindRaw) ?? .ghost }
    var url: URL? { URL(string: urlString) }
    var color: SiteColor {
        get { SiteColor(rawValue: colorRaw) ?? .rust }
        set { colorRaw = newValue.rawValue }
    }
    var host: String { url?.host() ?? urlString }

    /// Who can read this site, in words and as a symbol.
    var accessLabel: String { kind == .local ? "On this device" : isPublic ? "Public" : "Private" }
    var accessIcon: String { kind == .local ? "iphone" : isPublic ? "globe" : "lock" }
}

enum SiteColor: String, CaseIterable, Identifiable {
    case rust, ink, forest, ocean, plum, amber

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .rust: Color(red: 0.71, green: 0.27, blue: 0.17)
        case .ink: Color(red: 0.25, green: 0.27, blue: 0.33)
        case .forest: Color(red: 0.20, green: 0.45, blue: 0.30)
        case .ocean: Color(red: 0.13, green: 0.40, blue: 0.62)
        case .plum: Color(red: 0.49, green: 0.25, blue: 0.53)
        case .amber: Color(red: 0.78, green: 0.53, blue: 0.10)
        }
    }
    var label: String { rawValue.capitalized }
}
