import Foundation
import GhostKit
import SwiftData

private struct UnsupportedPost: LocalizedError {
    var errorDescription: String? { "This post has content Quill can't show, so edit it in Ghost." }
}

struct GhostBackend: SiteBackend {
    let client: GhostClient
    let site: Site
    let context: ModelContext

    func posts(limit: Int, page: Int, tag: SiteTag?) async throws -> [SitePost] {
        try await client.recentPosts(limit: limit, page: page, tagSlug: tag?.id).map { post in
            let untitled = post.title == "(Untitled)" || post.tags?.contains { $0.name == EntryBuilder.untitledTag } == true
            return SitePost(id: post.id, title: untitled ? (post.excerpt ?? post.title) : post.title, isUntitled: untitled,
                            date: post.publishedAt, updatedAt: post.updatedDate, badge: post.status == .published ? nil : post.status.rawValue.uppercased(),
                            url: post.url, tags: post.tags?.compactMap(\.slug))
        }
    }

    func stats() async throws -> PostStats {
        try await client.publishedStats()
    }

    func entry(forPost id: String) async throws -> Entry? {
        let post = try await client.post(id: id)
        guard post.status == .published || post.status == .draft,
              let body = HTMLToMarkdown.convert(post.html ?? "") else { return nil }
        // A second tap can have finished importing while this one waited.
        if let existing = try Entry.copy(of: id, on: site.id, in: context) { return existing }
        let entry = Entry(siteID: site.id)
        apply(post, body: body, to: entry)
        entry.createdAt = post.publishedAt ?? post.createdAt ?? .now
        entry.state = .sent
        entry.sentAt = entry.createdAt
        context.insert(entry)
        try context.save()
        return entry
    }

    func refresh(_ entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let post = try await client.post(id: id)
        guard post.updatedAt != entry.remoteUpdatedAt, entry.state == .sent, !entry.isDeleted,
              post.status == .published || post.status == .draft,
              let body = HTMLToMarkdown.convert(post.html ?? "") else { return }
        apply(post, body: body, to: entry)
        try context.save()
    }

    private func apply(_ post: GhostPost, body: String, to entry: Entry) {
        let tags = (post.tags ?? []).map(\.name)
        entry.title = tags.contains(EntryBuilder.untitledTag) || post.title == "(Untitled)" ? "" : post.title
        entry.body = body
        entry.tags = tags.filter { $0 != EntryBuilder.untitledTag }
        entry.publishStatus = post.status
        entry.remotePostID = post.id
        entry.remoteUpdatedAt = post.updatedAt
        entry.remoteURLString = post.url?.absoluteString
        entry.remoteStatusRaw = post.status.rawValue
    }

    /// Permanently deletes a post from Ghost, and Quill's copy of it.
    func deletePost(id: String) async throws {
        do {
            try await client.deletePost(id: id)
        } catch GhostError.notFound {
            // Already gone from Ghost; still clear the local copy.
        }
        let siteID = site.id
        let local = FetchDescriptor<Entry>(predicate: #Predicate { $0.remotePostID == id && $0.siteID == siteID })
        for entry in try context.fetch(local) { context.delete(entry) }
        try context.save()
    }

    func send(_ entry: Entry) async throws -> SentPost {
        let outgoing = entry.outgoing()
        let post: GhostPost
        if let id = entry.remotePostID {
            let updatedAt = try await resolvedUpdatedAt(entry, id: id)
            post = try await client.updatePost(id: id, updatedAt: updatedAt, outgoing)
        } else if let attempted = entry.createAttemptedAt,
                  let existing = try await client.post(marker: entry.id.uuidString,
                                                        createdSince: attempted.addingTimeInterval(-120)) {
            // The two minutes allow for clock differences.
            post = existing
        } else {
            if entry.createAttemptedAt == nil { entry.createAttemptedAt = .now }
            try context.save()
            // An entry that waited in the outbox is dated when it was written.
            var dated = outgoing
            if dated.status == .published { dated.publishedAt = entry.createdAt }
            dated.marker = entry.id.uuidString
            post = try await client.createPost(dated)
        }
        return SentPost(id: post.id, updatedAt: post.updatedAt, url: post.url, status: post.status)
    }

    func adoptLatestVersion(of entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let latest = try await client.post(id: id).updatedAt
        // Edit can be tapped during the fetch; that entry is no longer overwriting anything.
        if entry.isConflict { entry.remoteUpdatedAt = latest }
    }

    func takeLatestVersion(of entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        let post = try await client.post(id: id)
        guard entry.isConflict, !entry.isDeleted else { return }
        guard post.status == .published || post.status == .draft,
              let body = HTMLToMarkdown.convert(post.html ?? "") else { throw UnsupportedPost() }
        apply(post, body: body, to: entry)
        entry.resolveConflict()
        try context.save()
    }

    func tags() async throws -> [String] {
        try await client.tags().filter { !$0.isInternal }.map(\.name)
    }

    func filterTags() async throws -> [SiteTag] {
        try await client.tags()
            .filter { !$0.isInternal && $0.name != EntryBuilder.untitledTag && ($0.count?.posts ?? 0) > 0 && $0.slug != nil }
            .sorted { ($0.count?.posts ?? 0) > ($1.count?.posts ?? 0) }
            .map { SiteTag(id: $0.slug ?? $0.name, name: $0.name) }
    }

    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL {
        try await client.uploadImage(jpeg, filename: filename, mimeType: "image/jpeg")
    }

    /// Posts stay in Ghost, so only Quill's copies of them go.
    func removeSiteData() throws { try Entry.removeCopies(on: site.id, in: context) }

    private func resolvedUpdatedAt(_ entry: Entry, id: String) async throws -> String {
        if let known = entry.remoteUpdatedAt { return known }
        return try await client.post(id: id).updatedAt
    }
}
