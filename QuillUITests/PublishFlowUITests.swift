import GhostKit
import XCTest

/// A few journeys through the real app, against a real Ghost. One test per thing that would really
/// hurt if it broke, so don't add checks for individual controls here.
/// scripts/test-app.sh feeds simulated Face ID matches while this runs.
final class PublishFlowUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// First run: unlock, add a site, write, publish, and it's really in Ghost.
    @MainActor
    func testAddSiteWriteAndPublish() async throws {
        let (url, key) = try ghost()
        let app = quillApp()
        app.launch()
        allowFaceIDIfAsked()
        let editor = app.textViews["editor"]
        XCTAssertTrue(app.buttons["siteKind.ghost"].waitForExistence(timeout: 30), "Face ID unlock / site choice didn't appear")
        addGhostSite(url, key, app)

        let marker = "UI flow \(UUID().uuidString)"
        editor.tap()
        editor.typeText(marker)
        attach("written", app)
        app.buttons["sendButton"].tap()
        waitForBlankPage(editor)
        attach("published", app)

        let client = GhostClient(baseURL: URL(string: url)!, credentials: try GhostCredentials(apiKey: key))
        let posts = try await client.recentPosts(limit: 10)
        XCTAssertEqual(posts.first { $0.excerpt?.contains(marker) == true }?.status, .published)
    }

    /// A post written elsewhere can be found, edited and deleted.
    @MainActor
    func testEditAndDeleteAPost() async throws {
        let (url, key) = try ghost()
        let client = GhostClient(baseURL: URL(string: url)!, credentials: try GhostCredentials(apiKey: key))
        let title = "Past \(UUID().uuidString.prefix(8))"
        let created = try await client.createPost(OutgoingPost(title: title, html: "<p>Written elsewhere</p>", status: .published, tags: []))

        let app = quillApp()
        app.launch()
        allowFaceIDIfAsked()
        let ghostKind = app.buttons["siteKind.ghost"]
        waitForUnlock(ghostKind, app)
        if ghostKind.exists { addGhostSite(url, key, app) }

        showSidebar(app)
        app.cells.containing(.staticText, identifier: "Quill Dev").firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "post not listed")
        row.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15), "post didn't open")
        app.buttons["Edit"].tap()
        let editor = app.textViews["editor"]
        editor.tap()
        editor.typeText(" and edited")
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 20), "an update returns to the entry")
        let edited = try await client.post(id: created.id)
        XCTAssertTrue(edited.html?.contains("edited") == true, "edit didn't reach Ghost")

        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.buttons["Delete from Quill Dev"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        let remaining = try await client.recentPosts(limit: 50)
        XCTAssertFalse(remaining.contains { $0.id == created.id }, "still in Ghost")
    }

    /// Writing is kept without a server, and a draft outlives a relaunch.
    @MainActor
    func testLocalSiteKeepsWriting() async throws {
        let app = quillApp()
        app.launch()
        allowFaceIDIfAsked()
        let name = "Notebook \(UUID().uuidString.prefix(4))"
        let local = app.buttons["siteKind.local"]
        let editor = app.textViews["editor"]
        waitForUnlock(local, app)
        if !local.exists {
            showSidebar(app)
            app.buttons["Add Site"].tap()
        }
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["saveSite"].tap()

        showSidebar(app)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        app.buttons["New Entry"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site:'")).firstMatch.tap()
        app.buttons[name].firstMatch.tap()
        let text = "Only on this device \(UUID().uuidString.prefix(8))"
        editor.tap()
        editor.typeText(text)
        app.buttons["sendButton"].tap()
        waitForBlankPage(editor)
        showSidebar(app)
        app.cells.containing(.staticText, identifier: name).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 10),
                      "saved entry not listed")

        showSidebar(app)
        app.buttons["New Entry"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let kept = "Kept across a relaunch \(UUID().uuidString.prefix(8))"
        editor.tap()
        editor.typeText(kept)
        try await Task.sleep(for: .seconds(3)) // autosave
        app.terminate()
        app.launch()
        allowFaceIDIfAsked()
        waitForUnlock(editor, app)
        showSidebar(app)
        app.staticTexts["Drafts"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", kept)).firstMatch.waitForExistence(timeout: 10),
                      "draft not listed after relaunch")
    }

    /// A real Micro.blog account connects and shows its posts, and removing it leaves the blog
    /// alone. Never writes anything: a published post reaches followers and cross-posts.
    @MainActor
    func testMicroblogSite() async throws {
        let token = try XCTUnwrap(env["MICROBLOG_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "needs .dev/microblog.env")
        let app = quillApp()
        app.launch()
        allowFaceIDIfAsked()
        let kind = app.buttons["siteKind.microblog"]
        waitForUnlock(kind, app)
        if !kind.exists {
            showSidebar(app)
            app.buttons["Add Site"].tap()
            XCTAssertTrue(kind.waitForExistence(timeout: 5))
        }
        kind.tap()
        let tokenField = app.secureTextFields.firstMatch
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
        tokenField.tap()
        tokenField.typeText(token)
        let name = "Micro \(UUID().uuidString.prefix(4))"
        let nameField = app.textFields.firstMatch
        nameField.tap()
        nameField.typeText(name)
        app.buttons["saveSite"].tap()

        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 20), "site wasn't added")
        showSidebar(app)
        app.cells.containing(.staticText, identifier: name).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Muse'")).firstMatch.waitForExistence(timeout: 15),
                      "real posts didn't load")

        let edit = app.buttons["Edit Site"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let remove = app.buttons["Remove Site"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 10), "site wasn't removed")
    }

    private func ghost() throws -> (url: String, key: String) {
        (try XCTUnwrap(env["GHOST_DEV_URL"], "dev Ghost not configured"), try XCTUnwrap(env["GHOST_DEV_ADMIN_KEY"]))
    }

    @MainActor
    private func addGhostSite(_ url: String, _ key: String, _ app: XCUIApplication) {
        app.buttons["siteKind.ghost"].tap()
        let urlField = app.textFields["https://journal.example.com"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(url)
        let keyField = app.secureTextFields.firstMatch
        keyField.tap()
        keyField.typeText(key)
        app.buttons["saveSite"].tap()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 15), "site wasn't added")
    }

    /// The app with animations off, which takes minutes off a run.
    @MainActor
    private func quillApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-disableAnimations")
        return app
    }

    @MainActor
    /// Either what's expected on this launch, or home, or iPad's page with the sidebar closed.
    private func waitForUnlock(_ expected: XCUIElement, _ app: XCUIApplication) {
        let unlocked = NSPredicate { _, _ in expected.exists || app.buttons["Settings"].exists || app.textViews["editor"].exists }
        let waited = XCTWaiter.wait(for: [expectation(for: unlocked, evaluatedWith: nil)], timeout: 30)
        XCTAssertEqual(waited, .completed, "didn't unlock")
    }

    private func waitForBlankPage(_ editor: XCUIElement) {
        let blank = expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [blank], timeout: 20), .completed, "no blank page after sending")
    }

    @MainActor
    private func showSidebar(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.buttons["Settings"].isHittable {
            let back = app.buttons["BackButton"]
            (back.exists ? back : app.buttons["Show Sidebar"].firstMatch).tap()
            _ = app.buttons["Settings"].waitForExistence(timeout: 2)
        }
    }

    @MainActor
    private func allowFaceIDIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
