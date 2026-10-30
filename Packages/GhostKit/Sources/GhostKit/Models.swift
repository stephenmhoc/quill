import Foundation

public struct GhostSiteInfo: Decodable, Sendable, Equatable {
    public let title: String
    public let url: URL
    public let icon: URL?
    public let version: String?
}

public struct GhostUser: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let email: String?
}

public struct GhostTag: Codable, Sendable, Equatable, Hashable {
    public let id: String?
    public let name: String
    public let slug: String?

    public init(name: String) {
        self.id = nil
        self.name = name
        self.slug = nil
    }

    /// Internal tags start with `#` and are never shown publicly.
    public var isInternal: Bool { name.hasPrefix("#") }
}

public struct GhostPost: Decodable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case draft, published, scheduled, sent
    }

    public let id: String
    public let title: String
    public let slug: String
    public let status: Status
    public let url: URL?
    /// Opaque server timestamp; must be echoed back on edits for collision detection.
    public let updatedAt: String
    public let createdAt: Date?
    public let publishedAt: Date?
    public let excerpt: String?
    public let tags: [GhostTag]?
    /// Only present when asked for: `post(id:)` includes it, lists don't.
    public let html: String?

    enum CodingKeys: String, CodingKey {
        case id, title, slug, status, url, excerpt, tags, html
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case publishedAt = "published_at"
    }
}

/// What Quill sends to Ghost.
public struct OutgoingPost: Sendable, Equatable {
    public var title: String
    public var html: String
    public var status: GhostPost.Status
    public var tags: [String]
    public var publishedAt: Date?

    public init(title: String, html: String, status: GhostPost.Status, tags: [String], publishedAt: Date? = nil) {
        self.title = title
        self.html = html
        self.status = status
        self.tags = tags
        self.publishedAt = publishedAt
    }
}
