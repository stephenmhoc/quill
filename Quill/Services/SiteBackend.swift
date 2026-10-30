import Foundation
import GhostKit
import SwiftData

/// A post as listed under a site, whichever kind of site it's on.
struct SitePost: Identifiable, Equatable {
    let id: String
    let title: String
    let isUntitled: Bool
    let date: Date?
    /// Shown beside the date, e.g. "DRAFT". Nil for an ordinary published post.
    let badge: String?
    let url: URL?
}

/// What a backend reports after accepting an entry.
struct SentPost {
    let id: String
    let updatedAt: String?
    let url: URL?
    let status: GhostPost.Status
}

/// Everything the app needs from a kind of site. Views and the Publisher only talk to this;
/// `Publisher.backend(for:)` is the one place that picks an implementation.
protocol SiteBackend {
    func posts(limit: Int, page: Int) async throws -> [SitePost]
    /// The entry for a listed post, brought into Quill if needed. Nil if Quill can't edit it safely.
    func entry(forPost id: String) async throws -> Entry?
    func deletePost(id: String) async throws
    func send(_ entry: Entry) async throws -> SentPost
    /// Accept the site's current version, so `send` replaces it instead of conflicting.
    func adoptLatestVersion(of entry: Entry) async throws
    func tags() async throws -> [String]
    /// Stores an image and returns the URL to put in the Markdown.
    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL
    /// Called when the site is removed from Quill.
    func removeSiteData() throws
}

extension Publisher {
    func backend(for site: Site) throws -> any SiteBackend {
        switch site.kind {
        case .ghost: GhostBackend(client: try lock.client(for: site), site: site, context: context)
        case .local: LocalBackend(site: site, context: context)
        }
    }
}
