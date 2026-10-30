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
        let ghost = app.buttons["siteKind.ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 30), "Face ID unlock / site choice didn't appear")
        attach("add-site", app)
        XCTAssertTrue(app.buttons["siteKind.local"].exists, "local must be offered at setup")
        XCTAssertFalse(app.buttons["Cancel"].exists, "first site must not be skippable")
        XCTAssertFalse(app.textViews["editor"].exists, "no writing before a site exists")
        ghost.tap()
        let urlField = app.textFields["https://journal.example.com"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(url)
        let keyField = app.secureTextFields.firstMatch
        keyField.tap()
        keyField.typeText(key)
        XCTAssertTrue(app.buttons["Private"].isSelected, "new sites default to private")
        app.buttons["Save"].tap()

        // Then the blank page, on the new site.
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Site: Quill Dev"].waitForExistence(timeout: 10), "site not selected")
        attach("blank-page", app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard shouldn't open by itself on iPad")
        }
        XCTAssertFalse(app.textFields["titleField"].exists, "title stays hidden until asked for")
        XCTAssertFalse(app.buttons["Draft"].exists, "drafts are automatic")

        let marker = "UI flow \(UUID().uuidString)"
        editor.tap()
        editor.typeText(marker)
        attach("written", app)
        app.buttons["sendButton"].tap()

        waitForBlankPage(editor)
        attach("published", app)

        // The title is a tick box: on shows it, focused to type in; off removes it; on restores it.
        let titleBox = app.buttons["Title"]
        XCTAssertFalse(titleBox.isSelected)
        titleBox.tap()
        let titleField = app.textFields["titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Add Title didn't show the field")
        titleField.typeText("Kept draft")
        XCTAssertEqual(titleField.value as? String, "Kept draft", "title field wasn't focused")
        titleBox.tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 5), "unticking didn't hide the title")
        titleBox.tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, "Kept draft", "ticking again didn't restore the title")

        // Going back from a new entry goes home, with the writing kept as a draft.
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
        let ghost = app.buttons["siteKind.ghost"]
        let editorView = app.textViews["editor"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 30) || editorView.exists, "didn't unlock")
        if ghost.exists {
            ghost.tap()
            let urlField = app.textFields["https://journal.example.com"]
            XCTAssertTrue(urlField.waitForExistence(timeout: 5))
            urlField.tap()
            urlField.typeText(url)
            let keyField = app.secureTextFields.firstMatch
            keyField.tap()
            keyField.typeText(key)
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
        XCTAssertTrue(app.staticTexts["Private"].exists, "private site shows no lock label")
        attach("site-posts", app)
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
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 20), "an update returns to the entry")
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
            XCTAssertTrue(app.buttons["Focus"].isHittable, "the focus button went away")
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
        XCUIDevice.shared.orientation = .portrait
    }

    /// A local site does everything a Ghost site does, with no server and "Saved" for Publish.
    /// Stands alone: it's the app's only site on a fresh install, and one of several otherwise.
    @MainActor
    func testLocalSite() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        allowFaceIDIfAsked()
        let name = "Notebook \(UUID().uuidString.prefix(4))"
        let local = app.buttons["siteKind.local"]
        let editor = app.textViews["editor"]
        XCTAssertTrue(local.waitForExistence(timeout: 30) || editor.exists, "didn't unlock")
        if !local.exists {
            showSidebar(app)
            app.buttons["Add Site"].tap()
            XCTAssertTrue(local.waitForExistence(timeout: 5), "Add Site must offer every kind")
            XCTAssertTrue(app.buttons["siteKind.ghost"].exists)
            attach("add-site-kinds", app)
        }
        local.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "a local site needs no key")
        nameField.tap()
        nameField.typeText(name)
        app.buttons["Plum"].tap()
        attach("local-form", app)
        app.buttons["Save"].tap()

        // Write on it. Saved stands in for Publish, and it's listed under the site.
        showSidebar(app)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        app.buttons["New Entry"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Site:'")).firstMatch.tap()
        app.buttons[name].firstMatch.tap()
        let text = "Only on this device \(UUID().uuidString.prefix(8))"
        editor.tap()
        editor.typeText(text)
        let saved = app.buttons["sendButton"]
        XCTAssertEqual(saved.label, "Saved")
        attach("local-writing", app)
        saved.tap()
        waitForBlankPage(editor)

        showSidebar(app)
        app.cells.containing(.staticText, identifier: name).firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "saved entry not listed")
        XCTAssertTrue(app.staticTexts["On this device"].exists)
        attach("local-posts", app)

        // Edit it again, then delete it, just like a post on a site.
        row.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        // Edit opens the keyboard with the cursor at the end, so typing just continues.
        app.buttons["Edit"].tap()
        editor.typeText(" edited")
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.hasSuffix(" edited") == true, "cursor moved: \(editor.value ?? "nil")")
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete from \(name)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete must confirm")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))

        // Formatting can be undone, and an unticked title survives a relaunch.
        showSidebar(app)
        app.buttons["New Entry"].firstMatch.tap() // iPad's empty detail column has one too
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let kept = "Kept across a relaunch \(UUID().uuidString.prefix(8))"
        editor.tap()
        editor.typeText(kept)
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["Bold"].tap()
            XCTAssertNotEqual(editor.value as? String, kept, "bold changed nothing")
            editor.typeKey("z", modifierFlags: .command)
            XCTAssertEqual(editor.value as? String, kept, "undo didn't take back the formatting")
        }
        app.buttons["Title"].tap()
        let titleField = app.textFields["titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.typeText("Held back")
        app.buttons["Title"].tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 5))
        try await Task.sleep(for: .seconds(3)) // autosave
        app.terminate()
        app.launch()
        allowFaceIDIfAsked()
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        showSidebar(app)
        app.staticTexts["Drafts"].tap()
        let draft = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", kept)).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "draft not listed after relaunch")
        draft.tap()
        XCTAssertTrue(app.buttons["Title"].waitForExistence(timeout: 10))
        app.buttons["Title"].tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, "Held back", "unticked title was lost")
    }

    /// Sending a new entry gives no message, it just moves on to a fresh page.
    private func waitForBlankPage(_ editor: XCUIElement) {
        let blank = expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [blank], timeout: 20), .completed, "no blank page after sending")
    }

    private func showSidebar(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.buttons["Settings"].isHittable {
            let back = app.buttons["BackButton"]
            (back.exists ? back : app.buttons["Show Sidebar"].firstMatch).tap()
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
