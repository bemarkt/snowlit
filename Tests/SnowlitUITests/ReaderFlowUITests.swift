import XCTest

final class ReaderFlowUITests: XCTestCase {
    @MainActor
    func testChapterNavigationSettingsAndCachedResumeAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-snowlit-test-reader-flow", UUID().uuidString]
        app.launch()
        let book = app.buttons["library.book"]
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        app.buttons["library.chapter.0"].tap()
        let text = app.textViews["reader.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        text.swipeUp()
        app.buttons["reader.next"].tap()
        let title = app.staticTexts["reader.current-chapter"]
        let second = NSPredicate(format: "label == %@", "Chapter Two")
        expectation(for: second, evaluatedWith: title)
        waitForExpectations(timeout: 15)
        app.buttons["reader.settings"].tap()
        app.buttons["reader.font.increase"].tap()
        app.switches["reader.offline"].tap()
        app.buttons["完成"].tap()
        text.swipeUp()
        attachScreenshot("Second chapter with larger text")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["library.resume"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        app.buttons["library.resume"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Chapter Two")
        XCTAssertFalse(app.otherElements["reader.failure"].exists)
        attachScreenshot("Resumed persisted text")
        app.terminate()
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        value.name = name; value.lifetime = .keepAlways; add(value)
    }
}
