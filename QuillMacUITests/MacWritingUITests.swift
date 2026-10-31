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

        // The live preview renders beside the text.
        app.typeKey("p", modifierFlags: [.command, .shift])
        sleep(1)
        attach("preview", app)
        XCTAssertGreaterThan(app.webViews.count, 0, "preview didn't open")
        XCTAssertGreaterThan(app.webViews.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'Written on a' OR label CONTAINS 'Written on a'")).count, 0,
                             "preview didn't render")
        app.typeKey("p", modifierFlags: [.command, .shift])

        app.typeKey(.return, modifierFlags: .command)
        attach("after-publish", app)

        app.typeKey(",", modifierFlags: .command)
        sleep(1)
        attach("settings", app)
    }
}
