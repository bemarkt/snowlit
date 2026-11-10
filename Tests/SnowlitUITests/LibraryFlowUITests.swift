import XCTest

final class LibraryFlowUITests: XCTestCase {
    @MainActor
    func testAdoptSearchAllCatalogPagesAddAndReopenFromTheShelf() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-snowlit-test-library-flow", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        let source = app.staticTexts["Reading fixture"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let prepare = app.buttons["sources.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()
        let confirm = app.buttons["sources.confirm-adoption"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        if !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(app.buttons["sources.toggle-enabled"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["sources.management.failure"].exists)

        app.tabBars.buttons["搜索"].tap()
        let query = app.searchFields.firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("fixture\n")
        let firstResult = app.buttons.matching(identifier: "search.result")
            .matching(NSPredicate(format: "label == %@", "Another Novel")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15))
        let more = app.buttons["search.more"]
        XCTAssertTrue(more.isHittable)
        more.tap()
        let result = app.staticTexts["Fixture Novel"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        result.tap()
        XCTAssertTrue(app.staticTexts["book.chapter.1"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["book.chapter.0"].label, "Chapter One")
        XCTAssertEqual(app.staticTexts["book.chapter.1"].label, "Chapter Two")
        let add = app.buttons["book.add"]
        XCTAssertTrue(add.isEnabled && add.isHittable)
        add.tap()
        let saved = NSPredicate(format: "label == %@ AND enabled == false", "已在书架")
        expectation(for: saved, evaluatedWith: add)
        waitForExpectations(timeout: 10)
        attachScreenshot("Complete catalog added")

        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["library.book"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "library.book").count, 1)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["startup.ready"].waitForExistence(timeout: 10))
        let retained = app.buttons["library.book"]
        XCTAssertTrue(retained.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "library.book").count, 1)
        retained.tap()
        XCTAssertTrue(app.buttons["library.chapter.1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["library.chapter.0"].label, "Chapter One")
        XCTAssertEqual(app.buttons["library.chapter.1"].label, "Chapter Two")
        XCTAssertEqual(app.staticTexts["library.book.title"].label, "Fixture Novel")
        attachScreenshot("Reopened local catalog")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
