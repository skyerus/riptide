import XCTest

final class FirstAgentOnboardingUITests: XCTestCase {
    @MainActor
    func testFreshInstallStartsWithConnectorChoicesAndKeepsFailedPairingInSetup() {
        let app = freshApp()
        let title = app.staticTexts["Connect your first agent"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["sidebar-inbox"].exists)

        let form = app.navigationBars["Pair remote"]
        for connector in ["hermes", "openClaw"] {
            app.buttons["connect-\(connector)"].tap()
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["pair-ssh-fingerprint"].exists)
            form.buttons["Cancel"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
        }
        app.buttons["connect-codex"].tap()
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["pair-token"].exists)
        form.buttons["Pair"].tap()
        XCTAssertTrue(app.staticTexts["pair-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(form.exists)
        XCTAssertFalse(app.buttons["sidebar-inbox"].exists)
    }

    @MainActor
    func testSuccessfulPairingOpensInboxAndSurvivesRelaunch() throws {
        guard let port = ProcessInfo.processInfo.environment["RIPTIDE_PAIR_FIXTURE_PORT"] else {
            throw XCTSkip("Requires the loopback TLS App Server fixture and its trusted simulator certificate.")
        }
        let app = freshApp()
        app.buttons["connect-codex"].tap()
        let form = app.navigationBars["Pair remote"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))

        func fill(_ field: XCUIElement, _ value: String) {
            field.tap()
            field.typeText(value)
        }
        fill(app.textFields["Name"], "My Codex")
        fill(app.textFields["pair-address"], "wss://127.0.0.1:\(port)")
        fill(app.textFields["Absolute workspace path"], "/riptide-ux-fixture")
        fill(app.secureTextFields["pair-token"], "fixture-" + String(repeating: "x", count: 40))
        form.buttons["Pair"].tap()

        let inbox = app.buttons["sidebar-inbox"]
        let agent = app.scrollViews["agent-grid"].buttons["My Codex"]
        guard inbox.waitForExistence(timeout: 15) else {
            let issue = app.staticTexts["pair-error"]
            XCTFail(issue.exists ? issue.label : "Pairing did not open Inbox.")
            return
        }
        XCTAssertTrue(inbox.isSelected)
        app.showAgentGrid()
        XCTAssertTrue(agent.exists)
        XCTAssertFalse(app.buttons["sidebar-agent-hermes"].exists)
        XCTAssertFalse(app.buttons["sidebar-agent-openclaw"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(inbox.waitForExistence(timeout: 8))
        app.showAgentGrid()
        XCTAssertTrue(agent.exists)
        XCTAssertFalse(app.staticTexts["Connect your first agent"].exists)
        agent.tap()
        XCTAssertTrue(app.chatHeading.waitForExistence(timeout: 8))
        XCTAssertEqual(app.chatHeading.label, "Main Chat")
        XCTAssertEqual(app.chatHeading.value as? String, "My Codex")
    }

    @MainActor
    private func freshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DEMO"] = "0"
        app.launch()
        return app
    }
}
