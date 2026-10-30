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
        XCTAssertFalse(app.textFields["titleField"].exists, "title stays hidden until asked for")
        XCTAssertFalse(app.buttons["Draft"].exists, "drafts are automatic")

        let marker = "UI flow \(UUID().uuidString)"
        editor.tap()
        editor.typeText(marker)
        attach("written", app)
        app.buttons["sendButton"].tap()

        XCTAssertTrue(app.staticTexts["Published to Quill Dev"].waitForExistence(timeout: 20), "no success banner")
        attach("published", app)

        // Asking for a title shows it, and it's focused to type in.
        app.buttons["Add Title"].tap()
        let titleField = app.textFields["titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Add Title didn't show the field")
        titleField.typeText("Kept draft")
        XCTAssertEqual(titleField.value as? String, "Kept draft", "title field wasn't focused")

        // Going back from a new entry goes home, with the writing kept as a draft.
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.textViews["editor"].tap()
            app.buttons["Hide Keyboard"].tap()
        }
        showSidebar(app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "back didn't go home")
        attach("home", app)
        XCTAssertFalse(app.staticTexts["Sent"].exists)
        XCTAssertFalse(app.staticTexts["Outbox"].exists, "outbox shows only when something's wrong")
        XCTAssertTrue(app.staticTexts["Drafts"].exists, "draft wasn't kept")
        app.staticTexts["Drafts"].tap()
        XCTAssertTrue(app.staticTexts["Kept draft"].waitForExistence(timeout: 5))
        attach("drafts", app)
        showSidebar(app)
        XCTAssertTrue(app.buttons["New Entry"].waitForExistence(timeout: 5), "back didn't return home")
        app.buttons["New Entry"].tap()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 5))

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
        // Re-selecting the current site leaves the iPad sidebar floating over the list.
        if app.buttons["Hide Sidebar"].firstMatch.exists { app.buttons["Hide Sidebar"].firstMatch.tap() }
        try await Task.sleep(for: .seconds(1))
        row.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15), "post didn't open")
        XCTAssertEqual(editor.value as? String, "Written **elsewhere**")
        XCTAssertTrue(app.staticTexts["Published"].exists, "status shouldn't name the site")

        // Going back mid-edit cancels it: the text is restored and edit mode is off.
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["Edit"].tap()
            editor.tap()
            editor.typeText(" abandoned")
            app.buttons["BackButton"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15), "edit mode stuck after going back")
            XCTAssertEqual(editor.value as? String, "Written **elsewhere**", "cancelled edit wasn't discarded")
        }

        app.buttons["Edit"].tap()
        editor.tap()
        editor.typeText(" and edited")
        attach("editing-past-post", app)
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.staticTexts["Updated on Quill Dev"].waitForExistence(timeout: 20), "no update banner")
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5), "an update returns to the entry")
        let edited = try await client.post(id: created.id)
        XCTAssertTrue(edited.html?.contains("edited") == true, "edit didn't reach Ghost")

        // iPad: focus mode leaves only the page, and comes back.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let list = app.buttons["Edit Site"]
            XCTAssertTrue(list.isHittable)
            app.buttons["Focus"].tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 5), "focus mode left the list on screen")
            attach("focus-mode", app)
            app.buttons["Focus"].tap()
            XCTAssertTrue(list.waitForExistence(timeout: 5), "focus mode didn't exit")
        }

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

    override func setUp() {
        // All three iPad columns fit in landscape.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
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
