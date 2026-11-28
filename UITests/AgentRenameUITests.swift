import XCTest

final class AgentRenameUITests: XCTestCase {
    @MainActor
    func testAgentToolsUpdateNameAndPhotoAndRespectLocalReset() throws {
        guard let port = ProcessInfo.processInfo.environment["RIPTIDE_PROFILE_FIXTURE_PORT"] else {
            throw XCTSkip("Requires a trusted loopback TLS endpoint for the agent profile fixture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DEMO"] = "0"
        app.launch()

        let connect = app.buttons["connect-hermes"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        app.buttons["pair-transport"].tap()
        app.buttons["WebSocket"].tap()

        func fill(_ field: XCUIElement, _ value: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isHittable)
            field.tap()
            field.typeText(value)
        }
        fill(app.secureTextFields["pair-token"], String(repeating: "a", count: 50))
        fill(app.textFields["Existing main chat ID"], "main")
        fill(app.textFields["Absolute workspace path"], "/riptide-profile-fixture")
        fill(app.textFields["pair-address"], "wss://127.0.0.1:\(port)/acp")
        fill(app.textFields["Name"], "Hermes VPS")
        app.navigationBars["Pair remote"].buttons["Pair"].tap()

        let agent = app.showAgentGrid().buttons["Hermes VPS"]
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        let agentID = agent.identifier
        agent.tap()

        let heading = app.chatHeading
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertEqual(heading.value as? String, "Hermes VPS")
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        func waitForComposer() {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"),
                                                   object: composer)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
        waitForComposer()
        composer.tap()
        composer.typeText("Change your name to Harbor")
        app.buttons["send-message"].tap()
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Harbor"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 10), .completed)
        capture(app, "renamed-agent-chat")

        composer.tap()
        composer.typeText("Set your profile picture")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["I updated my profile picture."].firstMatch.waitForExistence(timeout: 10))

        app.buttons["BackButton"].tap()
        let updated = app.showAgentGrid().buttons[agentID]
        XCTAssertEqual(updated.label, "Harbor")

        func openPhotoEditor() {
            XCTAssertTrue(updated.waitForExistence(timeout: 8))
            updated.press(forDuration: 1)
            let edit = app.buttons["edit-agent-photo"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(app.buttons["choose-agent-photo"].waitForExistence(timeout: 5))
        }

        let reset = app.buttons["reset-agent-photo"]
        let done = app.navigationBars["Profile photo"].buttons["Done"]
        openPhotoEditor()
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        capture(app, "agent-set-profile-photo")
        done.tap()
        XCTAssertTrue(updated.isHittable)
        capture(app, "agent-set-photo-grid")

        app.terminate()
        app.launch()
        XCTAssertEqual(app.showAgentGrid().buttons[agentID].label, "Harbor")
        openPhotoEditor()
        XCTAssertTrue(reset.exists)
        reset.tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        done.tap()
        updated.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        waitForComposer()
        app.buttons["BackButton"].tap()
        _ = app.showAgentGrid()
        openPhotoEditor()
        XCTAssertFalse(reset.exists)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
