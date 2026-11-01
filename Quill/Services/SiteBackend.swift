import Foundation
import GhostKit
import SwiftData

/// A post as listed under a site, whichever kind of site it's on.
struct SitePost: Identifiable, Equatable, Codable {
    static let pageSize = 30

    let id: String
    let title: String
    let isUntitled: Bool
    let date: Date?
    /// Shown beside the date, e.g. "DRAFT". Nil for an ordinary published post.
    let badge: String?
    let url: URL?
}

/// A tag that posts can be filtered by. `id` is whatever the site filters on.
struct SiteTag: Identifiable, Hashable, Codable {
    let id: String
    let name: String
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
    /// With a tag, only its posts, from anywhere on the site.
    func posts(limit: Int, page: Int, tag: SiteTag?) async throws -> [SitePost]
    /// Totals for everything published, which can mean reading the whole site.
    func stats() async throws -> PostStats
    /// The entry for a listed post, brought into Quill if needed. Nil if Quill can't edit it safely.
    func entry(forPost id: String) async throws -> Entry?
    /// Updates an unedited copy of a post to match the site.
    func refresh(_ entry: Entry) async throws
    func deletePost(id: String) async throws
    func send(_ entry: Entry) async throws -> SentPost
    /// Accept the site's current version, so `send` replaces it instead of conflicting.
    func adoptLatestVersion(of entry: Entry) async throws
    /// Replace a conflicted entry with the site's current version.
    func takeLatestVersion(of entry: Entry) async throws
    func tags() async throws -> [String]
    /// Tags with posts, the ones worth offering first at the front.
    func filterTags() async throws -> [SiteTag]
    /// Stores an image and returns the URL to put in the Markdown.
    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL
    /// Called when the site is removed from Quill.
    func removeSiteData() throws
}

extension SiteBackend {
    func posts(limit: Int, page: Int) async throws -> [SitePost] {
        try await posts(limit: limit, page: page, tag: nil)
    }
}

extension Publisher {
    /// Only writes when something changed, because a write redraws every view of the site.
    func refreshTags(of site: Site) async {
        guard let tags = try? await backend(for: site).filterTags(), site.modelContext != nil, !site.isDeleted,
              let data = try? JSONEncoder().encode(tags), data != site.cachedTags else { return }
        site.cachedTags = data
        try? context.save()
    }

    /// Fetches a site's first page of posts and keeps it on the device for next time.
    func loadPosts(of site: Site) async throws -> [SitePost] {
        let posts = try await backend(for: site).posts(limit: SitePost.pageSize, page: 1)
        remember(posts, on: site)
        return posts
    }

    /// Only writes when something changed, because a write redraws every view of the site.
    func remember(_ posts: [SitePost], on site: Site) {
        guard site.modelContext != nil, !site.isDeleted,
              let data = try? JSONEncoder().encode(Array(posts.prefix(SitePost.pageSize))),
              data != site.cachedPosts else { return }
        site.cachedPosts = data
        try? context.save()
    }

    /// Totals walk a whole site, so they wait a minute between runs unless something's been sent.
    func refreshStats(of site: Site) async {
        if let last = statsChecked[site.id], last.sent == sentCount, last.at.timeIntervalSinceNow > -60 { return }
        statsChecked[site.id] = (.now, sentCount)
        guard let stats = try? await backend(for: site).stats(), site.modelContext != nil, !site.isDeleted,
              let data = try? JSONEncoder().encode(stats), data != site.cachedStats else { return }
        site.cachedStats = data
        try? context.save()
    }

    /// Freshens each site after unlocking, one at a time so it stays out of the way.
    func preloadPosts() async {
        let sites = (try? context.fetch(FetchDescriptor<Site>())) ?? []
        for site in sites where lock.canWork && !Task.isCancelled {
            guard site.modelContext != nil, !site.isDeleted else { continue }
            _ = try? await loadPosts(of: site)
            await refreshTags(of: site)
        }
        for site in sites where lock.canWork && !Task.isCancelled {
            guard site.modelContext != nil, !site.isDeleted else { continue }
            await refreshStats(of: site)
        }
    }

    func backend(for site: Site) throws -> any SiteBackend {
        switch site.kind {
        case .ghost: GhostBackend(client: try lock.client(for: site), site: site, context: context)
        case .microblog:
            MicroblogBackend(client: MicropubClient(token: try lock.key(for: site), destination: site.urlString),
                             site: site, context: context)
        case .local: LocalBackend(site: site, context: context)
        }
    }
}
