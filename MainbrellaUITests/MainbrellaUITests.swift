import XCTest

final class MainbrellaUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

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
