import CoreGraphics
import XCTest
@testable import ToggleMouse

final class ScreenLayoutTests: XCTestCase {
    /// Main 1440×900 display with a 1920×1080 display to its right, tops aligned.
    private let layout = ScreenLayout(displays: [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    ])

    func testOuterEdgesIgnoreEdgesSharedWithAnotherDisplay() {
        XCTAssertTrue(layout.isAtOuterEdge(CGPoint(x: 0, y: 400), .left))
        XCTAssertFalse(layout.isAtOuterEdge(CGPoint(x: 1439, y: 400), .right), "second display continues here")
        XCTAssertTrue(layout.isAtOuterEdge(CGPoint(x: 3359, y: 400), .right))
        XCTAssertTrue(layout.isAtOuterEdge(CGPoint(x: 700, y: 899), .bottom))
        XCTAssertFalse(layout.isAtOuterEdge(CGPoint(x: 700, y: 400), .bottom))
        XCTAssertFalse(layout.isAtOuterEdge(CGPoint(x: 5, y: 400), .left))
    }

    func testFractionAndEntryPointMatchAcrossLayouts() {
        let position = layout.fraction(of: CGPoint(x: 3359, y: 270), along: .right)
        XCTAssertEqual(position, 0.25, accuracy: 0.001)

        let receiver = ScreenLayout(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1600)])
        let entry = receiver.entryPoint(on: .left, fraction: position)!
        XCTAssertEqual(entry.x, 2)
        XCTAssertEqual(entry.y, 400)
        XCTAssertFalse(receiver.isAtOuterEdge(entry, .left), "entry must not be pushing the edge already")
    }

    func testEntryPointOnSpanOfOutermostDisplays() {
        // The right edge is only the second display's; land on it, scaled to its height.
        let entry = layout.entryPoint(on: .right, fraction: 1)!
        XCTAssertEqual(entry.x, 3357)
        XCTAssertEqual(entry.y, 1079)
        XCTAssertNotNil(layout.display(containing: entry))
    }

    func testClampKeepsCursorOnScreen() {
        // Below the shorter main display: stays on it rather than falling into the gap.
        let clamped = layout.clamp(CGPoint(x: 700, y: 950), from: CGPoint(x: 700, y: 890))
        XCTAssertEqual(clamped, CGPoint(x: 700, y: 899))
    }
}

final class EdgePushTests: XCTestCase {
    func testNeedsSustainedOutwardPush() {
        var push = EdgePush()
        XCTAssertFalse(push.push(against: .right, dx: 10, dy: 0, now: 0))
        XCTAssertFalse(push.push(against: .right, dx: 10, dy: 0, now: 0.05))
        XCTAssertTrue(push.push(against: .right, dx: 10, dy: 0, now: 0.1))
        // Resets after switching.
        XCTAssertFalse(push.push(against: .right, dx: 10, dy: 0, now: 0.15))
    }

    func testResetsOnRetreatPauseOrLeavingEdge() {
        var push = EdgePush()
        XCTAssertFalse(push.push(against: .left, dx: -20, dy: 0, now: 0))
        XCTAssertFalse(push.push(against: .left, dx: 5, dy: 0, now: 0.01))
        XCTAssertFalse(push.push(against: .left, dx: -20, dy: 0, now: 0.02))
        XCTAssertFalse(push.push(against: .left, dx: -20, dy: 0, now: 1), "pause resets")
        XCTAssertFalse(push.push(against: nil, dx: -20, dy: 0, now: 1.01))
        XCTAssertFalse(push.push(against: .left, dx: -20, dy: 0, now: 1.02))
        XCTAssertTrue(push.push(against: .left, dx: -20, dy: 0, now: 1.03))
    }
}
