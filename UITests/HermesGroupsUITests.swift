import XCTest

final class HermesGroupsUITests: XCTestCase {
    @MainActor
    func testCreateDiscussAndReopenGroup() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_HERMES_GROUP_FIXTURE"] = "1"
        continueAfterFailure = false
        app.launch()

        app.buttons["sidebar-group-chats"].tap()
        let editorial = app.buttons["hermes-group-row-editorial"]
        XCTAssertTrue(editorial.waitForExistence(timeout: 8))
        XCTAssertTrue(editorial.label.contains("Hermes Studio"))
        let newGroup = app.buttons["new-hermes-group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 8))
        newGroup.tap()

        let chooser = app.descendants(matching: .any).matching(identifier: "hermes-group-host").firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 8))
        let create = app.buttons["create-hermes-group"]
        XCTAssertFalse(create.isEnabled)
        chooser.tap()
        app.buttons["Hermes Studio"].tap()
        XCTAssertTrue(app.buttons["hermes-group-bot-editor"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["hermes-group-bot-sable-accountant"].exists)
        chooser.tap()
        app.buttons["Hermes VPS"].tap()
        let sable = app.buttons["hermes-group-bot-sable-accountant"]
        XCTAssertTrue(sable.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["hermes-group-bot-editor"].exists)
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
        XCTAssertTrue((heading.value as? String)?.contains("Hermes VPS") == true)
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
        app.buttons["sidebar-group-chats"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Month-end review")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(saved.label.contains("Hermes VPS"))
        XCTAssertTrue(editorial.exists)
        capture(app, "riptide-group-list")
        saved.tap()
        XCTAssertTrue(finalReply.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(identifier: "hermes-group-message-1").count, 1)
        capture(app, "riptide-group-discussion")
        app.buttons["workspace-switcher"].tap()
        app.buttons["switcher-group-chats"].tap()
        XCTAssertTrue(editorial.waitForExistence(timeout: 8))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
