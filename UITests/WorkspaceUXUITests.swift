import XCTest

final class WorkspaceUXUITests: XCTestCase {
    @MainActor
    func testReadingHistoryDoesNotGetPulledToTheEndOfALiveReply() {
        let app = freshApp()
        app.buttons["agent-openclaw"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("streaming demo")
        app.buttons["send-message"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let transcript = app.scrollViews["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Update 4"].waitForExistence(timeout: 6))
        transcript.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Long stream complete."].waitForExistence(timeout: 10))
        XCTAssertTrue(jump.exists)
        let readableArea = transcript.frame.insetBy(dx: 0, dy: 55)
        let heading = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Update [0-9]+"))
            .allElementsBoundByIndex.first { (readableArea.minY...readableArea.maxY).contains($0.frame.midY) }?.label
        guard let heading else {
            XCTFail("No streamed update was visible in the reading area.")
            return
        }
        app.buttons["rail-hermes"].tap()
        app.buttons["rail-openclaw"].tap()
        XCTAssertTrue(jump.waitForExistence(timeout: 6), "Returning to the chat lost the reader's place.")
        let restoredHeading = app.staticTexts[heading]
        XCTAssertTrue(restoredHeading.waitForExistence(timeout: 6))
        let restoredArea = transcript.frame
        XCTAssertTrue((restoredArea.minY...restoredArea.maxY).contains(restoredHeading.frame.midY))
        capture(app, as: "Resumed reading the same streamed chat")
        jump.tap()
        XCTAssertFalse(jump.exists)
        XCTAssertTrue(app.staticTexts["Long stream complete."].isHittable)
    }

    @MainActor
    func testBusySwitcherFindsAnUnopenedChatAcrossFourteenWorkspaces() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launch()
        let switcher = app.buttons["workspace-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 8))
        switcher.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Ops 12 incident 23")
        let matching = app.buttons["switch-chat-ops-12-ops-12-sample-23"]
        guard matching.waitForExistence(timeout: 10) else {
            XCTFail("The workspace switcher did not find a chat on an unopened workspace.")
            return
        }
        matching.tap()
        XCTAssertTrue(app.staticTexts["Fixture chat: Incident 23 review"].waitForExistence(timeout: 8))
        let title = app.buttons["chats-button"]
        XCTAssertEqual(title.value as? String, "Ops 12")
        capture(app, as: "Found a chat across a busy workspace")
    }

    @MainActor
    func testBusyInboxFiltersAndOnlyResolvesTheChosenApproval() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launchEnvironment["RIPTIDE_BUSY_INBOX"] = "1"
        app.launch()
        let switcher = app.buttons["workspace-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 8))
        switcher.tap()
        XCTAssertTrue(app.staticTexts["Live now"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()

        app.buttons["open-inbox"].tap()
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Ops 8")
        let target = app.buttons["inbox-approval-ops-8"]
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        XCTAssertTrue(target.staticTexts["Ops 8"].exists)
        XCTAssertFalse(app.buttons["inbox-approval-ops-9"].exists)
        target.tap()
        let decline = app.buttons["approval-reject_once"]
        XCTAssertTrue(decline.waitForExistence(timeout: 8))
        decline.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 8))
        app.buttons["chat-actions"].tap()
        app.buttons["Open Inbox"].tap()
        XCTAssertTrue(app.buttons["inbox-approval-ops-9"].waitForExistence(timeout: 8))
        XCTAssertFalse(target.exists)
        capture(app, as: "Busy Inbox keeps unrelated approvals")
    }

    @MainActor
    func testCodexApprovalArrivingAfterSwitchStillOpensTheSameLiveTurn() throws {
        let (app, editor) = try openCodexFixture()
        editor.tap()
        editor.typeText("Test the connected turn")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["stop-codex-turn"].waitForExistence(timeout: 6))
        try navigateAwayFromCodex(app)
        let approval = app.buttons["inbox-approval-local-codex"]
        guard approval.waitForExistence(timeout: 12) else {
            XCTFail("Codex closed the running chat connection when switching; the later approval never reached Inbox.")
            return
        }
        approval.tap()
        let decline = app.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 8))
        decline.tap()
        XCTAssertTrue(app.staticTexts["This reply survived switching workspaces."].waitForExistence(timeout: 8))
    }

    @MainActor
    func testReplyFinishingInAnotherWorkspaceStaysUnreadUntilItsChatOpens() throws {
        let (app, editor) = try openCodexFixture()
        editor.tap()
        editor.typeText("finish without approval")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["stop-codex-turn"].waitForExistence(timeout: 6))
        try navigateAwayFromCodex(app)
        let reply = app.buttons["inbox-reply-local-codex"]
        XCTAssertTrue(reply.waitForExistence(timeout: 12))
        reply.tap()
        XCTAssertTrue(app.staticTexts["A reply finished in the other workspace."].waitForExistence(timeout: 8))
        app.buttons["codex-chat-actions"].tap()
        app.buttons["Open Inbox"].tap()
        XCTAssertFalse(reply.exists)
    }

    @MainActor
    func testCodexShowsProgressAndToolOutputBeforeTheFinalReply() throws {
        let (app, editor) = try openCodexFixture()
        editor.tap()
        editor.typeText("show live feedback")
        app.buttons["Send"].tap()

        let step = app.staticTexts["Inspect the fixture workspace"]
        XCTAssertTrue(step.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Checking the current changes."].exists)
        let progress = app.descendants(matching: .any).matching(identifier: "turn-progress").firstMatch
        XCTAssertEqual(progress.label, "Running a command…")
        let activity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Activity")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()
        XCTAssertTrue(app.staticTexts["Fixture output is ready."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stop-codex-turn"].exists)
        capture(app, as: "Codex turn shows live plan and command output")
        XCTAssertTrue(app.staticTexts["The fixture turn is complete."].waitForExistence(timeout: 16))
        app.buttons["codex-chat-heading"].tap()
        XCTAssertTrue(app.buttons["codex-saved-chat"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func openCodexFixture() throws -> (XCUIApplication, XCUIElement) {
        guard let port = ProcessInfo.processInfo.environment["RIPTIDE_UX_FIXTURE_PORT"] else {
            throw XCTSkip("Start Host/ux_codex_fixture.py and export the port to the test runner.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = "ws://127.0.0.1:\(port)"
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = "fixture-" + String(repeating: "x", count: 40)
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = "/riptide-ux-fixture"
        app.launch()
        app.buttons["local-codex"].tap()
        let saved = app.buttons["saved-codex-chats"]
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        saved.tap()
        let row = app.buttons["codex-saved-chat"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let identifiedEditor = app.descendants(matching: .any).matching(identifier: "codex-composer").firstMatch
        let editor = identifiedEditor.waitForExistence(timeout: 5) ? identifiedEditor :
            app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@", "Message Codex")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        return (app, editor)
    }

    @MainActor
    private func navigateAwayFromCodex(_ app: XCUIApplication) throws {
        let remote = app.buttons["rail-openclaw"]
        _ = try XCTUnwrap(remote.waitForExistence(timeout: 8) ? remote : nil, "Codex did not show the workspace rail.")
        remote.tap()
        let other = app.buttons["chats-button"]
        _ = try XCTUnwrap(other.waitForExistence(timeout: 8) ? other : nil, "The rail did not switch away from Codex.")
        XCTAssertEqual(other.value as? String, "OpenClaw")
        let inbox = app.buttons["rail-inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 12))
        inbox.tap()
    }

    @MainActor
    func testSwitchRailKeepsTheDraftAndSwitcherFindsAgents() {
        let app = freshApp()
        app.buttons["agent-openclaw"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Keep this draft")

        let hermes = app.buttons["rail-hermes"]
        XCTAssertTrue(hermes.exists)
        hermes.tap()
        XCTAssertTrue(app.buttons["chats-button"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["chats-button"].value as? String, "Hermes")
        XCTAssertNotEqual(composer.value as? String, "Keep this draft")

        app.buttons["workspace-switcher"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("openclaw")
        let result = app.buttons["switch-openclaw"]
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        capture(app, as: "Workspace rail and retained draft")
    }

    @MainActor
    func testInboxResolvesLiveApprovalAcrossWorkspacesAndRemembersFollowUp() {
        let app = freshApp()
        app.buttons["agent-openclaw"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        app.buttons["chat-actions"].tap()
        app.buttons["follow-up-chat"].tap()
        composer.tap()
        composer.typeText("Show an approval")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.buttons["approval-reject_once"].waitForExistence(timeout: 8))

        app.buttons["rail-hermes"].tap()
        let actions = app.buttons["chat-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 8))
        actions.tap()
        app.buttons["Open Inbox"].tap()
        let approval = app.buttons["inbox-approval-openclaw"]
        XCTAssertTrue(approval.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["inbox-followUp-openclaw"].exists)
        capture(app, as: "Cross-workspace approval Inbox")
        approval.tap()
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        deny.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 8))
        actions.tap()
        app.buttons["Open Inbox"].tap()
        XCTAssertTrue(app.buttons["inbox-followUp-openclaw"].waitForExistence(timeout: 8))
        XCTAssertFalse(approval.exists)
        app.terminate()
        app.launch()
        app.buttons["open-inbox"].tap()
        XCTAssertTrue(app.buttons["inbox-followUp-openclaw"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testAwayModeIsDiscoverableFromInbox() {
        let app = freshApp()
        app.buttons["open-inbox"].tap()
        let settings = app.buttons["inbox-notifications"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Desktop presence"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Deliver alerts"].exists)
        capture(app, as: "Desktop-aware notification settings")
    }

    @MainActor
    func testFlickingTheChatHeaderSwitchesWorkspaces() {
        let app = freshApp()
        app.buttons["agent-openclaw"].tap()
        let title = app.buttons["chats-button"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.swipeLeft()
        let hermes = NSPredicate(format: "value == %@", "Hermes")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hermes, object: title)], timeout: 8), .completed)
    }

    @MainActor
    private func freshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["agent-openclaw"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
