import Foundation
import GhostKit
import SwiftData

struct GhostBackend: SiteBackend {
    let client: GhostClient
    let site: Site
    let context: ModelContext

    func posts(limit: Int, page: Int) async throws -> [SitePost] {
        try await client.recentPosts(limit: limit, page: page).map { post in
            let untitled = post.title == "(Untitled)" || post.tags?.contains { $0.name == EntryBuilder.untitledTag } == true
            return SitePost(id: post.id, title: untitled ? (post.excerpt ?? post.title) : post.title, isUntitled: untitled,
                            date: post.publishedAt, badge: post.status == .published ? nil : post.status.rawValue.uppercased(),
                            url: post.url)
        }
    }

    func entry(forPost id: String) async throws -> Entry? {
        let post = try await client.post(id: id)
        guard post.status == .published || post.status == .draft,
              let body = HTMLToMarkdown.convert(post.html ?? "") else { return nil }
        let tags = (post.tags ?? []).map(\.name)
        let entry = Entry(siteID: site.id)
        entry.title = tags.contains(EntryBuilder.untitledTag) || post.title == "(Untitled)" ? "" : post.title
        entry.body = body
        entry.tags = tags.filter { $0 != EntryBuilder.untitledTag }
        entry.publishStatus = post.status
        entry.createdAt = post.publishedAt ?? post.createdAt ?? .now
        entry.state = .sent
        entry.sentAt = entry.createdAt
        entry.remotePostID = post.id
        entry.remoteUpdatedAt = post.updatedAt
        entry.remoteURLString = post.url?.absoluteString
        entry.remoteStatusRaw = post.status.rawValue
        context.insert(entry)
        try context.save()
        return entry
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
                  let existing = try await findCreated(outgoing, since: attempted) {
            post = existing
        } else {
            if entry.createAttemptedAt == nil { entry.createAttemptedAt = .now }
            try context.save()
            // An entry that waited in the outbox is dated when it was written.
            var dated = outgoing
            if dated.status == .published { dated.publishedAt = entry.createdAt }
            post = try await client.createPost(dated)
        }
        return SentPost(id: post.id, updatedAt: post.updatedAt, url: post.url, status: post.status)
    }

    func adoptLatestVersion(of entry: Entry) async throws {
        guard let id = entry.remotePostID else { return }
        entry.remoteUpdatedAt = try await client.post(id: id).updatedAt
    }

    func tags() async throws -> [String] {
        try await client.tags().filter { !$0.isInternal }.map(\.name)
    }

    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL {
        try await client.uploadImage(jpeg, filename: filename, mimeType: "image/jpeg")
    }

    /// Posts stay in Ghost; there's nothing else here to clean up.
    func removeSiteData() throws {}

    private func resolvedUpdatedAt(_ entry: Entry, id: String) async throws -> String {
        if let known = entry.remoteUpdatedAt { return known }
        return try await client.post(id: id).updatedAt
    }

    /// After an attempt with an unknown outcome: did that post land? Title plus creation time
    /// identifies it; more than one match needs a human.
    private func findCreated(_ outgoing: OutgoingPost, since: Date) async throws -> GhostPost? {
        let cutoff = since.addingTimeInterval(-120) // allow for clock differences
        let matches = try await client.recentPosts(limit: 30).filter {
            $0.title == outgoing.title && ($0.createdAt ?? .distantPast) >= cutoff
        }
        if matches.count > 1 {
            throw GhostError.rejected("Found \(matches.count) posts with this title. Check Ghost for duplicates.")
        }
        return matches.first
    }
}
