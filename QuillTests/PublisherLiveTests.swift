import Foundation
import GhostKit
import SwiftData
import Testing
@testable import Quill

/// The real Publisher against the throwaway dev Ghost. Run with scripts/test-app.sh.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GHOST_DEV_ADMIN_KEY"] != nil))
struct PublisherLiveTests {
    let env = ProcessInfo.processInfo.environment
    let container = try! ModelContainer(for: Site.self, Entry.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    var key: String { env["GHOST_DEV_ADMIN_KEY"]! }
    var url: URL { URL(string: env["GHOST_DEV_URL"]!)! }

    private func harness(url: URL? = nil, key: String? = nil) -> (Publisher, Site, GhostClient) {
        let site = Site(name: "Dev", url: url ?? self.url, isPublic: false, color: .rust)
        context.insert(site)
        let lock = AppLock()
        lock.unlockForTesting(keys: [site.id: key ?? self.key])
        let client = GhostClient(baseURL: self.url, credentials: try! GhostCredentials(apiKey: self.key))
        return (Publisher(lock: lock, context: context), site, client)
    }

    private func entry(_ site: Site, body: String = "Body \(UUID())", title: String = "") -> Entry {
        let e = Entry(siteID: site.id)
        e.title = title
        e.body = body
        context.insert(e)
        return e
    }

    private func count(_ client: GhostClient, title: String) async throws -> Int {
        try await client.recentPosts(limit: 50).filter { $0.title == title }.count
    }

    @Test func preloadKeepsEachSitesPostsOnTheDevice() async throws {
        let (publisher, site, client) = harness()
        let title = "Cached \(UUID())"
        let post = try await client.createPost(OutgoingPost(title: title, html: "<p>Kept</p>", status: .published, tags: []))
        defer { Task { try? await client.deletePost(id: post.id) } }
        await publisher.preloadPosts()
        let cached = site.cachedPostList
        #expect(cached.contains { $0.title == title })

        // Offline, the list still has what it last saw.
        let (offline, dead, _) = harness(url: URL(string: "http://127.0.0.1:9")!)
        dead.cachedPosts = site.cachedPosts
        await offline.preloadPosts()
        #expect(dead.cachedPostList == cached)
    }

    @Test func statsCountPublishedPostsOnly() async throws {
        let (publisher, site, client) = harness()
        try await Task.sleep(for: .seconds(2)) // earlier tests delete their posts in the background
        let before = try await publisher.backend(for: site).stats()
        let post = try await client.createPost(OutgoingPost(title: "Stats \(UUID())", html: "<p>Four words right here</p>",
                                                            status: .published, tags: []))
        let draft = try await client.createPost(OutgoingPost(title: "Hidden \(UUID())", html: "<p>Not counted</p>",
                                                             status: .draft, tags: []))
        defer {
            Task {
                try? await client.deletePost(id: post.id)
                try? await client.deletePost(id: draft.id)
            }
        }
        let after = try await publisher.backend(for: site).stats()
        #expect(after.posts == before.posts + 1, "\(before) -> \(after)")
        #expect(after.words == before.words + 4, "\(before) -> \(after)")
        await publisher.refreshStats(of: site)
        #expect(site.stats == after)
    }

    @Test func localSiteSavesWithoutAnyServer() async throws {
        let site = Site(name: "Notebook", kind: .local, color: .plum)
        context.insert(site)
        let lock = AppLock()
        lock.unlockForTesting(keys: [:])
        let publisher = Publisher(lock: lock, context: context)
        let e = entry(site)
        await publisher.publish(e)
        #expect(e.state == .sent)
        #expect(e.remotePostID == e.id.uuidString)
        #expect(e.remoteURL == nil)
        let listed = try await publisher.backend(for: site).posts(limit: 10, page: 1)
        #expect(listed.map(\.id) == [e.id.uuidString])
        #expect(try await publisher.backend(for: site).stats().posts == 1)
        try await publisher.deletePost(id: e.id.uuidString, site: site)
        #expect(try await publisher.backend(for: site).posts(limit: 10, page: 1).isEmpty)
    }

    @Test func publishesUntitledEntry() async throws {
        let (publisher, site, client) = harness()
        let e = entry(site)
        await publisher.publish(e)
        #expect(e.state == .sent)
        #expect(e.remoteStatus == .published)
        let post = try await client.post(id: try #require(e.remotePostID))
        #expect(post.tags?.contains { $0.name == "#untitled" } == true)
        #expect(publisher.sentCount == 1)
    }

    @Test func unreachableStaysQueuedThenFlushesExactlyOnce() async throws {
        let (publisher, site, client) = harness(url: URL(string: "http://localhost:9")!)
        let title = "Outbox \(UUID())"
        let e = entry(site, title: title)
        await publisher.publish(e)
        #expect(e.state == .queued)
        #expect(e.lastError != nil)

        site.urlString = url.absoluteString   // "Tailscale came back"
        await publisher.flushOutbox()
        await publisher.flushOutbox()
        #expect(e.state == .sent)
        #expect(try await count(client, title: title) == 1)
    }

    @Test func staleEditIsConflictThenOverwriteWins() async throws {
        let (publisher, site, client) = harness()
        let e = entry(site, title: "Conflict \(UUID())")
        await publisher.publish(e)
        let id = try #require(e.remotePostID)

        // Ghost's updated_at has one-second precision.
        try await Task.sleep(for: .seconds(1.1))
        // Someone edits in Ghost Admin.
        _ = try await client.updatePost(id: id, updatedAt: try #require(e.remoteUpdatedAt),
                                        OutgoingPost(title: "From Ghost", html: "<p>x</p>", status: .published, tags: []))
        e.state = .editing
        e.title = "From Quill"
        await publisher.publish(e)
        #expect(e.state == .failed)
        #expect(e.isConflict)
        #expect(try await client.post(id: id).title == "From Ghost")

        await publisher.overwrite(e)
        #expect(e.state == .sent)
        #expect(try await client.post(id: id).title == "From Quill")
    }

    @Test func conflictCanTakeGhostsVersion() async throws {
        let (publisher, site, client) = harness()
        let e = entry(site, title: "Conflict \(UUID())")
        await publisher.publish(e)
        let id = try #require(e.remotePostID)

        try await Task.sleep(for: .seconds(1.1))
        _ = try await client.updatePost(id: id, updatedAt: try #require(e.remoteUpdatedAt),
                                        OutgoingPost(title: "From Ghost", html: "<p>Written there</p>", status: .published, tags: []))
        e.state = .editing
        e.title = "From Quill"
        await publisher.publish(e)
        #expect(e.isConflict)

        await publisher.takeSiteVersion(e)
        #expect(e.state == .sent)
        #expect(e.title == "From Ghost")
        #expect(e.body == "Written there")
        #expect(try await client.post(id: id).title == "From Ghost")
    }

    @Test func doubleTapPublishCreatesOnePost() async throws {
        let (publisher, site, client) = harness()
        let title = "Double \(UUID())"
        let e = entry(site, title: title)
        let first = Task { await publisher.publish(e) }
        let second = Task { await publisher.publish(e) }
        await first.value
        await second.value
        await publisher.flushOutbox()
        #expect(e.state == .sent)
        #expect(try await count(client, title: title) == 1)
    }

    @Test func lostResponseAdoptsThePostInsteadOfDuplicating() async throws {
        let (publisher, site, client) = harness()
        let title = "Lost \(UUID())"
        let e = entry(site, title: title)
        await publisher.publish(e)
        let id = e.remotePostID

        // Ghost created the post, but the phone never heard back.
        e.remotePostID = nil
        e.remoteUpdatedAt = nil
        e.createAttemptedAt = .now.addingTimeInterval(-5)
        e.state = .queued
        // A post with the same title isn't this one, and the entry's own title can't be relied on.
        _ = try await client.createPost(OutgoingPost(title: title, html: "<p>Another</p>", status: .published, tags: []))
        await publisher.flushOutbox()
        #expect(e.state == .sent)
        #expect(e.remotePostID == id)
        #expect(try await count(client, title: title) == 2)
    }

    @Test func editsThenDeletesAPostWrittenElsewhere() async throws {
        let (publisher, site, client) = harness()
        let markdown = """
            # Heading

            Some **bold**, *italic*, `code`, ~~gone~~ and a [link](https://example.com/a?b=1) with 2 \\* stars.

            - one
            - two
              - nested

            1. first
            2. second

            > quoted line
            >
            > second paragraph

            ```swift
            let x = 1 < 2
            ```

            ---

            ![alt text](https://example.com/photo.jpg)
            """
        let title = "Elsewhere \(UUID())"
        let created = try await client.createPost(OutgoingPost(title: title, html: EntryBuilder.html(fromMarkdown: markdown),
                                                               status: .published, tags: ["elsewhere"]))

        let e = try #require(try await publisher.importPost(id: created.id, site: site))
        #expect(e.title == title)
        #expect(e.body == markdown)
        #expect(e.tags == ["elsewhere"])

        e.state = .editing
        e.body += "\n\nAdded in Quill"
        await publisher.publish(e)
        #expect(e.state == .sent)
        let updated = try await client.post(id: created.id)
        #expect(updated.html?.contains("Added in Quill") == true)
        #expect(updated.html?.contains("<strong>bold</strong>") == true)
        #expect(updated.tags?.map(\.name) == ["elsewhere"])

        try await publisher.deletePost(id: created.id, site: site)
        await #expect(throws: GhostError.notFound) { try await client.post(id: created.id) }
        #expect(try context.fetch(FetchDescriptor<Entry>()).allSatisfy { $0.remotePostID != created.id })
    }

    @Test func refusesToEditWhatMarkdownCantHold() async throws {
        let (publisher, site, client) = harness()
        let html = "<!--kg-card-begin: html--><div style=\"color:red\">Custom</div><!--kg-card-end: html-->"
        let created = try await client.createPost(OutgoingPost(title: "Card \(UUID())", html: html, status: .draft, tags: []))
        #expect(try await publisher.importPost(id: created.id, site: site) == nil)
        try await publisher.deletePost(id: created.id, site: site)
    }

    @Test func pagesThroughHistory() async throws {
        let (_, _, client) = harness()
        for _ in 0..<3 { _ = try await client.createPost(OutgoingPost(title: "Page \(UUID())", html: "<p>x</p>", status: .draft, tags: [])) }
        let first = try await client.recentPosts(limit: 2)
        let second = try await client.recentPosts(limit: 2, page: 2)
        #expect(first.count == 2)
        #expect(!second.isEmpty)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}
