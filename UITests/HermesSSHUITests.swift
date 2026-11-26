import XCTest

final class HermesSSHUITests: XCTestCase {
    @MainActor
    func testNativeBrowserRequestResumesTheSameTurn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let label = environment["RIPTIDE_HERMES_SCREEN_AGENT"],
              let fixtureURL = environment["RIPTIDE_HERMES_BROWSER_FIXTURE_URL"] else {
            throw XCTSkip("Provide a paired Hermes agent and the URL of a disposable page with an autofocus text input.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let hermes = app.showAgentGrid().buttons
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 12))
        hermes.tap()
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        main.tap()
        let chats = app.buttons["chats-button"]
        XCTAssertTrue(chats.waitForExistence(timeout: 25))
        chats.tap()
        app.buttons["new-chat"].tap()
        XCTAssertTrue(app.buttons["close-chats"].waitForNonExistence(timeout: 20))
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        composer.tap()
        composer.typeText("Riptide browser handoff verification. Use computer_use to capture and chrome_input to navigate Chrome to \(fixtureURL). "
            + "Capture the fixture, focus its test input, and call chrome_handoff so I can type the test value. "
            + "After I hand back, capture the same Chrome window and reply with 'The browser received ' plus the visible input value. "
            + "Use only the paired Chrome tools.")
        app.buttons["send-message"].tap()
        let request = app.buttons["hermes-browser-request"]
        XCTAssertTrue(request.waitForExistence(timeout: 135))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Allow Chrome input")).firstMatch.exists)
        request.tap()
        let takeover = app.buttons["hermes-take-over"]
        let streaming = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: takeover)
        XCTAssertEqual(XCTWaiter.wait(for: [streaming], timeout: 55), .completed)
        takeover.tap()
        let keyboard = app.buttons["Show keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 12))
        keyboard.tap()
        app.typeText("riptide831")
        app.buttons["hermes-hand-back"].tap()
        XCTAssertTrue(app.buttons["stop-reply"].waitForNonExistence(timeout: 65))
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The browser received riptide831")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
    }

    @MainActor
    func testNativeBrowserTakeoverAndHandback() throws {
        guard let label = ProcessInfo.processInfo.environment["RIPTIDE_HERMES_SCREEN_AGENT"] else {
            throw XCTSkip("Provide an SSH-paired Hermes agent with Bot Screen enabled.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let hermes = app.showAgentGrid().buttons
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 12))
        hermes.tap()
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        main.tap()
        let actions = app.buttons["chat-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: actions)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        actions.tap()
        app.buttons["open-hermes-browser"].tap()
        let takeover = app.buttons["hermes-take-over"]
        XCTAssertTrue(takeover.waitForExistence(timeout: 15))
        let streaming = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: takeover)
        XCTAssertEqual(XCTWaiter.wait(for: [streaming], timeout: 55), .completed,
                       "The viewer did not complete the native RFB handshake.")
        takeover.tap()
        XCTAssertTrue(app.staticTexts["You’re in control"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Show keyboard"].waitForExistence(timeout: 8))
        app.buttons["hermes-hand-back"].tap()
        XCTAssertTrue(app.navigationBars["Hermes browser"].waitForNonExistence(timeout: 12))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        app.typeText("Back in chat")
        XCTAssertEqual(composer.value as? String, "Back in chat")
    }

    @MainActor
    func testReopensAlreadyPairedHermesChat() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let label = environment["RIPTIDE_SSH_EXISTING_AGENT_NAME"],
              let marker = environment["RIPTIDE_SSH_EXISTING_REPLY"] else {
            throw XCTSkip("Provide an existing paired Hermes agent and a known reply from its main chat.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let hermes = app.showAgentGrid().buttons
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 12))
        hermes.tap()
        let main = app.buttons["sidebar-main-chat"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        main.tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 35), "The existing SSH pairing did not replay the saved reply.")
    }

    @MainActor
    func testPairStreamAndRestoreTheRealHermesChat() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["RIPTIDE_SSH_PROOF_DIR"],
              let endpoint = environment["RIPTIDE_SSH_ENDPOINT"],
              let workspace = environment["RIPTIDE_SSH_WORKSPACE"],
              let fingerprint = environment["RIPTIDE_SSH_FINGERPRINT"] else {
            throw XCTSkip("Set up an authorized SSH ACP host and an enrollment coordinator for this live test.")
        }
        let label = environment["RIPTIDE_SSH_AGENT_NAME"] ?? "Hermes VPS"
        continueAfterFailure = false
        let proof = URL(filePath: directory, directoryHint: .isDirectory)
        let session = try String(contentsOf: proof.appending(path: "session"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launch()

        func button(_ identifier: String) -> XCUIElement {
            let item = app.buttons[identifier]
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            return item
        }
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 8))
            for _ in 0..<3 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        func fill(_ field: XCUIElement, with value: String) {
            reveal(field)
            field.tap()
            field.typeText(value)
        }

        let connectHermes = app.buttons["connect-hermes"]
        let onboarding = connectHermes.waitForExistence(timeout: 4)
        if onboarding {
            connectHermes.tap()
        } else {
            button("edit-roster").tap()
            button("pair-remote").tap()
        }
        let pairBar = app.navigationBars["Pair remote"]
        XCTAssertTrue(pairBar.waitForExistence(timeout: 12))
        if !onboarding {
            let backend = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Backend")).firstMatch
            if backend.exists && backend.isHittable { backend.tap() }
            else { app.staticTexts["Codex"].tap() }
            let hermesOption = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                               "Hermes", "sidebar-agent-hermes")).firstMatch
            reveal(hermesOption)
            hermesOption.tap()
            button("pair-transport").tap()
            button("SSH").tap()
        }
        fill(app.textFields["Name"], with: label)
        fill(app.textFields["pair-address"], with: endpoint)
        fill(app.textFields["Absolute workspace path"], with: workspace)
        fill(app.textFields["Existing main chat ID"], with: session)
        fill(app.textFields["pair-ssh-fingerprint"], with: fingerprint)
        let copy = button("pair-ssh-public-key")
        reveal(copy)
        copy.tap()
        try Data().write(to: proof.appending(path: "key-ready"))
        let enrolled = proof.appending(path: "enrolled")
        let enrollment = NSPredicate { _, _ in FileManager.default.fileExists(atPath: enrolled.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enrollment, object: nil)], timeout: 45), .completed)

        pairBar.buttons["Pair"].tap()
        XCTAssertTrue(pairBar.waitForNonExistence(timeout: 35), "Hermes pairing did not dismiss the form.")
        if !onboarding { app.navigationBars["Manage agents"].buttons["Done"].tap() }

        func openHermes() {
            let hermes = app.showAgentGrid().buttons
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(hermes.waitForExistence(timeout: 12))
            hermes.tap()
            button("sidebar-main-chat").tap()
        }

        openHermes()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: composer)],
                                       timeout: 25), .completed)
        composer.tap()
        composer.typeText("Read-only Riptide check. Reply with the word Riptide immediately followed by Verified, as one word. Do not use any tools.")
        button("send-message").tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "RiptideVerified")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 85), "The Hermes reply did not arrive in Riptide.")
        XCTAssertTrue(app.buttons["stop-reply"].waitForNonExistence(timeout: 15))
        app.terminate()
        app.launch()
        openHermes()
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "Hermes did not replay the saved reply after relaunch.")
        button("BackButton").tap()
        button("sidebar-inbox").tap()
        XCTAssertTrue(button("sidebar-inbox").isSelected)
        try Data().write(to: proof.appending(path: "live-verified"))
    }
}
