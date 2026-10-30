import CryptoKit
import Foundation
import Testing
@testable import GhostKit

private let sampleKey = "6ae4057d55c8400001a47b58:" + String(repeating: "ab", count: 32)

@Suite struct CredentialsTests {
    @Test func parsesIdAndSecret() throws {
        let creds = try GhostCredentials(apiKey: "  \(sampleKey)\n")
        #expect(creds.id == "6ae4057d55c8400001a47b58")
        #expect(creds.apiKey == sampleKey)
    }

    @Test(arguments: ["", "nocolon", ":abcd", "id:nothex!!", "id:abcd", "a:b:c"])
    func rejectsMalformedKeys(_ key: String) {
        #expect(throws: GhostError.invalidKey) { try GhostCredentials(apiKey: key) }
    }

    @Test func tokenIsAValidHS256JWT() throws {
        let creds = try GhostCredentials(apiKey: sampleKey)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parts = creds.token(now: now).split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try JSONSerialization.jsonObject(with: base64URLDecode(parts[0])) as! [String: String]
        #expect(header == ["alg": "HS256", "typ": "JWT", "kid": creds.id])
        let payload = try JSONSerialization.jsonObject(with: base64URLDecode(parts[1])) as! [String: Any]
        #expect(payload["aud"] as? String == "/admin/")
        #expect(payload["iat"] as? Int == 1_800_000_000)
        #expect(payload["exp"] as? Int == 1_800_000_300)

        let key = SymmetricKey(data: Data(hex: String(repeating: "ab", count: 32))!)
        let expected = HMAC<SHA256>.authenticationCode(for: Data((parts[0] + "." + parts[1]).utf8), using: key)
        #expect(GhostCredentials.base64URL(Data(expected)) == parts[2])
    }

    private func base64URLDecode(_ s: String) -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)!
    }
}

@Suite struct URLNormalizationTests {
    @Test(arguments: [
        ("journal.merimerimeri.com", "https://journal.merimerimeri.com"),
        ("https://journal.merimerimeri.com/", "https://journal.merimerimeri.com"),
        ("https://journal.merimerimeri.com/ghost/", "https://journal.merimerimeri.com"),
        ("https://example.com/blog/ghost/#/dashboard", "https://example.com/blog"),
        ("http://localhost:2369", "http://localhost:2369"),
    ])
    func normalizes(_ input: String, _ expected: String) throws {
        #expect(try GhostClient.normalizeSiteURL(input).absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com", "https://"])
    func rejects(_ input: String) {
        #expect(throws: GhostError.invalidURL) { try GhostClient.normalizeSiteURL(input) }
    }
}

@Suite struct EntryBuilderTests {
    let date = Date(timeIntervalSince1970: 1_793_328_480) // 2026-10-30 02:48 UTC
    let ny = TimeZone(identifier: "America/New_York")!
    let enUS = Locale(identifier: "en_US")

    @Test func untitledEntryGetsDateTitleAndInternalTag() {
        let post = EntryBuilder.post(title: "  ", markdown: "Hello", tags: ["Life"], status: .published,
                                     date: date, locale: enUS, timeZone: ny)
        // Apple uses a narrow no-break space before AM/PM.
        #expect(post.title.replacingOccurrences(of: "\u{202F}", with: " ") == "Thursday, October 29, 2026 · 10:48 PM")
        #expect(post.tags == ["Life", "#untitled"])
        #expect(post.status == .published)
    }

    @Test func titledEntryKeepsTitleAndDropsUntitledTag() {
        let post = EntryBuilder.post(title: " A day ", markdown: "x", tags: ["#untitled", "life", "Life", " "],
                                     status: .draft, date: date, locale: enUS, timeZone: ny)
        #expect(post.title == "A day")
        #expect(post.tags == ["life"])
    }

