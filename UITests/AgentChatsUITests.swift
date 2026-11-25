import XCTest

final class AgentChatsUITests: XCTestCase {
    @MainActor
    func testColdMainChatShowsSkeletonUntilHistoryArrives() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        continueAfterFailure = false
        app.launch()
        openMainChat(app)
        let history = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This is your main chat.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        app.terminate()

        app.launchEnvironment["RIPTIDE_DELAYED_CHAT_HISTORY"] = "1"
        app.launch()
        let chat = app.buttons["inbox-last-opened-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()

        let skeleton = app.descendants(matching: .any).matching(identifier: "chat-history-skeleton").firstMatch
        XCTAssertTrue(skeleton.waitForExistence(timeout: 5))
        XCTAssertFalse(history.exists)
        XCTAssertFalse(app.staticTexts["Opening chat…"].exists)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertFalse(composer.isEnabled)
        capture(app, as: "Main Chat loading skeleton")

        XCTAssertTrue(history.waitForExistence(timeout: 18))
        XCTAssertTrue(skeleton.waitForNonExistence(timeout: 2))
        XCTAssertTrue(composer.isEnabled)
        capture(app, as: "Main Chat history loaded")
    }

    @MainActor
    func testRichReplyRendersDiagramCodeAndDiff() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openMainChat(app)
        send("formatting demo", in: app)
        XCTAssertTrue(app.staticTexts["Formatting demo complete."].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Read the example guide or visit https://example.org."].exists)
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

        openMainChat(app)
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
    func testChatPickerSearchesAndSwitchesBetweenMainAndSideChat() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        continueAfterFailure = false
        app.launch()
        openMainChat(app)

        let heading = title(app)
        let close = app.buttons["close-chats"]
        let main = app.buttons["chat-picker-main"]
        let newChat = app.buttons["new-chat"]
        heading.tap()
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        XCTAssertTrue(main.isSelected)
        XCTAssertTrue(app.staticTexts["No side chats yet."].waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(app.staticTexts["empty-chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        let chatTitle = "Release checklist"
        send(chatTitle, in: app)
        let sideHeading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", chatTitle), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [sideHeading], timeout: 8), .completed)
        heading.tap()
        let side = app.scrollViews["chat-picker-list"].buttons[chatTitle]
        XCTAssertTrue(side.waitForExistence(timeout: 5))
        XCTAssertTrue(side.isSelected)
        XCTAssertFalse(main.isSelected)
        main.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(heading.label, "Main Chat")

        heading.tap()
        let search = app.textFields["chat-picker-search"]
        XCTAssertTrue(side.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(newChat.isHittable)
        XCTAssertLessThan(newChat.frame.maxY, main.frame.minY)
        XCTAssertTrue(main.isSelected)
        capture(app, as: "Chats sheet")

        search.tap()
        search.typeText("release")
        XCTAssertTrue(main.waitForNonExistence(timeout: 5))
        XCTAssertTrue(side.isHittable)
        capture(app, as: "Chats search")
        search.typeText(" zz")
        let noMatches = app.descendants(matching: .any).matching(identifier: "chat-picker-no-results").firstMatch
        XCTAssertTrue(noMatches.waitForExistence(timeout: 5))
        XCTAssertFalse(side.exists)

        app.buttons["Clear chat search"].tap()
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        side.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(heading.label, chatTitle)

        heading.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(heading.label, chatTitle)
    }

    @MainActor
    func testDemoApprovalCanBeDenied() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openMainChat(app)
        send("Show an approval", in: app)
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        let receipt = app.staticTexts["message-receipt"]
        let tool = app.descendants(matching: .any).matching(identifier: "chat-tool-call").firstMatch
        XCTAssertEqual(receipt.label, "Delivered")
        XCTAssertTrue(tool.exists)
        deny.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 5))
        XCTAssertTrue(tool.waitForNonExistence(timeout: 5))
        XCTAssertEqual(receipt.label, "Seen")
        app.buttons["chat-actions"].tap()
        app.buttons["Show Tool Calls"].tap()
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        app.buttons["chat-actions"].tap()
        app.buttons["Hide Tool Calls"].tap()
        XCTAssertTrue(tool.waitForNonExistence(timeout: 5))
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
        openMainChat(app)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        composer.tap()
        composer.typeText("Keep this draft")
        let modelOptions = app.buttons["model-options"]
        XCTAssertTrue(modelOptions.waitForExistence(timeout: 5))
        modelOptions.tap()
        let quickPicker = app.buttons["advanced-model-controls"]
        XCTAssertTrue(quickPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The quick picker should stay above the keyboard.")
        let effort = app.descendants(matching: .any).matching(identifier: "intelligence-steps").firstMatch
        XCTAssertTrue(effort.exists)
        XCTAssertEqual(effort.value as? String, "Medium")
        effort.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
        let activeEffort = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "High"), object: effort)
        XCTAssertEqual(XCTWaiter.wait(for: [activeEffort], timeout: 5), .completed)
        capture(app, as: "Quick intelligence selector")

        quickPicker.tap()
        let modelRow = app.buttons["config-picker-model"]
        XCTAssertTrue(modelRow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["config-picker-effort"].value as? String, "High")
        capture(app, as: "Advanced model settings")
        modelRow.tap()
        let mini = app.buttons["config-model-atlas-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(quickPicker.waitForNonExistence(timeout: 5))
        XCTAssertEqual(modelOptions.value as? String, "Atlas Mini, Medium")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        capture(app, as: "Composer")

        app.buttons["context-usage"].tap()
        let values = app.staticTexts["context-values"]
        XCTAssertTrue(values.waitForExistence(timeout: 5))
        XCTAssertTrue(values.label.contains(64_000.formatted()))
    }

    @MainActor
    private func openMainChat(_ app: XCUIApplication, agent: String = "openclaw") {
        let tab = app.buttons["sidebar-agent-\(agent)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let row = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(title(app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testHermesIntelligenceReachesBothEndsAndDismissesWithoutLosingTheDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openMainChat(app, agent: "hermes")
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let controls = app.buttons["model-options"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertEqual(controls.value as? String, "6.2 Sol, Extra High")
        composer.tap()
        composer.typeText("A draft for Hermes")
        controls.tap()
        let effort = app.descendants(matching: .any).matching(identifier: "intelligence-steps").firstMatch
        XCTAssertTrue(effort.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, as: "Hermes Intelligence at Extra High")

        for (position, value) in [(0.99, "Ultra"), (0.01, "Low")] {
            effort.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
            let selection = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: effort)
            XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 5), .completed)
            capture(app, as: "Hermes Intelligence at \(value)")
        }

        let outside = app.buttons["dismiss-model-picker"]
        XCTAssertTrue(outside.exists)
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(effort.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "A draft for Hermes")
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        controls.tap()
        app.buttons["advanced-model-controls"].tap()
        app.buttons["config-picker-effort"].tap()
        XCTAssertTrue(app.buttons["config-effort-low"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["config-effort-none"].exists)
        XCTAssertFalse(app.buttons["config-effort-minimal"].exists)
    }

    @MainActor
    func testFloatingComposerGrowsAndKeepsTheLatestReplyReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openMainChat(app, agent: "hermes")
        send("streaming demo", in: app)

        let latest = app.staticTexts["Long stream complete."]
        let sendButton = app.buttons["send-message"]
        let controls = app.buttons["model-options"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 12))
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(latest.frame.maxY, composer.frame.minY)

        let transcript = app.scrollViews["chat-transcript"]
        let jump = app.buttons["jump-to-latest"]
        transcript.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        capture(app, as: "Floating composer")

        let advanced = app.buttons["advanced-model-controls"]
        controls.tap()
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertFalse(jump.exists)
        capture(app, as: "Floating model picker")
        controls.tap()

        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let compactHeight = composer.frame.height
        let draft = "Review the workspace settings.\nKeep the draft while I scroll.\nThen list the next steps."
        composer.typeText(draft)
        XCTAssertGreaterThan(composer.frame.height, compactHeight + 20)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(sendButton.isHittable)
        capture(app, as: "Expanded floating composer")

        controls.tap()
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertLessThan(advanced.frame.maxY, composer.frame.minY)
        XCTAssertTrue(keyboard.exists)
        controls.tap()
        XCTAssertTrue(advanced.waitForNonExistence(timeout: 5))

        XCTAssertTrue(jump.isHittable)
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(latest.frame.maxY, composer.frame.minY)
        XCTAssertEqual(composer.value as? String, draft)
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
