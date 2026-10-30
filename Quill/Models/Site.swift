import Foundation
import SwiftData
import SwiftUI

/// A Ghost site Quill can publish to. Its key lives in the Keychain (see `Vault`), never here.
@Model
final class Site {
    @Attribute(.unique) var id: UUID
    var name: String
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

    var url: URL? { URL(string: urlString) }
    var color: SiteColor {
        get { SiteColor(rawValue: colorRaw) ?? .rust }
        set { colorRaw = newValue.rawValue }
    }
    var host: String { url?.host() ?? urlString }
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
