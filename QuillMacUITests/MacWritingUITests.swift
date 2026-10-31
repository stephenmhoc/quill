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
            let name = app.textFields["Name"]
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
        attach("writing", app)

        // The live preview renders beside the text.
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.staticTexts["Mac"].waitForExistence(timeout: 5)
                      || app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Written on a'")).firstMatch.exists,
                      "preview didn't render")
        attach("preview", app)
        app.typeKey("p", modifierFlags: [.command, .shift])

        app.typeKey(.return, modifierFlags: .command)
        attach("after-publish", app)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["General"].waitForExistence(timeout: 5) || app.tabs["General"].exists || app.buttons["General"].exists)
        attach("settings", app)
    }
}
