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
        XCTAssertFalse(app.textViews.firstMatch.exists, "no writing before a site exists")
        urlField.tap()
        urlField.typeText(url)
        let keyField = app.secureTextFields.firstMatch
        keyField.tap()
        keyField.typeText(key)
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save must need an explicit Private/Public choice")
        app.buttons["Private"].tap()
        app.buttons["Save"].tap()

        // Then the blank page, on the new site.
        let editor = app.textViews.firstMatch
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
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 30), "didn't unlock on relaunch")
        attach("relaunched", app)
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
