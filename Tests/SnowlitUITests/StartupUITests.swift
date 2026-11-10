import XCTest

final class StartupUITests: XCTestCase {
    @MainActor
    func testLaunchAndRelaunchReachTheApplication() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        attachScreenshot(name: "Ready")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["startup.failed"].exists)
    }

    @MainActor
    func testStartupFailureCanBeRetriedInTheInterface() {
        let app = XCUIApplication()
        app.launchArguments = ["-snowlit-test-startup-failure"]
        app.launch()
        XCTAssertTrue(app.staticTexts["startup.failed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["startup.ready"].exists)
        attachScreenshot(name: "Failure")

        let retry = app.buttons["startup.retry"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()

        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["startup.failed"].exists)
        attachScreenshot(name: "Recovered")
    }

    @MainActor
    func testSourceFilePickerCanBeCancelledWithoutSavingAnImport() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        let importFile = app.buttons["sources.import"]
        XCTAssertTrue(importFile.waitForExistence(timeout: 10))
        XCTAssertTrue(importFile.isHittable)
        importFile.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        attachScreenshot(name: "Source file picker")
        cancel.tap()
        XCTAssertTrue(importFile.waitForExistence(timeout: 10))
        XCTAssertTrue(importFile.isHittable)
        XCTAssertFalse(app.buttons["sources.save"].exists)
        attachScreenshot(name: "Source library after cancelling import")
    }

    @MainActor
    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
