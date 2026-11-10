import XCTest

/// The Mac app's main journey on a local site, which never leaves this machine. Keychain-backed
/// sites need a properly signed build, and Touch ID can't be driven here, so `-skipUnlock` stands in.
final class MacWritingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testWriteOnALocalSite() {
        let app = XCUIApplication()
        app.launchArguments = ["-skipUnlock"]
        app.launch()
        app.activate()

        let local = app.buttons["siteKind.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 5), "no site choice on first run")
        local.click()
        // An empty name is the "Notebook" it shows. The form resizes for the new kind, so the
        // button is still moving for a moment.
        let addSite = app.buttons["saveSite"]
        XCTAssertTrue(addSite.waitForExistence(timeout: 5))
        RunLoop.current.run(until: .now + 0.6)
        addSite.click()

        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor")
        editor.click()
        let words = "Written on a Mac \(UUID().uuidString.prefix(6))"
        editor.typeText(words)
        XCTAssertEqual(editor.value as? String, words)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "writing"
        shot.lifetime = .keepAlways
        add(shot)

        // The new site is the one showing, so its list is where the saved entry appears.
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Written on a Mac'")).firstMatch.waitForExistence(timeout: 5),
                      "the saved entry isn't listed")
    }
}
