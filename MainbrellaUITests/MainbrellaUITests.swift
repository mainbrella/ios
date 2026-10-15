import XCTest

@MainActor final class MainbrellaUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testLocalComputeFundingForExistingAndZeroBalance() throws {
        guard ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE"] == "1" else {
            throw XCTSkip("Start scripts/builder-fixture.py and opt in with TEST_RUNNER_MAINBRELLA_BUILDER_FIXTURE=1.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MAINBRELLA_BUILDER_FIXTURE_PORT"] = ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE_PORT"]
        app.launch()
        if app.buttons["builder-account"].exists { app.buttons["builder-account"].tap() }
        if app.buttons["Sign out"].exists { app.buttons["Sign out"].tap() }
        addTeardownBlock {
            app.terminate(); app.launch()
            if app.buttons["builder-account"].waitForExistence(timeout: 5) {
                app.buttons["builder-account"].tap()
                if app.buttons["Sign out"].waitForExistence(timeout: 5) { app.buttons["Sign out"].tap() }
            }
        }
        for (email, balance) in [("builder@example.test", "$4.92"), ("zero@example.test", "$0.00")] {
            openSignIn(app)
            app.textFields["login-email"].tap()
            app.textFields["login-email"].typeText(email)
            app.secureTextFields["login-password"].tap()
            app.secureTextFields["login-password"].typeText("fixture-password")
            app.buttons["email-sign-in"].tap()
            XCTAssertTrue(app.buttons["add-compute-funds"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts[balance].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["compute-purchase-error"].exists)
            XCTAssertFalse(app.staticTexts["compute-availability-error"].exists)
            XCTAssertFalse(app.buttons["check-compute-purchases"].exists)
            if balance == "$0.00" {
                XCTAssertEqual(app.staticTexts["compute-funding-required"].label, "Add at least $4.99 to get started.")
            } else {
                XCTAssertFalse(app.staticTexts["compute-funding-required"].exists)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Compute funding \(balance)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["add-compute-funds"].tap()
            XCTAssertTrue(app.navigationBars["Add funds"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["check-compute-purchases"].waitForExistence(timeout: 15))
            let funding = XCTAttachment(screenshot: app.screenshot())
            funding.name = "Add funds options \(balance)"; funding.lifetime = .keepAlways; add(funding)
            app.buttons["Done"].tap()
            app.buttons["builder-account"].tap()
            XCTAssertTrue(app.buttons["add-compute-funds"].waitForExistence(timeout: 5))
            app.buttons["Sign out"].tap()
            XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
        }
    }

    func testLocalBuilderPromptStreamingAndPreview() throws {
        guard ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE"] == "1" else {
            throw XCTSkip("Start scripts/builder-fixture.py and opt in with TEST_RUNNER_MAINBRELLA_BUILDER_FIXTURE=1.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MAINBRELLA_BUILDER_FIXTURE_PORT"] = ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE_PORT"]
        app.launch()
        // The fixture uses normal sign-in; no authentication bypass is built into the app.
        if app.buttons["builder-account"].exists { app.buttons["builder-account"].tap() }
        if app.buttons["Sign out"].exists { app.buttons["Sign out"].tap() }
        openSignIn(app)
        app.textFields["login-email"].tap()
        app.textFields["login-email"].typeText("builder@example.test")
        app.secureTextFields["login-password"].tap()
        app.secureTextFields["login-password"].typeText("fixture-password")
        app.buttons["email-sign-in"].tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        guard prompt.exists else { return }
        addTeardownBlock {
            if app.buttons["builder-account"].exists {
                app.buttons["builder-account"].tap()
                if app.buttons["Sign out"].waitForExistence(timeout: 5) { app.buttons["Sign out"].tap() }
            }
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Workspace"].exists)
        XCTAssertFalse(app.buttons["Activity"].exists)
        XCTAssertFalse(app.buttons["Projects"].exists)
        XCTAssertTrue(app.buttons["builder-submit"].isHittable)
        XCTAssertEqual(app.buttons["builder-submit"].label, "Build website")
        XCTAssertTrue(app.buttons["builder-new-website"].exists)
        app.buttons["builder-websites"].tap()
        XCTAssertTrue(app.staticTexts["No saved websites yet."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "Native website composer"; empty.lifetime = .keepAlways; add(empty)
        prompt.tap(); prompt.typeText("Make me a website about frogs")
        app.buttons["builder-account"].tap()
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["Manage billing"].exists)
        XCTAssertFalse(app.staticTexts["Share to Mainbrella"].exists)
        XCTAssertFalse(app.staticTexts["Live updates"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(prompt.value as? String, "Make me a website about frogs")
        app.buttons["builder-submit"].tap()
        XCTAssertTrue(app.staticTexts["build-message-thought"].waitForExistence(timeout: 10))
        let progress = XCTAttachment(screenshot: app.screenshot())
        progress.name = "Streamed build progress"; progress.lifetime = .keepAlways; add(progress)
        XCTAssertTrue(app.staticTexts["builder-preview-url"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Frog Field Guide"].waitForExistence(timeout: 15))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Embedded website preview"; preview.lifetime = .keepAlways; add(preview)
        app.webViews.buttons["Meet the frogs"].tap()
        XCTAssertTrue(app.webViews.buttons["Spring peeper, tree frog, bullfrog"].exists)
        if app.segmentedControls["builder-panels"].exists {
            app.segmentedControls["builder-panels"].buttons["Build"].tap()
        }
        prompt.tap(); prompt.typeText("Add a section about ponds")
        app.buttons["builder-submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "build-status-turn-2").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["builder-preview-url"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.webViews.staticTexts["Frog Field Guide"].waitForExistence(timeout: 15))
        if UIDevice.current.userInterfaceIdiom == .pad {
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                XCTAssertTrue(app.buttons["builder-websites"].waitForExistence(timeout: 5))
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "iPad builder \(orientation.rawValue)"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["builder-websites"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.buttons["builder-websites"].tap()
        let website = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Frog Field Guide")).firstMatch
        XCTAssertTrue(website.waitForExistence(timeout: 10))
        website.tap()
        XCTAssertTrue(app.buttons["builder-new-website"].waitForExistence(timeout: 5))
        app.buttons["builder-new-website"].tap()
        XCTAssertTrue(app.staticTexts["What would you like to build?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["builder-submit"].isEnabled)
        app.buttons["builder-account"].tap()
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
    }

    func testLocalBuilderConcurrentSessionsAndPersistence() throws {
        guard ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE"] == "1" else {
            throw XCTSkip("Start scripts/builder-fixture.py --port 8791 --build-seconds 45 and opt in with MAINBRELLA_BUILDER_FIXTURE=1, MAINBRELLA_BUILDER_FIXTURE_PORT=8791.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MAINBRELLA_BUILDER_FIXTURE_PORT"] = ProcessInfo.processInfo.environment["MAINBRELLA_BUILDER_FIXTURE_PORT"]
        app.launch()
        if app.buttons["builder-account"].exists {
            app.buttons["builder-account"].tap()
            if app.buttons["Sign out"].waitForExistence(timeout: 3) { app.buttons["Sign out"].tap() }
            else if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        }
        openSignIn(app)
        app.textFields["login-email"].tap()
        app.textFields["login-email"].typeText("builder@example.test")
        app.secureTextFields["login-password"].tap()
        app.secureTextFields["login-password"].typeText("fixture-password")
        app.buttons["email-sign-in"].tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        guard prompt.exists else { return }
        addTeardownBlock {
            if app.buttons["builder-account"].exists {
                app.buttons["builder-account"].tap()
                if app.buttons["Sign out"].waitForExistence(timeout: 5) { app.buttons["Sign out"].tap() }
            }
        }

        XCTAssertTrue(app.buttons["builder-new-website"].waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("Make me a website about frogs")
        app.buttons["builder-submit"].tap()
        XCTAssertTrue(app.staticTexts["build-message-thought"].waitForExistence(timeout: 10))

        // Starting Birds from the bottom action creates a second saved app
        // while Frog is still running.
        app.buttons["builder-new-website"].tap()
        let birdPrompt = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        XCTAssertTrue(birdPrompt.waitForExistence(timeout: 5))
        birdPrompt.tap()
        birdPrompt.typeText("Make me a website about birds")
        app.buttons["builder-submit"].tap()
        XCTAssertTrue(app.staticTexts["build-message-thought"].waitForExistence(timeout: 10))

        app.buttons["builder-sessions"].tap()
        let frogRow = sessionRow(app, named: "Frog Field Guide")
        let birdRow = sessionRow(app, named: "Bird Field Guide")
        XCTAssertTrue(frogRow.waitForExistence(timeout: 10))
        XCTAssertTrue(birdRow.waitForExistence(timeout: 10))
        XCTAssertTrue(frogRow.label.contains("Building"))
        XCTAssertTrue(birdRow.label.contains("Building"))
        let activeSessions = XCTAttachment(screenshot: app.screenshot())
        activeSessions.name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad concurrent builder sessions" : "iPhone concurrent builder sessions"
        activeSessions.lifetime = .keepAlways
        add(activeSessions)

        // Reload with both builds active and confirm the server restores both.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["builder-sessions"].waitForExistence(timeout: 15))
        app.buttons["builder-sessions"].tap()
        XCTAssertTrue(sessionRow(app, named: "Frog Field Guide").waitForExistence(timeout: 10))
        XCTAssertTrue(sessionRow(app, named: "Bird Field Guide").waitForExistence(timeout: 10))
        let restoredSessions = XCTAttachment(screenshot: app.screenshot())
        restoredSessions.name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad restored builder sessions" : "iPhone restored builder sessions"
        restoredSessions.lifetime = .keepAlways
        add(restoredSessions)
        sessionRow(app, named: "Bird Field Guide").tap()

        let birdDraft = "Add a migration map"
        let birdComposer = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        birdComposer.tap()
        birdComposer.typeText(birdDraft)
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Frog Field Guide").tap()
        let frogDraft = "Add a pond habitat map"
        let frogComposer = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        frogComposer.tap()
        frogComposer.typeText(frogDraft)
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Bird Field Guide").tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch.value as? String, birdDraft)
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Frog Field Guide").tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch.value as? String, frogDraft)

        // Closing a disposable draft prompts before discarding it and leaves
        // both saved builds in the session list.
        app.buttons["builder-new-website"].tap()
        let discardedPrompt = app.descendants(matching: .any).matching(identifier: "builder-prompt").firstMatch
        discardedPrompt.tap()
        discardedPrompt.typeText("Temporary unsaved draft")
        app.buttons["builder-sessions"].tap()
        let closeDraft = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "close-session-"))
            .matching(NSPredicate(format: "label CONTAINS %@", "Temporary unsaved draft")).firstMatch
        XCTAssertTrue(closeDraft.waitForExistence(timeout: 5))
        closeDraft.tap()
        XCTAssertTrue(app.buttons["Close Session"].waitForExistence(timeout: 5))
        app.buttons["Close Session"].tap()
        XCTAssertTrue(sessionRow(app, named: "Frog Field Guide").exists)
        XCTAssertTrue(sessionRow(app, named: "Bird Field Guide").exists)

        // Completion updates Frog's row while Bird remains selected.
        sessionRow(app, named: "Bird Field Guide").tap()
        app.buttons["builder-sessions"].tap()
        let completedFrog = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-"))
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Frog Field Guide", "Preview ready")).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Preview ready"), object: completedFrog)], timeout: 70), .completed)
        XCTAssertTrue(sessionRow(app, named: "Bird Field Guide").isSelected)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Bird Field Guide"].exists)

        // Keep the embedded website's interaction state when switching away
        // from and back to its session.
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Frog Field Guide").tap()
        if app.segmentedControls["builder-panels"].exists {
            app.segmentedControls["builder-panels"].buttons["Preview"].tap()
        }
        XCTAssertTrue(app.webViews.staticTexts["Frog Field Guide"].waitForExistence(timeout: 15))
        app.webViews.buttons["Meet the frogs"].tap()
        XCTAssertTrue(app.webViews.buttons["Spring peeper, tree frog, bullfrog"].waitForExistence(timeout: 5))
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Bird Field Guide").tap()
        app.buttons["builder-sessions"].tap()
        sessionRow(app, named: "Frog Field Guide").tap()
        if app.segmentedControls["builder-panels"].exists {
            app.segmentedControls["builder-panels"].buttons["Preview"].tap()
        }
        XCTAssertTrue(app.webViews.buttons["Spring peeper, tree frog, bullfrog"].waitForExistence(timeout: 5))
    }

    private func sessionRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-"))
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    func testProductionWorkflow() throws {
        try XCTSkipIf(true, "Workspace UI and sharing are temporarily hidden. Use the builder fixture for iOS UI checks.")
        guard let key = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_KEY"] else {
            throw XCTSkip("Run scripts/ProductionSmoke.swift with --ui to check the real production workflow.")
        }
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launch()
        openSignIn(app)
        XCTAssertTrue(app.buttons["Use an API key"].waitForExistence(timeout: 10))
        app.buttons["Use an API key"].tap()
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
        XCTAssertFalse(app.staticTexts["Sign in to Mainbrella, then share again."].exists,
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
        try XCTSkipIf(true, "Workspace UI is temporarily hidden. Handoff transport is covered by unit tests.")
        guard let key = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_KEY"],
              let workspaceID = ProcessInfo.processInfo.environment["MAINBRELLA_UI_TEST_WORKSPACE_ID"] else {
            throw XCTSkip("Explicit production credentials and a test-owned workspace are required.")
        }
        let app = XCUIApplication(); app.launch()
        openSignIn(app)
        XCTAssertTrue(app.buttons["Use an API key"].waitForExistence(timeout: 10))
        app.buttons["Use an API key"].tap()
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
        if app.buttons["welcome-get-started"].waitForExistence(timeout: 3) { return }
        if app.buttons["google-sign-in"].exists && !app.tabBars.firstMatch.exists && !app.buttons["Account"].exists { return }
        if app.tabBars.buttons["Account"].waitForExistence(timeout: 5) { app.tabBars.buttons["Account"].tap() }
        else { app.buttons["Account"].tap() }
        XCTAssertTrue(app.buttons["Remove saved key"].waitForExistence(timeout: 10))
        app.buttons["Remove saved key"].tap()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["welcome-headline"].exists)
        XCTAssertFalse(app.textFields["login-email"].exists)
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

    private func openSignIn(_ app: XCUIApplication) {
        let start = app.buttons["welcome-get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 10),
                      "Run account-gate tests on a simulator without a saved account.")
        start.tap()
    }

    func testWelcomeToSignInAndBack() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["welcome-headline"].exists)
        XCTAssertFalse(app.textFields["login-email"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let welcome = XCTAttachment(screenshot: app.screenshot())
        welcome.name = "Fresh-install welcome"
        welcome.lifetime = .keepAlways
        add(welcome)
        app.buttons["welcome-get-started"].tap()
        XCTAssertTrue(app.buttons["google-sign-in"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Welcome"].tap()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Your websites and conversations stay saved to your account."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcome-get-started"].isHittable)
    }

    func testWelcomeWithLargeText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["welcome-get-started"].isHittable)
        XCTAssertTrue(app.staticTexts["welcome-headline"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Welcome with accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["welcome-get-started"].tap()
        XCTAssertTrue(app.navigationBars["Sign in to Mainbrella"].waitForExistence(timeout: 5))
    }

    func testDisconnectedAccountGate() throws {
        let app = XCUIApplication()
        app.launch()
        openSignIn(app)
        XCTAssertTrue(app.navigationBars["Sign in to Mainbrella"].waitForExistence(timeout: 10),
                      "Run account-gate tests on a simulator without a saved account.")
        XCTAssertTrue(app.buttons["google-sign-in"].isHittable)
        XCTAssertTrue(app.textFields["login-email"].exists)
        XCTAssertTrue(app.secureTextFields["login-password"].exists)
        XCTAssertFalse(app.secureTextFields["API key"].exists)
        XCTAssertFalse(app.buttons["Use an API key"].exists)
        XCTAssertFalse(app.buttons["email-sign-in"].isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Open preview"].exists)
        app.textFields["login-email"].tap()
        app.textFields["login-email"].typeText("person@example.com")
        XCTAssertFalse(app.buttons["email-sign-in"].isEnabled)
        app.secureTextFields["login-password"].tap()
        app.secureTextFields["login-password"].typeText("password123")
        XCTAssertTrue(app.buttons["email-sign-in"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testWorkspaceConnectionIsHidden() throws {
        let app = XCUIApplication()
        app.launch()
        openSignIn(app)
        XCTAssertTrue(app.buttons["google-sign-in"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Use an API key"].exists)
        XCTAssertFalse(app.secureTextFields["API key"].exists)
        XCTAssertFalse(app.buttons["Connect"].exists)
    }

    func testGoogleSignInPresentationAndCancellation() throws {
        let app = XCUIApplication()
        app.launch()
        openSignIn(app)
        XCTAssertTrue(app.buttons["google-sign-in"].waitForExistence(timeout: 10))
        app.buttons["google-sign-in"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = system.alerts.buttons["Continue"]
        if consent.waitForExistence(timeout: 5) { consent.tap() }
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Google sign-in should present the system authentication sheet")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Sign in to Mainbrella"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["google-sign-in"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["authentication-error"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testTabletAccountGateRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet layout check") }
        let app = XCUIApplication()
        app.launch()
        openSignIn(app)
        XCTAssertTrue(app.navigationBars["Sign in to Mainbrella"].waitForExistence(timeout: 10),
                      "Run account-gate tests on a simulator without a saved account.")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["google-sign-in"].isHittable)
            XCTAssertTrue(app.textFields["login-email"].isHittable)
            XCTAssertTrue(app.secureTextFields["login-password"].isHittable)
            XCTAssertTrue(app.buttons["email-sign-in"].isHittable)
        }
    }

    func testTabletWelcomeRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet layout check") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["welcome-get-started"].waitForExistence(timeout: 10))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let layout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed)
            XCTAssertTrue(app.staticTexts["welcome-headline"].isHittable)
            XCTAssertTrue(app.buttons["welcome-get-started"].isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "iPad welcome \(orientation == .portrait ? "portrait" : "landscape")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
