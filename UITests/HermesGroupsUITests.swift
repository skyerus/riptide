import XCTest

final class HermesGroupsUITests: XCTestCase {
    @MainActor
    func testCreateDiscussAndReopenGroup() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_HERMES_GROUP_FIXTURE"] = "1"
        continueAfterFailure = false
        app.launch()

        app.buttons["sidebar-agent-hermes"].tap()
        let newGroup = app.buttons["new-hermes-group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 8))
        newGroup.tap()

        let sable = app.buttons["hermes-group-bot-sable-accountant"]
        XCTAssertTrue(sable.waitForExistence(timeout: 8))
        let create = app.buttons["create-hermes-group"]
        XCTAssertFalse(create.isEnabled)
        let name = app.textFields["hermes-group-name"]
        name.tap()
        name.typeText("Month-end review")
        sable.tap()
        XCTAssertFalse(create.isEnabled)
        app.buttons["hermes-group-bot-skye-accountant"].tap()
        XCTAssertTrue(create.isEnabled)
        capture(app, "riptide-group-creation")
        create.tap()

        let heading = app.buttons["hermes-group-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        XCTAssertTrue(heading.label.contains("Month-end review"))
        let composer = app.descendants(matching: .any).matching(identifier: "hermes-group-composer").firstMatch
        composer.tap()
        composer.typeText("Compare your month-end checklists.")
        app.buttons["send-hermes-group"].tap()
        let finalReply = app.staticTexts["hermes-group-message-3"]
        XCTAssertTrue(finalReply.waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["Sable Accountant"].exists)
        XCTAssertTrue(app.staticTexts["Skye Accountant"].exists)

        app.terminate()
        app.launch()
        app.buttons["sidebar-agent-hermes"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "hermes-group-row-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        capture(app, "riptide-group-list")
        saved.tap()
        XCTAssertTrue(finalReply.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(identifier: "hermes-group-message-1").count, 1)
        capture(app, "riptide-group-discussion")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
