import XCTest

final class CodexLiveUITests: XCTestCase {
    @MainActor
    func testCallsFromTheSavedChatAndReturnsToItsHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proofPath = environment["RIPTIDE_CODEX_PROOF_DIR"],
              let endpoint = environment["RIPTIDE_CODEX_URL"],
              let title = environment["RIPTIDE_CODEX_SAVED_CHAT_TITLE"] else {
            throw XCTSkip("Requires the local signed-in server and a seeded disposable saved chat.")
        }
        let proof = URL(filePath: proofPath, directoryHint: .isDirectory)
        let bearer = try String(contentsOf: proof.appending(path: "bearer"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = endpoint
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = bearer
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = proof.appending(path: "proof").path
        app.launchEnvironment["RIPTIDE_CODEX_VOICE_CHECK"] = "1"
        app.launch()

        app.openAgentWorkspace("local-codex")
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-chat-"))
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 12))
        saved.tap()
        let marker = app.staticTexts["Riptide saved-chat verification"]
        XCTAssertTrue(marker.waitForExistence(timeout: 12))
        let call = app.buttons["call-codex-in-chat"]
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        call.tap()
        let callStatus = app.staticTexts["codex-voice-status"]
        XCTAssertTrue(callStatus.waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Continuing “\(title)” using the host’s ChatGPT sign-in."].exists)
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Connected · Microphone off"), object: callStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 28), .completed, callStatus.label)
        capture(app, as: "Call in saved Codex chat")
        app.buttons["codex-voice-end"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: callStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 6), .completed)
        XCTAssertTrue(marker.exists)
        XCTAssertTrue(call.isEnabled)
    }

    @MainActor
    func testConnectsSubscriptionVoiceWithoutUsingMicrophone() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proofPath = environment["RIPTIDE_CODEX_PROOF_DIR"],
              let endpoint = environment["RIPTIDE_CODEX_URL"] else {
            throw XCTSkip("Requires a localhost Codex server signed into ChatGPT.")
        }
        let proof = URL(filePath: proofPath, directoryHint: .isDirectory)
        let bearer = try String(contentsOf: proof.appending(path: "bearer"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = endpoint
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = bearer
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = proof.appending(path: "proof").path
        app.launchEnvironment["RIPTIDE_CODEX_VOICE_CHECK"] = "1"
        app.launch()

        app.openAgentWorkspace("local-codex")
        app.buttons["watch-desktop-codex"].tap()
        let call = app.buttons["call-codex"]
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        call.tap()
        let status = app.staticTexts["codex-voice-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Connected · Microphone off"), object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed, status.label)
        capture(app, as: "Codex subscription voice")
        app.buttons["codex-voice-end"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    @MainActor
    func testLiveCodexComposerSteersAndOffersQueue() throws {
        continueAfterFailure = false
        let app = try openLiveCodexFixture(portKey: "RIPTIDE_UX_LIVE_FIXTURE_PORT", mode: "--live")
        let editor = app.descendants(matching: .any).matching(identifier: "codex-steer-input").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Check the first paragraph")
        let send = app.buttons["codex-steer-send"]
        send.tap()
        XCTAssertTrue(app.staticTexts["codex-steer-receipt"].waitForExistence(timeout: 8))

        editor.tap()
        editor.typeText("Review the summary next")
        send.press(forDuration: 1)
        let queue = app.buttons["queue-follow-up"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        queue.tap()
        XCTAssertTrue(app.buttons["queued-messages"].waitForExistence(timeout: 5))
        capture(app, as: "Desktop Codex follow-up queued")
    }

    @MainActor
    func testLiveCodexOnlyShowsLatestFollowUpReceipt() throws {
        continueAfterFailure = false
        let app = try openLiveCodexFixture(portKey: "RIPTIDE_UX_LIVE_PROGRESS_FIXTURE_PORT", mode: "--live --watch-progress")
        let editor = app.descendants(matching: .any).matching(identifier: "codex-steer-input").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let send = app.buttons["codex-steer-send"]
        let receipts = app.staticTexts.matching(identifier: "message-receipt")
        let first = "finish without approval: check the opening"
        let latest = "finish without approval: check the summary"

        XCTAssertTrue(app.staticTexts["The fixture turn is complete."].waitForExistence(timeout: 26))
        editor.tap()
        editor.typeText(first)
        send.tap()
        XCTAssertTrue(app.staticTexts["A reply finished in the other workspace."].waitForExistence(timeout: 12))
        XCTAssertEqual(receipts.firstMatch.label, "Seen")

        editor.tap()
        editor.typeText(latest)
        send.tap()
        let latestMessage = app.staticTexts[latest]
        XCTAssertTrue(latestMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[first].exists)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.firstMatch.label, "Delivered")
        XCTAssertGreaterThanOrEqual(receipts.firstMatch.frame.minY, latestMessage.frame.maxY)
        capture(app, as: "One live Codex receipt under the latest follow-up")
    }

    @MainActor
    private func openLiveCodexFixture(portKey: String, mode: String) throws -> XCUIApplication {
        guard let port = ProcessInfo.processInfo.environment[portKey] else {
            throw XCTSkip("Start the Codex UX fixture with \(mode) and pass \(portKey).")
        }
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_FIXTURE_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = "ws://127.0.0.1:\(port)"
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = "fixture-" + String(repeating: "x", count: 40)
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = "/riptide-ux-fixture"
        app.launch()
        app.openAgentWorkspace("local-codex")
        app.buttons["watch-desktop-codex"].tap()
        return app
    }

    @MainActor
    func testWatchesAndSteersAnExistingCodexTurn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proofPath = environment["RIPTIDE_CODEX_PROOF_DIR"],
              let endpoint = environment["RIPTIDE_CODEX_URL"] else {
            throw XCTSkip("Requires a localhost Codex server and a running native terminal turn.")
        }
        let marker = "RIPTIDE-STEER-714"
        let proof = URL(filePath: proofPath, directoryHint: .isDirectory)
        let bearer = try String(contentsOf: proof.appending(path: "bearer"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchEnvironment["RIPTIDE_CODEX_URL"] = endpoint
        app.launchEnvironment["RIPTIDE_CODEX_BEARER"] = bearer
        app.launchEnvironment["RIPTIDE_CODEX_WORKSPACE"] = proof.appending(path: "proof").path
        app.launch()

        app.openAgentWorkspace("local-codex")
        app.buttons["watch-desktop-codex"].tap()

        let status = app.staticTexts["codex-turn-status"]
        let watching = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Watching a turn already in progress"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [watching], timeout: 15), .completed, status.label)
        let turnLabel = app.staticTexts["codex-turn-id"].label
        let turnID = try XCTUnwrap(turnLabel.split(separator: " ").last)

        let progress = app.staticTexts["codex-live-updates"]
        XCTAssertTrue(progress.waitForExistence(timeout: 22))
        let firstUpdate = progress.label
        let moreOutput = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", firstUpdate), object: progress
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moreOutput], timeout: 18), .completed)

        let input = app.descendants(matching: .any).matching(identifier: "codex-steer-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Reply exactly \(marker) when done.")
        app.buttons["codex-steer-send"].tap()

        let receipt = app.staticTexts["codex-steer-receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 8))
        XCTAssertEqual(receipt.label, "Steering accepted · Turn \(turnID)")
        capture(app, as: "Accepted steering on turn \(turnID)")
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 160))
        XCTAssertEqual(status.label, "Turn completed")
        XCTAssertEqual(app.staticTexts["codex-turn-id"].label, turnLabel)
        capture(app, as: "Completed turn \(turnID)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
