import XCTest

final class AgentGridUITests: XCTestCase {
    @MainActor
    func testAgentsGridOpensWorkspaceAndEditsItsPhoto() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_HERMES_GROUP_FIXTURE"] = "1"
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        continueAfterFailure = false
        app.launch()

        XCTAssertTrue(app.buttons["sidebar-inbox"].isSelected)
        XCTAssertTrue(app.buttons["sidebar-group-chats"].isHittable)
        let grid = app.showAgentGrid()
        let agentsTab = app.buttons["sidebar-agents"]
        XCTAssertGreaterThan(agentsTab.frame.minY, app.frame.midY)
        let openClaw = grid.buttons["sidebar-agent-openclaw"]
        let vps = grid.buttons["sidebar-agent-hermes"]
        let studio = grid.buttons["sidebar-agent-hermes-studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 8))
        XCTAssertEqual(openClaw.frame.minY, studio.frame.minY, accuracy: 1)
        XCTAssertLessThan(openClaw.frame.minX, vps.frame.minX)
        XCTAssertLessThan(vps.frame.minX, studio.frame.minX)
        capture(app, "agents-gradient-grid")

        vps.tap()
        XCTAssertTrue(app.buttons["sidebar-main-chat"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["agent-workspace-heading"].label, "Hermes VPS")
        XCTAssertFalse(agentsTab.exists)
        capture(app, "agents-workspace")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(vps.waitForExistence(timeout: 8))

        func openPhotoEditor() {
            vps.press(forDuration: 1)
            let edit = app.buttons["edit-agent-photo"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(app.buttons["choose-agent-photo"].waitForExistence(timeout: 5))
        }

        openPhotoEditor()
        capture(app, "agents-photo-editor")
        guard ProcessInfo.processInfo.environment["RIPTIDE_AVATAR_PHOTO_SEEDED"] == "1" else { return }
        app.buttons["choose-agent-photo"].tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 12), app.debugDescription)
        photo.tap()
        let reset = app.buttons["reset-agent-photo"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "agents-custom-photo")
        app.navigationBars["Profile photo"].buttons["Done"].tap()
        XCTAssertTrue(vps.isHittable)
        capture(app, "agents-grid-customized")

        app.terminate()
        app.launch()
        _ = app.showAgentGrid()
        openPhotoEditor()
        XCTAssertTrue(reset.exists)
        reset.tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["choose-agent-photo"].label, "Choose photo")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
extension XCUIApplication {
    @discardableResult
    func showAgentGrid() -> XCUIElement {
        let tab = buttons["sidebar-agents"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        if !tab.isSelected { tab.tap() }
        let grid = scrollViews["agent-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        return grid
    }

    func openAgentWorkspace(_ id: String) {
        let agent = showAgentGrid().buttons["sidebar-agent-\(id)"]
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        agent.tap()
    }
}
