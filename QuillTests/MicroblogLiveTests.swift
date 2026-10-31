import Foundation
import GhostKit
import SwiftData
import Testing
import UIKit
@testable import Quill

/// The real backend against a real Micro.blog account, which has real followers. Everything here
/// is a draft, because a published post can cross-post before it could be deleted, and every test
/// deletes what it made. Needs .dev/microblog.env; see TESTING.md.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MICROBLOG_TOKEN"] != nil))
struct MicroblogLiveTests {
    let container = try! ModelContainer(for: Site.self, Entry.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    var token: String { ProcessInfo.processInfo.environment["MICROBLOG_TOKEN"]! }

    private func harness() async throws -> (Publisher, Site, MicropubClient) {
        let blog = try #require(try await MicropubClient(token: token).destinations().first)
        let site = Site(name: "Blog", url: try #require(URL(string: blog.uid)), isPublic: true, color: .rust, kind: .microblog)
        context.insert(site)
        let lock = AppLock()
        lock.unlockForTesting(keys: [site.id: token])
        return (Publisher(lock: lock, context: context), site, MicropubClient(token: token, destination: blog.uid))
    }

    private func draft(_ site: Site, body: String, title: String = "") -> Entry {
        let e = Entry(siteID: site.id)
        e.title = title
        e.body = body
        e.publishStatus = .draft
        context.insert(e)
        return e
    }

    /// Runs `test` with a draft on the blog, and removes it whatever happens.
    private func withDraft(title: String = "", _ test: @MainActor (Publisher, Entry, MicropubClient, Site) async throws -> Void) async throws {
        let (publisher, site, client) = try await harness()
        let e = draft(site, body: "Quill test draft \(UUID())", title: title)
        await publisher.publish(e)
        let url = try #require(e.remotePostID, "\(e.lastError ?? "no post")")
        do {
            let created = try await client.post(url: url)
            #expect(created.status == .draft, "must never publish to a real blog")
            try await test(publisher, e, client, site)
        } catch {
            try? await client.delete(url: e.remotePostID ?? url)
            throw error
        }
        try? await client.delete(url: e.remotePostID ?? url)
        await #expect(throws: GhostError.notFound) { _ = try await client.post(url: e.remotePostID ?? url) }
    }

    @Test func draftRoundTripsWithItsMarkdown() async throws {
        try await withDraft(title: "Quill test") { publisher, e, client, site in
            e.body = "Some **bold** text with `code` and <angle> brackets.\n\n- a list"
            e.title = "Quill test, edited"
            e.state = .editing
            await publisher.publish(e)
            #expect(e.state == .sent)
            let post = try await client.post(url: try #require(e.remotePostID))
            #expect(post.title == "Quill test, edited")
            #expect(post.content == e.body)
            #expect(post.status == .draft)

            let listed = try await publisher.backend(for: site).posts(limit: 10, page: 1)
            #expect(listed.first { $0.id == e.remotePostID }?.badge == "DRAFT")
        }
    }

    @Test func untitledPostsListWithoutMarkdown() async throws {
        try await withDraft { publisher, e, _, site in
            e.body = "Read [this piece](https://example.com/a_b) about **real** _rowing_ snake_case ![](https://example.com/i.jpg)"
            e.state = .editing
            await publisher.publish(e)
            let listed = try await publisher.backend(for: site).posts(limit: 10, page: 1)
            #expect(listed.first { $0.id == e.remotePostID }?.title == "Read this piece about real rowing snake_case")
        }
    }

    @Test func aChangeOnTheBlogIsAConflict() async throws {
        try await withDraft { publisher, e, client, _ in
            let url = try #require(e.remotePostID)
            _ = try await client.update(url: url, title: "", content: "From the blog", categories: [], status: .draft)
            e.state = .editing
            e.body = "From Quill"
            await publisher.publish(e)
            #expect(e.isConflict)
            #expect(try await client.post(url: url).content == "From the blog")

            await publisher.overwrite(e)
            #expect(e.state == .sent)
            #expect(try await client.post(url: url).content == "From Quill")

            _ = try await client.update(url: url, title: "", content: "From the blog again", categories: [], status: .draft)
            e.state = .editing
            e.body = "Abandoned"
            await publisher.publish(e)
            #expect(e.isConflict)
            await publisher.takeSiteVersion(e)
            #expect(e.state == .sent)
            #expect(e.body == "From the blog again")
        }
    }

    @Test func cachedCopyRefreshesWhenOpened() async throws {
        try await withDraft { publisher, e, client, site in
            let url = try #require(e.remotePostID)
            _ = try await client.update(url: url, title: "", content: "Changed elsewhere", categories: [], status: .draft)
            await publisher.refresh(e, site: site)
            #expect(e.body == "Changed elsewhere")
            #expect(e.state == .sent)
        }
    }

    @Test func lostResponseAdoptsThePostInsteadOfDuplicating() async throws {
        try await withDraft { publisher, e, client, _ in
            let url = e.remotePostID
            e.remotePostID = nil
            e.remoteUpdatedAt = nil
            e.createAttemptedAt = .now.addingTimeInterval(-5)
            e.state = .queued
            await publisher.flushOutbox()
            #expect(e.state == .sent)
            #expect(e.remotePostID == url)
            let recent = try await client.posts(limit: 10, offset: 0)
            #expect(recent.filter { $0.content == e.body }.count == 1)
        }
    }

    @Test func importsAndDeletesAPost() async throws {
        let (publisher, site, client) = try await harness()
        let body = "Quill test draft \(UUID())"
        let url = try await client.create(title: "", content: body, categories: [], status: .draft, published: nil)
        do {
            let imported = try #require(try await publisher.importPost(id: url, site: site))
            #expect(imported.body == body)
            #expect(imported.remoteStatus == .draft)
            #expect(try await publisher.importPost(id: url, site: site) == imported, "imported twice")
            try await publisher.deletePost(id: url, site: site)
        } catch {
            try? await client.delete(url: url)
            throw error
        }
        await #expect(throws: GhostError.notFound) { _ = try await client.post(url: url) }
        #expect(try Entry.copy(of: url, on: site.id, in: context) == nil)
    }

    @Test func imagesUploadAndCanBeRemoved() async throws {
        let (publisher, site, client) = try await harness()
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.5) { $0.fill(.init(x: 0, y: 0, width: 8, height: 8)) }
        let url = try await publisher.backend(for: site).uploadImage(jpeg, filename: "quill-test-\(UUID().uuidString).jpg")
        #expect(url.path().contains("quill-test-"))
        try await client.deleteImage(url: url)
    }

    @Test func listsCategoriesAndPages() async throws {
        let (publisher, site, _) = try await harness()
        let backend = try publisher.backend(for: site)
        _ = try await backend.tags()
        let first = try await backend.posts(limit: 2, page: 1)
        let second = try await backend.posts(limit: 2, page: 2)
        #expect(first.count == 2)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}
