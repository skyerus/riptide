import XCTest

final class WorkspaceUXUITests: XCTestCase {
    @MainActor
    func testHermesDictationCancelAndStopPreserveAnEditableDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1"
        continueAfterFailure = false
        app.launch()
        openMainChat(in: app, agent: "hermes")
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Please review this.")
        let dictate = app.buttons["dictation-start"]
        dictate.tap()
        let stop = app.buttons["dictation-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dictation-send"].isEnabled)
        capture(app, as: "Dictation with Stop and Send")
        app.buttons["dictation-cancel"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Please review this.")

        dictate.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, "Please review this. Add a quick summary of the open items.")
        XCTAssertTrue(app.buttons["send-message"].isEnabled)
        XCTAssertFalse(app.staticTexts["Please review this. Add a quick summary of the open items."].exists)
        capture(app, as: "Dictation in editable draft")
        editor.tap()
        editor.typeText(" Edited.")
        XCTAssertTrue((editor.value as? String)?.contains("Edited.") == true)
    }

    @MainActor
    func testHermesSendsDictationInOneTap() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1"
        continueAfterFailure = false
        app.launch()
        openMainChat(in: app, agent: "hermes")
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Please review this.")
        app.buttons["dictation-start"].tap()

        let send = app.buttons["dictation-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let transcript = app.scrollViews["chat-transcript"]
        let message = transcript.staticTexts["Please review this. Add a quick summary of the open items."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String)?.contains("Please review this.") ?? false)
        XCTAssertEqual(transcript.staticTexts.matching(identifier: message.label).count, 1)
        capture(app, as: "Dictation sent directly")
    }

    @MainActor
    func testHermesDictationStillNeedsConfirmationAtTheRecordingLimit() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1"
        app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE_LIMIT"] = "1"
        continueAfterFailure = false
        app.launch()
        openMainChat(in: app, agent: "hermes")
        let dictate = app.buttons["dictation-start"]
        XCTAssertTrue(dictate.waitForExistence(timeout: 8))
        dictate.tap()
        let status = app.descendants(matching: .any).matching(identifier: "dictation-status").firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Recording ready"),
                                              object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertFalse(editor.exists)
        app.buttons["dictation-stop"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, "Add a quick summary of the open items.")
    }

    @MainActor
    func testTheTranscriptFollowsNewLinesBeforeTheReplyFinishes() {
        let app = freshApp()
        openMainChat(in: app)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("streaming demo")
        capture(app, as: "Composer with send enabled")
        app.buttons["send-message"].tap()

        let transcript = app.scrollViews["chat-transcript"]
        let earlyUpdate = app.staticTexts["Update 8"]
        XCTAssertTrue(earlyUpdate.waitForExistence(timeout: 6))
        XCTAssertTrue(isVisible(earlyUpdate, in: transcript), "Autofollow did not move with the growing reply.")
        XCTAssertTrue(app.buttons["stop-reply"].exists, "The transcript did not follow until completion.")
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.43)).press(forDuration: 2)

        let final = app.staticTexts["Long stream complete."]
        XCTAssertTrue(final.waitForExistence(timeout: 9))
        XCTAssertTrue(isVisible(final, in: transcript), "Releasing a stationary touch did not catch up to the live edge.")
        XCTAssertFalse(app.buttons["jump-to-latest"].exists)
        capture(app, as: "Chat follows incoming text")
    }

    @MainActor
    func testReadingHistoryDoesNotGetPulledToTheEndOfALiveReply() {
        let app = freshApp()
        openMainChat(in: app)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("streaming demo")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let transcript = app.scrollViews["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Update 4"].waitForExistence(timeout: 6))
        transcript.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Long stream complete."].waitForExistence(timeout: 10))
        XCTAssertTrue(jump.exists)
        transcript.swipeUp(velocity: .slow)
        let readableArea = transcript.frame.insetBy(dx: 0, dy: 55)
        let readingHeading = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Update [0-9]+"))
            .allElementsBoundByIndex.first { (readableArea.minY...readableArea.maxY).contains($0.frame.midY) }
        guard let readingHeading else {
            XCTFail("No streamed update was visible in the reading area.")
            return
        }
        let heading = readingHeading.label
        let readingY = readingHeading.frame.midY
        XCTAssertNotEqual(heading, "Update 1", "Save a reading position partway through the transcript.")
        app.navigationBars.buttons["BackButton"].tap()
        openMainChat(in: app, agent: "hermes")
        app.navigationBars.buttons["BackButton"].tap()
        openMainChat(in: app)
        XCTAssertTrue(jump.waitForExistence(timeout: 6), "Returning to the chat lost the reader's place.")
        let restoredHeading = app.staticTexts[heading]
        XCTAssertTrue(restoredHeading.waitForExistence(timeout: 6))
        let restoredArea = transcript.frame
        XCTAssertTrue((restoredArea.minY...restoredArea.maxY).contains(restoredHeading.frame.midY))
        XCTAssertEqual(restoredHeading.frame.midY, readingY, accuracy: 65)
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
        openMainChat(in: app)
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
    func testTheSidebarReachesTheLastAgentAndListsItsChats() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launch()
        let strip = app.scrollViews["sidebar-workspace-tabs"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        let inbox = strip.buttons["sidebar-inbox"]
        func inboxIsVisible() -> Bool {
            inbox.exists && !inbox.frame.isEmpty && strip.frame.contains(inbox.frame)
        }
        XCTAssertTrue(inboxIsVisible())
        let last = app.buttons["sidebar-agent-ops-12"]
        for _ in 0..<10 {
            if last.exists && !last.frame.isEmpty && strip.frame.contains(last.frame) { break }
            strip.swipeLeft()
        }
        guard last.exists && !last.frame.isEmpty && strip.frame.contains(last.frame) else {
            XCTFail("The last agent never scrolled into view.")
            return
        }
        last.tap()
        XCTAssertEqual(app.staticTexts["sidebar-heading"].label, "Ops 12")
        let main = app.buttons["sidebar-main-chat"]
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-chat-ops-12-sample-")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        XCTAssertLessThan(main.frame.minY, history.frame.minY)
        XCTAssertTrue(app.staticTexts["Side chats"].exists)
        XCTAssertFalse(inboxIsVisible(), "Inbox should scroll offscreen with the connector tabs.")
        capture(app, as: "Sidebar agent and side chats")
        main.tap()
        let heading = app.buttons["chats-button"]
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        XCTAssertEqual(heading.value as? String, "Ops 12")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(last.waitForExistence(timeout: 8))
        XCTAssertTrue(last.isSelected)
        for _ in 0..<10 {
            if inboxIsVisible() { break }
            strip.swipeRight()
        }
        XCTAssertTrue(inboxIsVisible(), "Swiping back should reveal Inbox again.")
        inbox.tap()
        XCTAssertTrue(inbox.isSelected)
        XCTAssertEqual(app.staticTexts["sidebar-heading"].label, "Inbox")
    }

    @MainActor
    func testHomeInboxOpensTheSelectedChatAndUpdatesTheBadge() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launchEnvironment["RIPTIDE_BUSY_INBOX"] = "1"
        app.launch()
        let inbox = app.buttons["sidebar-inbox"]
        let waiting = NSPredicate(format: "value == %@", "12 waiting")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: waiting, object: inbox)], timeout: 8), .completed)

        XCTAssertTrue(inbox.isSelected)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inbox-approval-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        let item = app.buttons[rows.firstMatch.identifier]
        let name = item.staticTexts.firstMatch.label
        item.tap()
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["chats-button"].value as? String, name)
        deny.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        let reduced = NSPredicate(format: "value == %@", "11 waiting")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reduced, object: inbox)], timeout: 8), .completed)
        XCTAssertFalse(item.exists)
        let lastOpened = app.buttons["inbox-last-opened-chat"]
        XCTAssertTrue(lastOpened.waitForExistence(timeout: 5))
        XCTAssertTrue(lastOpened.staticTexts["Main Chat"].exists)
        XCTAssertTrue(lastOpened.staticTexts[name].exists)
        XCTAssertTrue(rows.firstMatch.isHittable)
        capture(app, as: "Last opened main chat alongside pending approvals")
    }

    @MainActor
    func testBusyInboxFiltersAndOnlyResolvesTheChosenApproval() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launchEnvironment["RIPTIDE_BUSY_INBOX"] = "1"
        app.launch()
        let inbox = app.buttons["sidebar-inbox"]
        let waiting = NSPredicate(format: "value == %@", "12 waiting")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: waiting, object: inbox)], timeout: 8), .completed)
        capture(app, as: "Workspaces with 12 waiting approvals")
        let search = app.textFields["inbox-search"]
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
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        XCTAssertEqual(search.value as? String, "Ops 8")
        XCTAssertFalse(app.buttons["inbox-last-opened-chat"].exists)
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Ops 8".count) + "Ops 9")
        XCTAssertTrue(app.buttons["inbox-approval-ops-9"].waitForExistence(timeout: 8))
        XCTAssertFalse(target.exists)
        capture(app, as: "Busy Inbox keeps unrelated approvals")
    }

    @MainActor
    func testCodexSendsDictationInOneTap() throws {
        let (app, editor) = try openCodexFixture(dictation: true)
        editor.tap()
        editor.typeText("finish without approval")
        app.buttons["dictation-start"].tap()
        let send = app.buttons["dictation-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let message = app.staticTexts["finish without approval Add a quick summary of the open items."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A reply finished in the other workspace."].waitForExistence(timeout: 10))
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
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertFalse(reply.exists)
    }

    @MainActor
    func testCodexShowsProgressAndToolOutputBeforeTheFinalReply() throws {
        let (app, editor) = try openCodexFixture()
        XCTAssertEqual(editor.frame.midY, app.buttons["Send"].frame.midY, accuracy: 8)
        editor.tap()
        editor.typeText("show live feedback")
        app.buttons["Send"].tap()

        let receipt = app.staticTexts["message-receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label, "Delivered")
        let activity = app.buttons["live-turn-activity"]
        XCTAssertEqual(activity.label, "Thinking")
        XCTAssertLessThan(activity.frame.height, 44)
        let timer = app.staticTexts["turn-working"]
        let firstReading = timer.label
        XCTAssertTrue(firstReading.hasPrefix("Working "))
        let tick = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Working ", firstReading),
            object: timer
        )
        XCTAssertEqual(XCTWaiter.wait(for: [tick], timeout: 4), .completed)
        XCTAssertEqual(activity.label, "Thinking")
        capture(app, as: "Codex thinking")
        let step = app.staticTexts["Inspect the fixture workspace"]
        XCTAssertTrue(step.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Checking the current changes."].exists)
        XCTAssertEqual(activity.label, "git status --short")
        let output = app.staticTexts["Fixture output is ready."]
        XCTAssertFalse(output.exists)
        activity.tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label, "Seen")
        XCTAssertTrue(app.buttons["stop-codex-turn"].exists)
        capture(app, as: "Codex turn shows live plan and command output")
        XCTAssertTrue(app.staticTexts["The fixture turn is complete."].waitForExistence(timeout: 16))
        XCTAssertTrue(activity.waitForNonExistence(timeout: 5))
        XCTAssertFalse(timer.exists)
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
        app.buttons["codex-chat-actions"].tap()
        app.buttons["Show Tool Calls"].tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        app.buttons["codex-chat-heading"].tap()
        XCTAssertTrue(app.buttons["codex-saved-chat"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func openCodexFixture(dictation: Bool = false) throws -> (XCUIApplication, XCUIElement) {
        guard let port = ProcessInfo.processInfo.environment["RIPTIDE_UX_FIXTURE_PORT"] else {
            throw XCTSkip("Start Host/ux_codex_fixture.py and export the port to the test runner.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = "ws://127.0.0.1:\(port)"
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = "fixture-" + String(repeating: "x", count: 40)
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = "/riptide-ux-fixture"
        if dictation { app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1" }
        app.launch()
        app.buttons["sidebar-agent-local-codex"].tap()
        let row = app.buttons["sidebar-chat-busy-fixture-thread"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let identifiedEditor = app.descendants(matching: .any).matching(identifier: "codex-composer").firstMatch
        let editor = identifiedEditor.waitForExistence(timeout: 5) ? identifiedEditor :
            app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@", "Message Codex")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Inbox")).firstMatch.exists)
        return (app, editor)
    }

    @MainActor
    private func isVisible(_ item: XCUIElement, in transcript: XCUIElement) -> Bool {
        guard item.exists else { return false }
        let visible = transcript.frame
        return visible.minY <= item.frame.midY && item.frame.midY <= visible.maxY
    }

    @MainActor
    private func navigateAwayFromCodex(_ app: XCUIApplication) throws {
        let back = app.navigationBars.buttons["BackButton"]
        _ = try XCTUnwrap(back.waitForExistence(timeout: 8) ? back : nil, "Codex did not show Back.")
        back.tap()
        let codex = app.buttons["sidebar-agent-local-codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: 8))
        XCTAssertTrue(codex.isSelected)
        let inbox = app.buttons["sidebar-inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 12))
        inbox.tap()
    }

    @MainActor
    func testSidebarSwitchKeepsTheDraftAndSwitcherFindsAgents() {
        let app = freshApp()
        openMainChat(in: app)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Keep this draft")

        XCTAssertFalse(app.scrollViews["sidebar-workspace-tabs"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Inbox")).firstMatch.exists)
        app.navigationBars.buttons["BackButton"].tap()
        let openClaw = app.buttons["sidebar-agent-openclaw"]
        XCTAssertTrue(openClaw.waitForExistence(timeout: 8))
        XCTAssertTrue(openClaw.isSelected)
        openMainChat(in: app, agent: "hermes")
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
        capture(app, as: "Chat without connector tabs, with retained draft")
    }

    @MainActor
    func testInboxResolvesLiveApprovalAcrossWorkspacesAndRemembersFollowUp() {
        let app = freshApp()
        openMainChat(in: app)
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        app.buttons["chat-actions"].tap()
        app.buttons["follow-up-chat"].tap()
        composer.tap()
        composer.typeText("Show an approval")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.buttons["approval-reject_once"].waitForExistence(timeout: 8))

        app.navigationBars.buttons["BackButton"].tap()
        let hermes = app.buttons["sidebar-agent-hermes"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 8))
        hermes.tap()
        app.buttons["sidebar-inbox"].tap()
        let approval = app.buttons["inbox-approval-openclaw"]
        XCTAssertTrue(approval.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["inbox-followUp-openclaw"].exists)
        capture(app, as: "Cross-workspace approval Inbox")
        approval.tap()
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        deny.tap()
        XCTAssertTrue(app.staticTexts["I skipped the sample action. Nothing was run."].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["inbox-followUp-openclaw"].waitForExistence(timeout: 8))
        XCTAssertFalse(approval.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-followUp-openclaw"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testAwayModeIsDiscoverableFromInbox() {
        let app = freshApp()
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
        openMainChat(in: app)
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
        XCTAssertTrue(app.buttons["sidebar-agent-openclaw"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func openMainChat(in app: XCUIApplication, agent: String = "openclaw") {
        let tab = app.buttons["sidebar-agent-\(agent)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        if !tab.isSelected { tab.tap() }
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        main.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
