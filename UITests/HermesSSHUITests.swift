import XCTest

final class HermesSSHUITests: XCTestCase {
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
        let hermes = app.scrollViews["sidebar-workspace-tabs"].buttons
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 12))
        if !hermes.isSelected { hermes.tap() }
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
        fill(app.textFields["Name"], with: "Hermes VPS")
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
            let hermes = app.scrollViews["sidebar-workspace-tabs"].buttons
                .matching(NSPredicate(format: "label == %@", "Hermes VPS")).firstMatch
            XCTAssertTrue(hermes.waitForExistence(timeout: 12))
            if !hermes.isSelected { hermes.tap() }
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
