import XCTest

final class MainbrellaUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }
    func testTabletRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet layout check") }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your agents need you."].waitForExistence(timeout: 10))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Tablet \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertTrue(app.buttons["Approve"].firstMatch.isHittable)
        }
    }
    func testPreviewFeedbackLoop() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your agents need you."].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Needs Me"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Open preview"].firstMatch.tap()
        let capture = app.buttons["Screenshot & annotate"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: capture)
        waitForExpectations(timeout: 20)
        capture.tap()
        let input = app.textFields["Instruction for the agent"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let canvas = app.descendants(matching: .any)["annotationCanvas"].firstMatch
        XCTAssertTrue(canvas.exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        let annotated = XCTAttachment(screenshot: app.screenshot())
        annotated.name = "Annotated preview"
        annotated.lifetime = .keepAlways
        add(annotated)
        input.tap()
        input.typeText("Reduce the space above the headline.")
        let send = app.buttons["Try sending feedback"]
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(app.staticTexts["Demo feedback captured. No files uploaded."].waitForExistence(timeout: 10))
    }
    func testDemoDenialRemovesRequest() {
        let app = XCUIApplication()
        app.launch()
        let title = app.staticTexts["Allow outbound access to api.stripe.com?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        app.buttons["Deny"].firstMatch.tap()
        XCTAssertFalse(title.exists)
    }
}
