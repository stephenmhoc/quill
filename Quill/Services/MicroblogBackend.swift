import Foundation
import GhostKit
import SwiftData

/// A blog on Micro.blog, written in Markdown. Micropub identifies a post by its URL, so that's the
/// post ID. It has no `updated_at`, so `remoteUpdatedAt` holds the post's `version` fingerprint.
struct MicroblogBackend: SiteBackend {
    let client: MicropubClient
    let site: Site
    let context: ModelContext

    func posts(limit: Int, page: Int, tag: SiteTag?) async throws -> [SitePost] {
        guard let tag else {
            return try await client.posts(limit: limit, offset: limit * (page - 1)).map(sitePost)
        }
        // Micropub ignores a category filter, so this reads the blog, and answers in one page.
        guard page == 1 else { return [] }
        var tagged: [SitePost] = []
        var offset = 0
        while true {
            let batch = try await client.posts(limit: 100, offset: offset)
            guard !batch.isEmpty else { return tagged }
            tagged += batch.filter { $0.categories.contains(tag.name) }.map(sitePost)
            offset += batch.count
        }
    }

    /// Micropub has no update date, so the only edits it can know about are the ones sent from here.
    private func sitePost(_ post: MicropubPost) -> SitePost {
        SitePost(id: post.url, title: post.title.isEmpty ? Self.excerpt(of: post.content) : post.title,
                 isUntitled: post.title.isEmpty, date: post.published,
                 updatedAt: (try? Entry.copy(of: post.url, on: site.id, in: context))??.sentAt,
                 badge: post.status == .draft ? "DRAFT" : nil, url: URL(string: post.url), tags: post.categories)
    }

    func stats() async throws -> PostStats {
        try await client.publishedStats()
    }

    func entry(forPost id: String) async throws -> Entry? {
        let post = try await client.post(url: id)
        if let existing = try Entry.copy(of: id, on: site.id, in: context) { return existing }
        let entry = Entry(siteID: site.id)
        apply(post, to: entry)
        entry.createdAt = post.published ?? .now
        entry.state = .sent
        entry.sentAt = entry.createdAt
        context.insert(entry)
        try context.save()
        return entry
    }

    func refresh(_ entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let post = try await client.post(url: id)
        guard post.version != entry.remoteUpdatedAt, entry.state == .sent, !entry.isDeleted else { return }
        apply(post, to: entry)
        try context.save()
    }

    func deletePost(id: String) async throws {
        do {
            try await client.delete(url: id)
        } catch GhostError.notFound {
            // Already gone from the blog; still clear the local copy.
        }
        if let local = try Entry.copy(of: id, on: site.id, in: context) { context.delete(local) }
        try context.save()
    }

    func send(_ entry: Entry) async throws -> SentPost {
        let url: String
        if let id = entry.remotePostID {
            // Nothing server-side rejects a stale edit, so compare first.
            let current = try await client.post(url: id)
            if let known = entry.remoteUpdatedAt, known != current.version { throw GhostError.conflict("") }
            url = try await client.update(url: id, title: entry.title, content: entry.body, categories: entry.tags,
                                          status: entry.publishStatus)
        } else if let attempted = entry.createAttemptedAt, let landed = try await findCreated(entry, since: attempted) {
            url = landed
        } else {
            if entry.createAttemptedAt == nil { entry.createAttemptedAt = .now }
            try context.save()
            url = try await client.create(title: entry.title, content: entry.body, categories: entry.tags,
                                          status: entry.publishStatus, published: entry.createdAt)
        }
        let post = try await client.post(url: url)
        return SentPost(id: url, updatedAt: post.version, url: URL(string: url), status: post.status)
    }

    func adoptLatestVersion(of entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let latest = try await client.post(url: id).version
        if entry.isConflict { entry.remoteUpdatedAt = latest }
    }

    func takeLatestVersion(of entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let post = try await client.post(url: id)
        guard entry.isConflict, !entry.isDeleted else { return }
        apply(post, to: entry)
        entry.resolveConflict()
        try context.save()
    }

    func tags() async throws -> [String] { try await client.categories() }

    func filterTags() async throws -> [SiteTag] {
        try await client.categories().map { SiteTag(id: $0, name: $0) }
    }

    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL {
        try await client.uploadImage(jpeg, filename: filename, mimeType: "image/jpeg")
    }

    /// Posts stay on the blog, so only Quill's copies of them go.
    func removeSiteData() throws { try Entry.removeCopies(on: site.id, in: context) }

    /// An untitled post's text for a list, without its Markdown.
    private static func excerpt(of markdown: String) -> String {
        let text = markdown
            .replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
            .replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
            .replacing(/(^|\W)[*_`]+/) { String($0.output.1) } // leaving snake_case alone
            .replacing(/[*_`]+(\W|$)/) { String($0.output.1) }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private func apply(_ post: MicropubPost, to entry: Entry) {
        entry.title = post.title
        entry.body = post.content
        entry.tags = post.categories
        entry.publishStatus = post.status
        entry.remotePostID = post.url
        entry.remoteUpdatedAt = post.version
        entry.remoteURLString = post.url
        entry.remoteStatusRaw = post.status.rawValue
    }

    /// After an attempt with an unknown outcome: did that post land? Posts keep the exact text
    /// they were sent with, which identifies them.
    private func findCreated(_ entry: Entry, since attempted: Date) async throws -> String? {
        let cutoff = attempted.addingTimeInterval(-120) // allow for clock differences
        return try await client.posts(limit: 50, offset: 0).first {
            $0.content == entry.body && $0.title == entry.title && ($0.published ?? .distantPast) >= min(cutoff, entry.createdAt)
        }?.url
    }
}
