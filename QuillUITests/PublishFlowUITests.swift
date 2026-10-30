import GhostKit
import XCTest

/// The whole app against the dev Ghost: Face ID, add a site, write, publish, check Ghost.
/// scripts/test-app.sh feeds simulated Face ID matches while this runs.
final class PublishFlowUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testAddSiteWriteAndPublish() async throws {
        let url = try XCTUnwrap(env["GHOST_DEV_URL"], "dev Ghost not configured")
        let key = try XCTUnwrap(env["GHOST_DEV_ADMIN_KEY"])
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launch()
        allowFaceIDIfAsked()

        // First run: unlocking lands on Add Site, and there's no way past it without one.
        let urlField = app.textFields["https://journal.example.com"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 30), "Face ID unlock / Add Site didn't appear")
        attach("add-site", app)
        XCTAssertFalse(app.buttons["Cancel"].exists, "first site must not be skippable")
        XCTAssertFalse(app.textViews["editor"].exists, "no writing before a site exists")
        urlField.tap()
        urlField.typeText(url)
        let keyField = app.secureTextFields.firstMatch
        keyField.tap()
        keyField.typeText(key)
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save must need an explicit Private/Public choice")
        app.buttons["Private"].tap()
        app.buttons["Save"].tap()

        // Then the blank page, on the new site.
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Site: Quill Dev"].waitForExistence(timeout: 10), "site not selected")
        attach("blank-page", app)

        let marker = "UI flow \(UUID().uuidString)"
        editor.tap()
        editor.typeText(marker)
        attach("written", app)
        app.buttons["sendButton"].tap()

        XCTAssertTrue(app.staticTexts["Published to Quill Dev"].waitForExistence(timeout: 20), "no success banner")
        attach("published", app)

        // Really in Ghost, as an untitled entry?
        let client = GhostClient(baseURL: URL(string: url)!, credentials: try GhostCredentials(apiKey: key))
        let posts = try await client.recentPosts(limit: 10)
        let post = try XCTUnwrap(posts.first { $0.excerpt?.contains(marker) == true })
        XCTAssertEqual(post.status, .published)
        XCTAssertTrue(post.tags?.contains { $0.name == EntryBuilder.untitledTag } == true)

        // Relaunch: locked again, and the sent entry persisted.
        app.terminate()
        app.launch()
        allowFaceIDIfAsked()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 30), "didn't unlock on relaunch")
        attach("relaunched", app)
    }

    /// Everything past the first run: a post written elsewhere can be found, edited and deleted,
    /// and settings stick. Stands alone, so it adds the site if this is a fresh install.
    @MainActor
    func testManagePastPostsAndSettings() async throws {
        let url = try XCTUnwrap(env["GHOST_DEV_URL"], "dev Ghost not configured")
        let key = try XCTUnwrap(env["GHOST_DEV_ADMIN_KEY"])
        continueAfterFailure = false
        let client = GhostClient(baseURL: URL(string: url)!, credentials: try GhostCredentials(apiKey: key))
        let title = "Past \(UUID().uuidString.prefix(8))"
        let created = try await client.createPost(OutgoingPost(title: title, html: "<p>Written <strong>elsewhere</strong></p>",
                                                               status: .published, tags: []))

        let app = XCUIApplication()
        app.launch()
        allowFaceIDIfAsked()
        let urlField = app.textFields["https://journal.example.com"]
        let editorView = app.textViews["editor"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 30) || editorView.exists, "didn't unlock")
        if urlField.exists {
            urlField.tap()
            urlField.typeText(url)
            let keyField = app.secureTextFields.firstMatch
            keyField.tap()
            keyField.typeText(key)
            app.buttons["Private"].tap()
            app.buttons["Save"].tap()
            XCTAssertTrue(editorView.waitForExistence(timeout: 15))
        }

        // Settings, from the home sidebar.
        showSidebar(app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        attach("settings-dark", app)
        chooseIcon("Ink", app)
        attach("settings-icon", app)
        app.buttons["Done"].tap()

        // The post is listed under its site and opens with its formatting as Markdown.
        app.cells.containing(.staticText, identifier: "Quill Dev").firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "post not listed")
        attach("site-posts", app)
        row.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15), "post didn't open")
        XCTAssertEqual(editor.value as? String, "Written **elsewhere**")

        app.buttons["Edit"].tap()
        editor.tap()
        editor.typeText(" and edited")
        attach("editing-past-post", app)
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.staticTexts["Updated on Quill Dev"].waitForExistence(timeout: 20), "no update banner")
        let edited = try await client.post(id: created.id)
        XCTAssertTrue(edited.html?.contains("edited") == true, "edit didn't reach Ghost")

        // Delete asks first, then it's gone from Ghost.
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete from Quill Dev"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete must confirm")
        attach("delete-confirm", app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(timeout: 10))
        let remaining = try await client.recentPosts(limit: 50)
        XCTAssertFalse(remaining.contains { $0.id == created.id }, "still in Ghost")

        // Appearance survives a relaunch.
        app.terminate()
        app.launch()
        allowFaceIDIfAsked()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 30))
        showSidebar(app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Dark"].isSelected, "appearance wasn't saved")
        XCTAssertTrue(app.buttons["Ink icon"].isSelected, "icon wasn't saved")
        app.buttons["Auto"].tap()
        chooseIcon("Auto", app)
        app.buttons["Done"].tap()
    }

    private func showSidebar(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.buttons["Settings"].isHittable {
            let back = app.buttons["BackButton"]
            (back.exists ? back : app.buttons["Show Sidebar"]).tap()
            _ = app.buttons["Settings"].waitForExistence(timeout: 2)
        }
    }

    private func chooseIcon(_ name: String, _ app: XCUIApplication) {
        let button = app.buttons["\(name) icon"]
        button.tap()
        // iOS confirms every icon change with its own alert.
        let ok = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        let selected = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: selected, evaluatedWith: button)], timeout: 5), .completed,
                       "\(name) icon wasn't selected")
    }

    private func allowFaceIDIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
