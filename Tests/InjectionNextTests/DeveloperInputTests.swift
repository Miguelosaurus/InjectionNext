import XCTest
@testable import InjectionBundle

final class DeveloperInputTests: XCTestCase {
    func testOnlyBoundedWellFormedInputIsAccepted() {
        XCTAssertTrue(DeveloperInput.valid(tool: "tap", value: "120,340.5"))
        XCTAssertTrue(DeveloperInput.valid(tool: "longpress", value: "120,340.5"))
        XCTAssertTrue(InjectionNext.validDeveloperTool("longpress", value: "1,2"))
        XCTAssertTrue(DeveloperInput.valid(tool: "swipe", value: "200,600,200,200"))
        XCTAssertTrue(DeveloperInput.valid(tool: "type", value: "hello"))
        for value in [nil, "", "120", "120,", "a,b", "-1,5", "1,2,3", "inf,2", "30000,1"] {
            XCTAssertFalse(DeveloperInput.valid(tool: "tap", value: value), String(describing: value))
            XCTAssertFalse(DeveloperInput.valid(tool: "longpress", value: value), String(describing: value))
        }
        XCTAssertFalse(DeveloperInput.valid(tool: "swipe", value: "1,2,3"))
        XCTAssertFalse(DeveloperInput.valid(tool: "type", value: ""))
        XCTAssertFalse(DeveloperInput.valid(tool: "type", value: String(repeating: "x", count: 513)))
        XCTAssertFalse(DeveloperInput.valid(tool: "drag", value: "1,2"))
        XCTAssertTrue(InjectionNext.validDeveloperTool("tap", value: "1,2"))
        XCTAssertFalse(InjectionNext.validDeveloperTool("tap", value: "1"))
    }

    func testSettlingRequiresConsecutiveQuietPollsAndHasDeadline() {
        var state = DeveloperInput.SettleState()
        XCTAssertFalse(state.shouldComplete(elapsed: 0, quiet: true))
        XCTAssertFalse(state.shouldComplete(elapsed: 0.05, quiet: true))
        XCTAssertFalse(state.shouldComplete(elapsed: 0.10, quiet: false))
        XCTAssertFalse(state.shouldComplete(elapsed: 0.15, quiet: true))
        XCTAssertTrue(state.shouldComplete(elapsed: 0.20, quiet: true))
        var busy = DeveloperInput.SettleState()
        XCTAssertFalse(busy.shouldComplete(elapsed: 1.49, quiet: false))
        XCTAssertTrue(busy.shouldComplete(elapsed: 1.5, quiet: false))
    }

    func testTapAndSwipeBecomeOneContinuousTouch() throws {
        let tap = try XCTUnwrap(DeveloperInput(tool: "tap", value: "10,20")).touches
        XCTAssertEqual(tap.map(\.2), ["began", "ended"])
        XCTAssertEqual(tap.first?.1, CGPoint(x: 10, y: 20))

        let longpress = try XCTUnwrap(DeveloperInput(tool: "longpress", value: "10,20")).touches
        XCTAssertEqual(longpress.map(\.2), ["began", "ended"])
        XCTAssertEqual(longpress.map(\.0), [0, 0.8])
        XCTAssertTrue(longpress.allSatisfy { $0.1 == CGPoint(x: 10, y: 20) })

        let swipe = try XCTUnwrap(DeveloperInput(tool: "swipe", value: "100,500,100,100")).touches
        XCTAssertEqual(swipe.first?.2, "began")
        XCTAssertEqual(swipe.last?.2, "ended")
        XCTAssertEqual(swipe.last?.1, CGPoint(x: 100, y: 100))
        XCTAssertTrue(swipe.dropFirst().dropLast().allSatisfy { $0.2 == "moved" })
        XCTAssertEqual(swipe.map(\.0), swipe.map(\.0).sorted(), "phases are delivered in time order")
        XCTAssertTrue(try XCTUnwrap(DeveloperInput(tool: "type", value: "x")).touches.isEmpty)
    }
}
