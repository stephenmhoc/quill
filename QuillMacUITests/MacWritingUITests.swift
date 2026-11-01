import XCTest

/// The Mac app end to end on a local site, which never leaves this machine. Keychain-backed sites
/// need a properly signed build, and Touch ID can't be driven here, so `-skipUnlock` stands in.
final class MacWritingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testWriteOnALocalSite() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipUnlock"]
        app.launch()
        app.activate()

        // First run asks for a site; later runs already have one.
        let local = app.descendants(matching: .any)["siteKind.local"]
        if local.waitForExistence(timeout: 5) {
            attach("welcome", app)
            local.click()
            let name = app.textFields.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.click()
            name.typeText("Notebook")
            attach("site-form", app)
            app.buttons["Save"].click()
        }

        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor")
        attach("empty", app)
        app.typeKey("n", modifierFlags: .command)
        editor.click()
        let words = "Written on a **Mac** \(UUID().uuidString.prefix(6))"
        editor.typeText(words)
        XCTAssertEqual(editor.value as? String, words)

        // Markdown shortcuts, from the menu bar's keys.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "**\(words)**")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, words, "Undo didn't take the formatting back")
        app.typeKey(.rightArrow, modifierFlags: [])
        attach("writing", app)

        // The sidebar button stays put, and so does the toolbar, whichever list is showing.
        app.staticTexts["Drafts"].click()
        sleep(1)
        attach("drafts", app)
        let toggle = app.descendants(matching: .any)["sidebarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2), "no sidebar button")
        let toggleSpot = toggle.frame
        toggle.click()
        sleep(1)
        attach("sidebar-closed", app)
        XCTAssertEqual(toggle.frame, toggleSpot, "the sidebar button moved")
        toggle.click()
        sleep(1)
        editor.click()

        // The live preview renders beside the text.
        app.typeKey("p", modifierFlags: [.command, .option])
        sleep(1)
        attach("preview", app)
        XCTAssertGreaterThan(app.webViews.count, 0, "preview didn't open")
        XCTAssertGreaterThan(app.webViews.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'Written on a' OR label CONTAINS 'Written on a'")).count, 0,
                             "preview didn't render")
        app.typeKey("p", modifierFlags: [.command, .option])

        app.typeKey(.return, modifierFlags: .command)
        attach("after-publish", app)

        app.typeKey(",", modifierFlags: .command)
        sleep(1)
        attach("settings", app)
    }

    /// A replacement key has to be pasteable into a site that already exists.
    @MainActor func testPasteANewKeyIntoAnExistingSite() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipUnlock", "-seedGhostSite"]
        app.launch()
        app.activate()

        let site = app.staticTexts.matching(NSPredicate(format: "value == 'Key Test' OR label == 'Key Test'")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 10))
        site.click()
        let edit = app.buttons["Edit Site"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()

        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5), "no key field")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("abc123:def456\n", forType: .string)
        app.buttons["Paste"].click()
        sleep(1)
        attach("edit-site", app)
        XCTAssertEqual((key.value as? String)?.count, "abc123:def456".count, "paste didn't reach the key field")
    }
}
