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

    @Test func publishesUntitledEntry() async throws {
        let (publisher, site, client) = harness()
        let e = entry(site)
        await publisher.publish(e)
        #expect(e.state == .sent)
        #expect(e.remoteStatus == .published)
        let post = try await client.post(id: try #require(e.remotePostID))
        #expect(post.tags?.contains { $0.name == "#untitled" } == true)
        #expect(publisher.lastResult?.siteName == "Dev")
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
        await publisher.flushOutbox()
        #expect(e.state == .sent)
        #expect(e.remotePostID == id)
        #expect(try await count(client, title: title) == 1)
    }
}
