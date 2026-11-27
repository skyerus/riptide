import UIKit
import UniformTypeIdentifiers
import XCTest

final class WorkspaceUXUITests: XCTestCase {
    @MainActor
    func testSharedComposerPastesTextPhotoAndFile() {
        continueAfterFailure = false
        let app = freshApp()
        openMainChat(in: app, agent: "hermes")
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))

        editor.tap()
        func pasteFromEditMenu() {
            editor.press(forDuration: 0.65)
            let paste = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
            paste.tap()
        }

        UIPasteboard.general.string = "Please review"
        pasteFromEditMenu()
        let textPasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Please review"),
                                                   object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [textPasted], timeout: 5), .completed, app.debugDescription)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        UIPasteboard.general.image = image
        pasteFromEditMenu()
        XCTAssertTrue(app.buttons["remove-attachment"].firstMatch.waitForExistence(timeout: 8))

        let document = NSItemProvider()
        document.suggestedName = "Fixture report.pdf"
        document.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { result in
            result(Data("%PDF-1.4 Riptide fixture".utf8), nil)
            return nil
        }
        UIPasteboard.general.setItemProviders([document], localOnly: true, expirationDate: nil)
        pasteFromEditMenu()
        let file = app.staticTexts["Fixture report.pdf"]
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "remove-attachment").count, 2)
        XCTAssertEqual(editor.value as? String, "Please review")
        capture(app, as: "Image and PDF pasted into the shared Riptide composer")

        app.buttons["send-message"].tap()
        let sent = app.scrollViews["chat-transcript"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Attached: Fixture report.pdf")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 8))
    }

    @MainActor
    func testHermesComposerOffersNativeAttachmentPickers() {
        let app = freshApp()
        openMainChat(in: app, agent: "hermes")
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Can you review this?")
        let add = app.buttons["add-attachments"]
        add.tap()
        XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        captureAttachmentMenu(as: "Riptide attachment menu")

        app.buttons["Files"].tap()
        let browse = app.buttons["Browse"]
        let recents = app.buttons["Recents"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5) || recents.exists)
        capture(app, as: "Riptide Files picker")
    }

    @MainActor
    func testHermesPhotoAttachmentCanBeRemovedAndSentWithoutText() throws {
        guard ProcessInfo.processInfo.environment["RIPTIDE_ATTACHMENT_PHOTO_SEEDED"] == "1" else {
            throw XCTSkip("Seed one photo with simctl addmedia and set RIPTIDE_ATTACHMENT_PHOTO_SEEDED.")
        }
        continueAfterFailure = false
        let app = freshApp()
        openMainChat(in: app, agent: "hermes")
        let add = app.buttons["add-attachments"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))

        func selectPhoto() {
            add.tap()
            app.buttons["Photos"].tap()
            let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 8), app.debugDescription)
            photo.tap()
            let done = app.navigationBars["Photos"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 4), app.debugDescription)
            XCTAssertTrue(done.isEnabled, app.debugDescription)
            done.tap()
            XCTAssertTrue(app.buttons["remove-attachment"].waitForExistence(timeout: 10), app.debugDescription)
        }

        selectPhoto()
        capture(app, as: "Riptide photo attachment ready to send")
        XCTAssertTrue(app.buttons["send-message"].isEnabled)
        app.buttons["remove-attachment"].tap()
        XCTAssertFalse(app.buttons["send-message"].isEnabled)
        selectPhoto()
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.scrollViews["chat-transcript"].staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Attached: Photo-")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["remove-attachment"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testCodexNewSavedAndLiveChatsShareTheAttachmentMenu() throws {
        continueAfterFailure = false
        let (app, _) = try openCodexFixture()
        func verifyMenu(_ name: String) {
            let add = app.buttons["add-attachments"]
            XCTAssertTrue(add.waitForExistence(timeout: 8))
            add.tap()
            XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 4))
            XCTAssertTrue(app.buttons["Photos"].exists)
            XCTAssertTrue(app.buttons["Files"].exists)
            captureAttachmentMenu(as: name)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
            XCTAssertTrue(app.buttons["Camera"].waitForNonExistence(timeout: 4))
        }

        verifyMenu("Attachments in a saved Codex chat")
        app.navigationBars.buttons["BackButton"].tap()
        let newChat = app.buttons["workspace-new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        capture(app, as: "Codex workspace with New chat")
        newChat.tap()
        XCTAssertTrue(app.staticTexts["New Codex fixture"].waitForExistence(timeout: 8))
        verifyMenu("Attachments in a new Codex chat")
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["watch-desktop-codex"].tap()
        XCTAssertTrue(app.staticTexts["Watching a turn already in progress"].waitForExistence(timeout: 8))
        verifyMenu("Attachments while steering Codex")
    }

    @MainActor
    func testCodexComposerChangesNativeSpeedModelAndIntelligence() throws {
        continueAfterFailure = false
        let (app, _) = try openCodexFixture()
        let fast = app.buttons["fast-mode"]
        let model = app.buttons["model-options"]
        XCTAssertTrue(fast.waitForExistence(timeout: 8))
        let context = app.buttons["context-usage"]
        XCTAssertEqual(context.value as? String, "Usage unavailable")
        context.tap()
        let unavailable = app.staticTexts["context-unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        capture(app, as: "Codex context unavailable")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "6.2 Sol, Extra High")
        XCTAssertEqual(fast.value as? String, "Off")
        capture(app, as: "Codex Fast mode off")

        fast.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "On"), object: fast)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        capture(app, as: "Codex Fast mode on")

        fast.tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Off"), object: fast)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)

        model.tap()
        let effort = app.descendants(matching: .any).matching(identifier: "intelligence-steps").firstMatch
        XCTAssertTrue(effort.waitForExistence(timeout: 5))
        capture(app, as: "Codex quick intelligence picker")
        app.buttons["advanced-model-controls"].tap()
        app.buttons["config-picker-model"].tap()
        let astra = app.buttons["config-model-gpt-6.2-astra"]
        XCTAssertTrue(astra.waitForExistence(timeout: 5))
        capture(app, as: "Codex model list")
        astra.tap()
        app.buttons["Done"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "6.2 Astra, Medium"), object: model)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        XCTAssertTrue(fast.waitForNonExistence(timeout: 5))
        XCTAssertTrue(context.exists)
    }

    @MainActor
    func testCodexDesktopWatcherShowsReportedContextUsage() throws {
        continueAfterFailure = false
        let app = try launchCodexFixture(portKey: "RIPTIDE_UX_LIVE_FIXTURE_PORT")
        app.buttons["watch-desktop-codex"].tap()
        let context = app.buttons["context-usage"]
        XCTAssertTrue(context.waitForExistence(timeout: 8))
        context.tap()
        let values = app.staticTexts["context-values"]
        XCTAssertTrue(values.waitForExistence(timeout: 5))
        XCTAssertEqual(values.label, "\(8_000.formatted()) of \(32_000.formatted()) tokens used")
        capture(app, as: "Codex desktop watch context usage")
    }

    @MainActor
    func testCodexDesktopWatcherHidesProgressOnCompletion() throws {
        continueAfterFailure = false
        let app = try launchCodexFixture(portKey: "RIPTIDE_UX_WATCH_PROGRESS_PORT")
        app.buttons["watch-desktop-codex"].tap()
        let progress = app.staticTexts["Checking the current changes."]
        XCTAssertTrue(progress.waitForExistence(timeout: 14))
        capture(app, as: "Codex desktop watcher while progress is visible")
        let final = app.staticTexts["The fixture turn is complete."]
        XCTAssertTrue(final.waitForExistence(timeout: 16))
        XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
        capture(app, as: "Codex desktop watcher after progress disappears")
    }

    @MainActor
    func testHermesComposerChangesFastMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launch()
        openMainChat(in: app, agent: "hermes")
        let fast = app.buttons["fast-mode"]
        XCTAssertTrue(fast.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["context-usage"].exists)
        XCTAssertTrue(app.buttons["model-options"].exists)
        XCTAssertEqual(fast.value as? String, "Off")
        for value in ["On", "Off"] {
            fast.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: fast)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            if value == "On" { capture(app, as: "Hermes Fast mode on") }
        }
    }

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
    func testHermesKeepsTheReadingPositionAndHidesLatestAtTheBottom() {
        continueAfterFailure = false
        let app = freshApp()
        openMainChat(in: app, agent: "hermes")
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("streaming demo")
        app.buttons["send-message"].tap()

        let latest = app.staticTexts["Long stream complete."]
        let transcript = app.scrollViews["chat-transcript"]
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["stop-reply"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(isVisible(latest, in: transcript))
        let initialY = latest.frame.midY

        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.45))
        let end = start.withOffset(CGVector(dx: 0, dy: 48))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)

        XCTAssertTrue(jump.waitForExistence(timeout: 3), "A small scroll should pause following the latest reply.")
        let displacement = latest.frame.midY - initialY
        XCTAssertGreaterThan(displacement, 10, "The transcript snapped back to the bottom.")
        XCTAssertLessThan(displacement, 112, "The gesture should stay inside the old auto-follow range.")
        capture(app, as: "Chat stays in place after a short scroll")

        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertEqual(latest.frame.midY, initialY, accuracy: 2)
        capture(app, as: "Chat returns to the latest reply")

        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        transcript.swipeUp(velocity: .slow)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Scrolling back to the bottom should resume following.")
        XCTAssertEqual(latest.frame.midY, initialY, accuracy: 2)
        capture(app, as: "Chat at the bottom after scrolling")
    }

    @MainActor
    func testReadingHistoryStaysInPlaceDuringAReplyAndReopensAtTheLatestMessage() {
        continueAfterFailure = false
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
        let latest = app.staticTexts["Long stream complete."]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertTrue(jump.exists)
        XCTAssertFalse(isVisible(latest, in: transcript))
        transcript.swipeUp(velocity: .slow)
        XCTAssertTrue(jump.exists, "Leave the chat while reading its history.")
        app.buttons["BackButton"].tap()
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        main.tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 8))
        XCTAssertTrue(isVisible(latest, in: transcript), "Reopening the chat should show the newest message.")
        XCTAssertFalse(jump.exists)
        capture(app, as: "Reopened chat at the latest message")
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
    func testTheAgentsGridReachesTheLastAgentAndListsItsChats() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_BUSY_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["sidebar-inbox"].isSelected)
        let grid = app.showAgentGrid()
        let last = grid.buttons["sidebar-agent-ops-12"]
        for _ in 0..<8 where !last.isHittable { grid.swipeUp() }
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertEqual(app.buttons["agent-workspace-heading"].label, "Ops 12")
        let main = app.buttons["sidebar-main-chat"]
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-chat-ops-12-sample-")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        XCTAssertLessThan(main.frame.minY, history.frame.minY)
        XCTAssertTrue(app.staticTexts["Side chats"].exists)
        capture(app, as: "Agent with main and side chats")
        main.tap()
        let heading = app.buttons["chats-button"]
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        XCTAssertEqual(heading.value as? String, "Ops 12")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["sidebar-agents"].isSelected)
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
        let context = app.buttons["context-usage"]
        XCTAssertEqual(context.value as? String, 0.25.formatted(.percent) + " used")
        context.tap()
        let values = app.staticTexts["context-values"]
        XCTAssertTrue(values.waitForExistence(timeout: 5))
        XCTAssertEqual(values.label, "\(8_000.formatted()) of \(32_000.formatted()) tokens used")
    }

    @MainActor
    func testCodexTapSteersAndLongPressQueuesAfterTheActiveTurn() throws {
        let (app, editor) = try openCodexFixture()
        continueAfterFailure = false
        editor.tap()
        editor.typeText("Review the draft")
        app.buttons["Send"].tap()

        let stop = app.buttons["stop-codex-turn"]
        let steer = app.buttons["codex-steer-send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        XCTAssertFalse(steer.exists)
        editor.tap()
        editor.typeText("Focus on the opening paragraph")
        XCTAssertTrue(steer.isEnabled)
        XCTAssertFalse(stop.exists)
        capture(app, as: "Tap to steer")
        steer.tap()
        let transcript = app.scrollViews["codex-saved-transcript"]
        let steeringMessage = transcript.staticTexts["Focus on the opening paragraph"]
        XCTAssertTrue(steeringMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(steer.exists)
        let receipts = transcript.staticTexts.matching(identifier: "message-receipt")
        XCTAssertTrue(isVisible(transcript.staticTexts["Review the draft"], in: transcript))
        XCTAssertEqual(receipts.count, 1)
        XCTAssertGreaterThanOrEqual(receipts.firstMatch.frame.minY, steeringMessage.frame.maxY)
        capture(app, as: "One Codex receipt under the latest message")

        let followUp = "finish without approval and check the conclusion"
        editor.tap()
        editor.typeText(followUp)
        steer.press(forDuration: 1)
        let queue = app.buttons["queue-follow-up"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        XCTAssertFalse(transcript.staticTexts[followUp].exists)
        capture(app, as: "Hold Send to queue")
        queue.tap()
        let queued = app.buttons["queued-messages"]
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        XCTAssertFalse(transcript.staticTexts[followUp].exists)
        capture(app, as: "Follow-up queued")

        let decline = app.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 8))
        decline.tap()
        XCTAssertTrue(transcript.staticTexts["This reply survived switching workspaces."].waitForExistence(timeout: 8))
        XCTAssertTrue(transcript.staticTexts[followUp].waitForExistence(timeout: 8))
        XCTAssertTrue(queued.waitForNonExistence(timeout: 5))
        XCTAssertTrue(transcript.staticTexts["A reply finished in the other workspace."].waitForExistence(timeout: 12))
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.firstMatch.label, "Seen")
        XCTAssertGreaterThanOrEqual(receipts.firstMatch.frame.minY, transcript.staticTexts[followUp].frame.maxY)
    }

    @MainActor
    func testHermesTapSteersAndDictationCanQueue() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1"
        continueAfterFailure = false
        app.launch()
        openMainChat(in: app, agent: "hermes")
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Show an approval")
        let send = app.buttons["send-message"]
        send.tap()
        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        let stop = app.buttons["stop-reply"]
        XCTAssertTrue(stop.exists)
        XCTAssertFalse(send.exists)
        capture(app, as: "Empty running composer shows Stop")
        editor.tap()
        editor.typeText("a")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(stop.exists)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(stop.exists)
        XCTAssertFalse(send.exists)
        editor.typeText("Focus on the draft")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(stop.exists)
        capture(app, as: "Running composer with a draft shows Send")
        send.tap()
        let transcript = app.scrollViews["chat-transcript"]
        let steeringMessage = transcript.staticTexts["Focus on the draft"]
        XCTAssertTrue(steeringMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(deny.exists)
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(send.exists)
        let receipts = transcript.staticTexts.matching(identifier: "message-receipt")
        XCTAssertTrue(isVisible(transcript.staticTexts["Show an approval"], in: transcript))
        XCTAssertEqual(receipts.count, 1)
        XCTAssertGreaterThanOrEqual(receipts.firstMatch.frame.minY, steeringMessage.frame.maxY)
        capture(app, as: "One Hermes receipt under the latest message")

        app.buttons["dictation-start"].tap()
        let dictationSend = app.buttons["dictation-send"]
        XCTAssertTrue(dictationSend.waitForExistence(timeout: 5))
        dictationSend.press(forDuration: 1)
        let queue = app.buttons["queue-follow-up"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        capture(app, as: "Hermes dictation queue option")
        queue.tap()
        let queued = app.buttons["queued-messages"]
        XCTAssertTrue(queued.waitForExistence(timeout: 8))
        let dictated = transcript.staticTexts["Add a quick summary of the open items."]
        XCTAssertFalse(dictated.exists)
        deny.tap()
        XCTAssertTrue(dictated.waitForExistence(timeout: 8))
        XCTAssertTrue(queued.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testHermesCanSteerAnAlreadyRunningReplyAndExplicitlyQueue() {
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_FIXTURE_OBSERVED_TURN"] = "1"
        continueAfterFailure = false
        app.launch()
        openMainChat(in: app, agent: "hermes")

        let deny = app.buttons["approval-reject_once"]
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["stop-reply"].exists)
        let editor = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        editor.tap()
        editor.typeText("Focus on the draft")
        let send = app.buttons["send-message"]
        XCTAssertEqual(send.label, "Steer")
        capture(app, as: "Steer an existing Hermes reply")
        send.tap()
        let transcript = app.scrollViews["chat-transcript"]
        XCTAssertTrue(transcript.staticTexts["Focus on the draft"].waitForExistence(timeout: 5))
        XCTAssertTrue(deny.exists)

        editor.tap()
        editor.typeText("Send a separate follow-up")
        send.press(forDuration: 1)
        let queue = app.buttons["queue-follow-up"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        capture(app, as: "Hold to queue a Hermes follow-up")
        queue.tap()
        let followUp = transcript.staticTexts["Send a separate follow-up"]
        XCTAssertTrue(app.buttons["queued-messages"].waitForExistence(timeout: 5))
        XCTAssertFalse(followUp.exists)
        deny.tap()
        XCTAssertTrue(followUp.waitForExistence(timeout: 8))
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
        XCTAssertEqual(app.staticTexts["turn-working"].label, "Working")
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
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
        app.buttons["codex-chat-actions"].tap()
        app.buttons["Show Tool Calls"].tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        app.buttons["codex-chat-heading"].tap()
        XCTAssertTrue(app.buttons["codex-saved-chat"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    func testSavedCodexHidesProgressOnCompletion() throws {
        continueAfterFailure = false
        let (app, editor) = try openCodexFixture()
        editor.tap()
        editor.typeText("show live feedback")
        app.buttons["Send"].tap()
        let progress = app.staticTexts["Checking the current changes."]
        XCTAssertTrue(progress.waitForExistence(timeout: 12))
        capture(app, as: "Saved Codex chat while progress is visible")
        let final = app.staticTexts["The fixture turn is complete."]
        XCTAssertTrue(final.waitForExistence(timeout: 16))
        XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
        capture(app, as: "Saved Codex chat after progress disappears")
    }

    @MainActor
    private func launchCodexFixture(portKey: String = "RIPTIDE_UX_FIXTURE_PORT", dictation: Bool = false) throws -> XCUIApplication {
        guard let port = ProcessInfo.processInfo.environment[portKey] else {
            throw XCTSkip("Start Host/ux_codex_fixture.py and pass \(portKey) to the test runner.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = "ws://127.0.0.1:\(port)"
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = "fixture-" + String(repeating: "x", count: 40)
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = "/riptide-ux-fixture"
        if dictation { app.launchEnvironment["RIPTIDE_DICTATION_FIXTURE"] = "1" }
        app.launch()
        app.openAgentWorkspace("local-codex")
        return app
    }

    @MainActor
    private func openCodexFixture(dictation: Bool = false) throws -> (XCUIApplication, XCUIElement) {
        let app = try launchCodexFixture(dictation: dictation)
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
        if app.buttons["agent-workspace-heading"].exists { back.tap() }
        XCTAssertTrue(app.buttons["sidebar-agents"].isSelected)
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

        XCTAssertFalse(app.scrollViews["agent-grid"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Inbox")).firstMatch.exists)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["agent-workspace-heading"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["agent-workspace-heading"].label, "OpenClaw")
        app.navigationBars.buttons["BackButton"].tap()
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
        XCTAssertTrue(app.buttons["agent-workspace-heading"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
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
        XCTAssertTrue(app.buttons["sidebar-agents"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func openMainChat(in app: XCUIApplication, agent: String = "openclaw") {
        app.openAgentWorkspace(agent)
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 8))
        main.tap()
    }

    @MainActor
    private func captureAttachmentMenu(as name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
