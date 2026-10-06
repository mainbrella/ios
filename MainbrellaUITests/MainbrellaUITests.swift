import XCTest

@MainActor final class MainbrellaUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testProductionWorkflow() throws {
        guard let key = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_KEY"] else {
            throw XCTSkip("Run scripts/ProductionSmoke.swift with --ui to check the real production workflow.")
        }
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launch()
        guard app.secureTextFields["API key"].waitForExistence(timeout: 10) else {
            XCTFail("Use a simulator without an existing saved account key.")
            return
        }
        guard let workspaceID = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_WORKSPACE_ID"] else {
            XCTFail("Temporary production workspace identity is missing.")
            return
        }
        addTeardownBlock {
            app.terminate(); app.launch()
            if app.tabBars.buttons["Account"].waitForExistence(timeout: 5) { app.tabBars.buttons["Account"].tap() }
            else if app.buttons["Account"].exists { app.buttons["Account"].tap() }
            if app.buttons["Remove saved key"].waitForExistence(timeout: 5) { app.buttons["Remove saved key"].tap() }
        }
        app.secureTextFields["API key"].tap()
        app.secureTextFields["API key"].typeText(key)
        app.buttons["Connect"].tap()
        let projects = app.tabBars.buttons["Projects"].exists ? app.tabBars.buttons["Projects"] : app.buttons["Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 30))
        let liveStatus = app.descendants(matching: .any).matching(identifier: "live-status").firstMatch
        XCTAssertTrue(liveStatus.waitForExistence(timeout: 15))
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Live updates: Live"), object: liveStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 15), .completed)
        guard let generation = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_GENERATION"] else {
            XCTFail("Production generation is missing.")
            return
        }
        // The workspace is owned by the smoke test. Create real work after the UI
        // has attached, then verify that both the list and open output update.
        let liveExecutionID = try createExecution(key: key, workspaceID: workspaceID, generation: generation)
        let liveExecution = app.descendants(matching: .any).matching(identifier: "execution-\(workspaceID)-\(liveExecutionID)").firstMatch
        XCTAssertTrue(liveExecution.waitForExistence(timeout: 30))
        liveExecution.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ios-live-finished")).firstMatch.waitForExistence(timeout: 35))
        XCTAssertTrue(app.staticTexts["Succeeded"].exists)
        let liveScreenshot = XCTAttachment(screenshot: app.screenshot())
        liveScreenshot.name = "Live execution updated over WebSocket"
        liveScreenshot.lifetime = .keepAlways
        add(liveScreenshot)
        app.navigationBars["Execution"].buttons.element(boundBy: 0).tap()
        guard let executionID = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_EXECUTION_ID"] else {
            XCTFail("Production execution identity is missing.")
            return
        }
        let execution = app.descendants(matching: .any).matching(identifier: "execution-\(workspaceID)-\(executionID)").firstMatch
        XCTAssertTrue(execution.waitForExistence(timeout: 15))
        execution.tap()
        XCTAssertTrue(app.staticTexts["ios-check-output"].waitForExistence(timeout: 15))
        app.segmentedControls.buttons["Errors"].tap()
        XCTAssertTrue(app.staticTexts["ios-check-error"].exists)
        app.buttons["Copy errors"].tap()
        XCTAssertTrue(app.buttons["Copied"].exists)
        let executionScreenshot = XCTAttachment(screenshot: app.screenshot())
        executionScreenshot.name = "Production execution inspection"
        executionScreenshot.lifetime = .keepAlways
        add(executionScreenshot)
        app.buttons["share-execution-output"].tap()
        let systemShareScreenshot = XCTAttachment(screenshot: app.screenshot())
        systemShareScreenshot.name = "System share sheet"
        systemShareScreenshot.lifetime = .keepAlways
        add(systemShareScreenshot)
        var share = app.cells["Mainbrella"]
        if !share.waitForExistence(timeout: 5) {
            let more = app.cells["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            share = app.cells["Mainbrella"]
        }
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Mainbrella must be registered in the system share sheet")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share to Mainbrella"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Connect your account in Mainbrella, then share again."].exists,
                       "The extension must read the account key saved by the containing app")
        let shareInstruction = app.textFields["Instruction for the agent"]
        XCTAssertTrue(shareInstruction.waitForExistence(timeout: 10))
        shareInstruction.tap(); shareInstruction.typeText("Investigate this error from iPhone")
        let shareDestination = app.buttons["share-workspace"]
        if shareDestination.exists {
            shareDestination.tap()
            let destination = app.buttons.containing(NSPredicate(format: "label ENDSWITH %@", "· " + workspaceID)).firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            destination.tap()
        }
        app.swipeUp()
        let shareScreenshot = XCTAttachment(screenshot: app.screenshot())
        shareScreenshot.name = "Production native share extension"
        shareScreenshot.lifetime = .keepAlways
        add(shareScreenshot)
        XCTAssertTrue(app.buttons["Send to workspace"].isEnabled)
        app.buttons["Send to workspace"].tap()
        XCTAssertTrue(app.staticTexts["Saved to workspace inbox"].waitForExistence(timeout: 35))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Execution"].waitForExistence(timeout: 10))
        app.navigationBars["Execution"].buttons.element(boundBy: 0).tap()
        projects.tap()
        let sendInbox = app.buttons["send-inbox-\(workspaceID)"]
        XCTAssertTrue(sendInbox.waitForExistence(timeout: 15))
        sendInbox.tap()
        let instruction = app.textFields["Instruction for the agent"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        let attachFile = app.buttons["Attach a file"]
        XCTAssertTrue(attachFile.waitForExistence(timeout: 5))
        attachFile.tap()
        dismissFilePicker(app)
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        instruction.tap(); instruction.typeText("iOS production handoff check")
        app.textFields["Context for the agent"].tap()
        app.textFields["Context for the agent"].typeText("https://mainbrella.com/")
        app.swipeUp()
        app.buttons["submit-inbox-message"].tap()
        XCTAssertTrue(app.staticTexts["Saved to workspace inbox"].waitForExistence(timeout: 35))
        app.buttons["Done"].tap()
        app.buttons["open-preview-\(workspaceID)"].tap()
        app.alerts.buttons["Open"].tap()
        let capture = app.buttons["Screenshot & annotate"]
        XCTAssertTrue(capture.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(30)
        while !capture.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(capture.isEnabled)
        capture.tap()
        XCTAssertTrue(app.navigationBars["Fix this"].waitForExistence(timeout: 10))
        let canvas = app.descendants(matching: .any).matching(identifier: "annotationCanvas").firstMatch
        XCTAssertTrue(canvas.exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6)))
        let feedback = app.textFields["Instruction for the agent"]
        feedback.tap(); feedback.typeText("Screenshot workflow check")
        app.buttons["Upload feedback"].tap()
        XCTAssertTrue(app.staticTexts["Feedback saved to /workspace/inbox."].waitForExistence(timeout: 35))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production screenshot handoff"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testProductionHandoff() throws {
        guard let key = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_KEY"],
              let workspaceID = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_WORKSPACE_ID"] else {
            throw XCTSkip("Explicit production credentials and a test-owned workspace are required.")
        }
        let app = XCUIApplication(); app.launch()
        guard app.secureTextFields["API key"].waitForExistence(timeout: 10) else {
            XCTFail("Use a simulator without an existing saved account key.")
            return
        }
        addTeardownBlock {
            app.terminate(); app.launch()
            if app.tabBars.buttons["Account"].waitForExistence(timeout: 5) { app.tabBars.buttons["Account"].tap() }
            else if app.buttons["Account"].exists { app.buttons["Account"].tap() }
            if app.buttons["Remove saved key"].waitForExistence(timeout: 5) { app.buttons["Remove saved key"].tap() }
        }
        app.secureTextFields["API key"].tap(); app.secureTextFields["API key"].typeText(key)
        app.buttons["Connect"].tap()
        let projects = app.tabBars.buttons["Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 30)); projects.tap()
        let send = app.buttons["send-inbox-\(workspaceID)"]
        XCTAssertTrue(send.waitForExistence(timeout: 15)); send.tap()
        let picker = app.buttons["Attach a file"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        dismissFilePicker(app)
        let instruction = app.textFields["Instruction for the agent"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: instruction)], timeout: 5), .completed)
        instruction.tap(); instruction.typeText("iOS native handoff check")
        app.textFields["Context for the agent"].tap()
        app.textFields["Context for the agent"].typeText("Device QA notes for the current agent")
        app.swipeUp()
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Native workspace handoff"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["submit-inbox-message"].tap()
        XCTAssertTrue(app.staticTexts["Saved to workspace inbox"].waitForExistence(timeout: 35))
    }

    func testRemoveSmokeAccount() throws {
        guard ProcessInfo.processInfo.environment["MAINBRELLA_REMOVE_SMOKE_ACCOUNT"] == "1" else {
            throw XCTSkip("Explicit recovery for a dedicated production-test simulator only.")
        }
        let app = XCUIApplication()
        app.launch()
        if app.secureTextFields["API key"].waitForExistence(timeout: 3) && !app.tabBars.firstMatch.exists && !app.buttons["Account"].exists { return }
        if app.tabBars.buttons["Account"].waitForExistence(timeout: 5) { app.tabBars.buttons["Account"].tap() }
        else { app.buttons["Account"].tap() }
        XCTAssertTrue(app.buttons["Remove saved key"].waitForExistence(timeout: 10))
        app.buttons["Remove saved key"].tap()
        XCTAssertTrue(app.navigationBars["Connect to Mainbrella"].waitForExistence(timeout: 10))
    }

    private func dismissFilePicker(_ app: XCUIApplication) {
        // The document picker embeds a remote accessibility tree. Scope the
        // control to its navigation bar so we never tap the composer's Cancel.
        let cancel = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func createExecution(key: String, workspaceID: String, generation: String) throws -> String {
        var url = URLComponents(string: "https://api.mainbrella.com/containers/executions")!
        url.queryItems = [.init(name: "id", value: workspaceID), .init(name: "createdAt", value: generation)]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios-live-ui-" + UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": "printf 'ios-live-start\\n'; sleep 8; printf 'ios-live-finished\\n'", "timeoutMs": 30000
        ])
        let completed = expectation(description: "Production execution created")
        var executionID: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                executionID = result["id"] as? String
            }
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 35)
        guard let executionID else {
            throw NSError(domain: "MainbrellaProductionTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Production test execution could not be created"])
        }
        return executionID
    }

    func testDisconnectedAccountGate() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Connect to Mainbrella"].waitForExistence(timeout: 10),
                      "Run account-gate tests on a simulator without a saved API key.")
        XCTAssertTrue(app.navigationBars["Connect to Mainbrella"].exists)
        XCTAssertTrue(app.secureTextFields["API key"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "api.mainbrella.com")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Connect"].isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Open preview"].exists)
        app.secureTextFields["API key"].tap()
        app.secureTextFields["API key"].typeText("   ")
        XCTAssertFalse(app.buttons["Connect"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Account connection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTabletAccountGateRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet layout check") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Connect to Mainbrella"].waitForExistence(timeout: 10),
                      "Run account-gate tests on a simulator without a saved API key.")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.secureTextFields["API key"].isHittable)
            XCTAssertTrue(app.buttons["Create an API key"].isHittable)
        }
    }
}
