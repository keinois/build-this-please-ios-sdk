import XCTest

final class BuildThisPleaseExampleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testThreeSectionsAndImplementedPrivacy() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        let featureRequests = app.buttons["Feature requests"]
        XCTAssertTrue(featureRequests.waitForExistence(timeout: 5))
        featureRequests.tap()
        let requests = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Requests'")).firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 5))
        let implemented = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Implemented'")).firstMatch
        XCTAssertTrue(implemented.waitForExistence(timeout: 2))
        implemented.tap()
        XCTAssertTrue(app.staticTexts["Implemented release notes"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'votes'")).firstMatch.exists)
    }
    func testCompletionInboxAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        let feedback = app.buttons["Feature requests"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        feedback.tap()
        let updates = app.buttons["Updates"].firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        updates.tap()
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Implemented release notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Email me when requests ship"].exists)
        XCTAssertTrue(app.switches["Local notifications"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Completion inbox and preferences"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
