import XCTest

final class ReaderInteractionUITests: XCTestCase {
    @MainActor
    func testSystemCurlCommitsCompletedGesturesAndKeepsPageAfterCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["-snowlit-probe-reader-interaction"]
        app.launch()
        let status = app.staticTexts["probe.reader-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        expect(status, containing: "laidOut=true")
        let surface = app.otherElements["probe.curl-surface"]
        XCTAssertTrue(surface.exists)
        let right = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
        let left = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.7))
        let short = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.7))
        for repetition in 1...3 {
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.1)
            expect(status, containing: "completed=\(repetition * 2 - 1);")
            XCTAssertTrue(status.label.contains("page=1;visible=gesture-page-2;"), status.label)
            XCTAssertTrue(status.label.contains("active=false"), status.label)

            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.1)
            expect(status, containing: "completed=\(repetition * 2);")
            XCTAssertTrue(status.label.contains("page=0;visible=gesture-page-1;"), status.label)

            // A short slow drag releases before crossing the page. The delegate
            // must report an actual cancelled transition; a no-op is not a pass.
            right.press(forDuration: 0.05, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.5)
            expect(status, containing: "cancelled=\(repetition);")
            XCTAssertTrue(status.label.contains("page=0;visible=gesture-page-1;"), status.label)
            XCTAssertTrue(status.label.contains("completed=\(repetition * 2);"), status.label)
            XCTAssertTrue(status.label.contains("began=\(repetition * 3);"), status.label)
            XCTAssertTrue(status.label.contains("active=false"), status.label)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "System curl after cancellation \(repetition)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func expect(_ element: XCUIElement, containing text: String) {
        let condition = NSPredicate(format: "label CONTAINS %@", text)
        let observed = XCTNSPredicateExpectation(predicate: condition, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 8), .completed,
                       "Missing \(text); observed \(element.label)")
    }
}