    @Test func markdownBecomesHTML() {
        let html = EntryBuilder.html(fromMarkdown: "# Hi\n\nSome *em* and **strong**.\n\n- one\n- two\n\n> quote")
        #expect(html.contains("<h1>Hi</h1>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<strong>strong</strong>"))
        #expect(html.contains("<li>one</li>"))
        #expect(html.contains("<blockquote>"))
    }

    @Test func gfmExtrasAndRawHTML() {
        let html = EntryBuilder.html(fromMarkdown: "| a | b |\n|---|---|\n| 1 | 2 |\n\n~~gone~~ https://example.com\n\n<aside>kept</aside>")
        #expect(html.contains("<table>"))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
        #expect(html.contains("<aside>kept</aside>"))
    }

    @Test func errorMapping() {
        let body = Data(#"{"errors":[{"message":"Saving failed!","context":"Someone else is editing this post."}]}"#.utf8)
        #expect(GhostClient.error(status: 409, data: body) == .conflict("Saving failed! Someone else is editing this post."))
        #expect(GhostClient.error(status: 401, data: Data()) == .unauthorized("unauthorized"))
        #expect(GhostClient.error(status: 503, data: Data()).isTransient)
        #expect(!GhostClient.error(status: 422, data: Data()).isTransient)
    }
}

/// Runs against the throwaway dev Ghost when GHOST_DEV_URL and GHOST_DEV_ADMIN_KEY are set
/// (see scripts/test-ghostkit.sh). Skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GHOST_DEV_ADMIN_KEY"] != nil))
struct LiveGhostTests {
    let client: GhostClient = {
        let env = ProcessInfo.processInfo.environment
        return GhostClient(baseURL: try! GhostClient.normalizeSiteURL(env["GHOST_DEV_URL"]!),
                           credentials: try! GhostCredentials(apiKey: env["GHOST_DEV_ADMIN_KEY"]!))
    }()

    @Test func siteInfo() async throws {
        let site = try await client.site()
        #expect(!site.title.isEmpty)
    }

    @Test func publishUntitledThenEditThenDetectConflict() async throws {
        let entry = EntryBuilder.post(title: "", markdown: "Live test **entry** \(UUID())", tags: ["quill-test"],
                                      status: .published, date: .now)
        let created = try await client.createPost(entry)
        #expect(created.status == .published)
        #expect(created.title == entry.title)
        #expect(created.slug != "untitled")

        let fetched = try await client.post(id: created.id)
        #expect(fetched.tags?.map(\.name).contains("#untitled") == true)

        var edit = entry
        edit.title = "Now with a title"
        edit.tags = ["quill-test"]
        let updated = try await client.updatePost(id: created.id, updatedAt: created.updatedAt, edit)
        #expect(updated.title == "Now with a title")

        // A changed edit sent with the stale timestamp must be refused, not overwrite.
        // (Ghost only checks when a field actually changes.)
        edit.title = "Stale edit"
        await #expect(throws: GhostError.self) {
            _ = try await client.updatePost(id: created.id, updatedAt: created.updatedAt, edit)
        }
    }

    @Test func draftStaysDraft() async throws {
        let post = try await client.createPost(
            EntryBuilder.post(title: "Draft test", markdown: "draft", tags: [], status: .draft, date: .now))
        #expect(post.status == .draft)
    }

    @Test func listsPostsAndTags() async throws {
        let posts = try await client.recentPosts(limit: 5)
        #expect(!posts.isEmpty)
        _ = try await client.tags()
    }

    @Test func uploadsImage() async throws {
        // 1x1 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let url = try await client.uploadImage(png, filename: "pixel.png", mimeType: "image/png")
        #expect(url.absoluteString.contains("/content/images/"))
    }

    @Test func wrongKeyIsUnauthorized() async throws {
        let bad = GhostClient(baseURL: client.baseURL,
                              credentials: try GhostCredentials(apiKey: "6ae4057d55c8400001a47b58:" + String(repeating: "cd", count: 32)))
        await #expect {
            _ = try await bad.recentPosts()
        } throws: { error in
            if case GhostError.unauthorized = error { return true }
            return false
        }
    }
}
