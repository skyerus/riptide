import XCTest

final class AgentChatsUITests: XCTestCase {
    @MainActor
    func testRichReplyRendersDiagramCodeAndDiff() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openOpenClaw(app)
        send("formatting demo", in: app)
        XCTAssertTrue(app.staticTexts["Formatting demo complete."].waitForExistence(timeout: 12))
        let diff = app.descendants(matching: .any).matching(identifier: "markdown-diff").firstMatch
        XCTAssertTrue(diff.exists)
        XCTAssertTrue(app.staticTexts["+ watch(turn)"].exists)
        XCTAssertTrue(app.staticTexts["swift"].exists)
        capture(app, as: "Inline code and diff")

        let diagram = app.buttons["diagram-source"]
        for _ in 0..<3 where !diagram.isHittable { app.swipeDown() }
        XCTAssertTrue(diagram.waitForExistence(timeout: 10))
        XCTAssertEqual(diagram.label, "Source")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        capture(app, as: "Rendered Mermaid diagram")
        diagram.tap()
        XCTAssertEqual(diagram.label, "Preview")
        XCTAssertTrue(app.staticTexts["mermaid"].exists)
        let copy = app.buttons["copy-code"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
    }

    @MainActor
    func testAgentOpensMainAndCanReopenSavedChatAfterRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        capture(app, as: "Agent roster")

        openOpenClaw(app)
        XCTAssertEqual(title(app).label, "Main Chat")
        let history = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This is your main chat.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let lastOpened = app.buttons["inbox-last-opened-chat"]
        XCTAssertTrue(lastOpened.waitForExistence(timeout: 5))
        XCTAssertTrue(lastOpened.staticTexts["Main Chat"].exists)
        lastOpened.tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))

        app.buttons["chats-button"].tap()
        app.buttons["new-chat"].tap()
        XCTAssertTrue(app.staticTexts["empty-chat"].waitForExistence(timeout: 5))

        send("Project overview", in: app)
        XCTAssertTrue(app.staticTexts["Other chats"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Saved separately"].exists)
        app.terminate()
        app.launch()

        XCTAssertTrue(lastOpened.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar-inbox"].isSelected)
        XCTAssertTrue(app.staticTexts["You’re caught up"].isHittable)
        XCTAssertTrue(lastOpened.staticTexts["Project overview"].exists)
        XCTAssertTrue(lastOpened.staticTexts["OpenClaw"].exists)
        capture(app, as: "Last opened side chat alongside the Inbox")
        lastOpened.tap()
        XCTAssertTrue(app.staticTexts["Saved separately"].waitForExistence(timeout: 5))
        XCTAssertEqual(title(app).label, "Project overview")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["sidebar-inbox"].isSelected)

        app.buttons["sidebar-agent-openclaw"].tap()
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        let saved = app.buttons["Project overview"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertLessThan(main.frame.minY, saved.frame.minY)
        capture(app, as: "Main chat above a saved side chat")
        saved.tap()
        XCTAssertTrue(app.staticTexts["Saved separately"].waitForExistence(timeout: 5))
        XCTAssertEqual(title(app).label, "Project overview")
        capture(app, as: "Reopened chat")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["sidebar-agent-openclaw"].isSelected)
    }

    @MainActor
    func testDemoApprovalCanBeDenied() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openOpenClaw(app)
        send("Show an approval", in: app)
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRosterAndComposerControls() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()

        let openClaw = app.buttons["sidebar-agent-openclaw"]
        let hermes = app.buttons["sidebar-agent-hermes"]
        XCTAssertTrue(openClaw.waitForExistence(timeout: 5))
        XCTAssertTrue(hermes.exists)
        XCTAssertEqual(openClaw.frame.minY, hermes.frame.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["sidebar-inbox"].value as? String, "All caught up")
        XCTAssertTrue(app.buttons["sidebar-inbox"].isSelected)
        XCTAssertFalse(app.buttons["inbox-last-opened-chat"].exists)
        XCTAssertTrue(app.scrollViews["sidebar-workspace-tabs"].exists)
        XCTAssertFalse(app.buttons["workspace-switcher"].exists)
        capture(app, as: "Workspaces without waiting items")

        app.buttons["edit-roster"].tap()
        app.buttons["pair-remote"].tap()
        XCTAssertTrue(app.navigationBars["Pair remote"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let unpin = app.buttons["unpin-hermes"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        unpin.tap()
        XCTAssertTrue(app.buttons["pin-hermes"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertLessThan(openClaw.frame.minX, hermes.frame.minX)
        app.terminate()
        app.launch()

        XCTAssertTrue(openClaw.waitForExistence(timeout: 5))
        XCTAssertLessThan(openClaw.frame.minX, hermes.frame.minX)
        openOpenClaw(app)
        let modelOptions = app.buttons["model-options"]
        XCTAssertTrue(modelOptions.waitForExistence(timeout: 5))
        modelOptions.tap()
        let mini = app.buttons["config-model-atlas-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(modelOptions.value as? String, "Atlas Mini, Medium")
        capture(app, as: "Composer")

        app.buttons["context-usage"].tap()
        let values = app.staticTexts["context-values"]
        XCTAssertTrue(values.waitForExistence(timeout: 5))
        XCTAssertTrue(values.label.contains(64_000.formatted()))
    }

    @MainActor
    private func openOpenClaw(_ app: XCUIApplication) {
        let tab = app.buttons["sidebar-agent-openclaw"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let row = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(title(app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["chats-button"]
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(text)
        app.buttons["send-message"].tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
