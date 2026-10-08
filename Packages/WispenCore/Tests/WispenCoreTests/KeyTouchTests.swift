import Foundation
import XCTest
@testable import WispenCore

final class KeyTouchTests: XCTestCase {
    /// Types whatever the tracker says to type, in order.
    private struct Typist {
        var tracker = KeyTouchTracker<Int, String>()
        var typed = ""
        mutating func down(_ t: Int, _ k: String, rollsOver: Bool = true) {
            typed += tracker.begin(t, key: k, rollsOver: rollsOver).joined()
        }
        mutating func up(_ t: Int) { typed += tracker.end(t) ?? "" }
    }

    func testSlowTypingTypesOnRelease() {
        var k = Typist()
        k.down(1, "h"); XCTAssertEqual(k.typed, "")
        k.up(1); XCTAssertEqual(k.typed, "h")
        k.down(2, "i"); k.up(2)
        XCTAssertEqual(k.typed, "hi")
    }

    func testOverlappingFingersKeepEveryLetterInOrder() {
        var k = Typist()
        // "the": t down, h down before t lifts, e down before h lifts, then lifts in any order.
        k.down(1, "t"); k.down(2, "h"); k.down(3, "e")
        k.up(1); k.up(3); k.up(2)
        XCTAssertEqual(k.typed, "the")
        XCTAssertTrue(k.tracker.isEmpty)
    }

    func testLiftOrderDoesNotReorderLetters() {
        var k = Typist()
        k.down(1, "a"); k.down(2, "b")
        k.up(2); k.up(1)
        XCTAssertEqual(k.typed, "ab")
    }

    func testCancelledTouchStillTypes() {
        var k = Typist()
        k.down(1, "x")
        k.up(1) // the view reports cancellations the same way
        XCTAssertEqual(k.typed, "x")
        k.up(1) // a second end for the same touch types nothing
        XCTAssertEqual(k.typed, "x")
    }

    func testModifiersAreNotTypedByRollover() {
        var k = Typist()
        k.down(1, "⇧", rollsOver: false)
        k.down(2, "a")
        XCTAssertEqual(k.typed, "")
        k.up(2); XCTAssertEqual(k.typed, "a")
        k.up(1); XCTAssertEqual(k.typed, "a⇧")
    }

    func testSuppressedTouchIsNeverTyped() {
        var k = Typist()
        k.down(1, " ")
        k.tracker.suppress(1)
        k.down(2, "a")
        k.up(1); k.up(2)
        XCTAssertEqual(k.typed, "a")
    }

    func testHitTestPicksContainingThenNearestKey() {
        let frames = [CGRect(x: 0, y: 0, width: 30, height: 40), CGRect(x: 40, y: 0, width: 30, height: 40)]
        XCTAssertEqual(KeyHitTest.index(of: CGPoint(x: 10, y: 10), in: frames), 0)
        XCTAssertEqual(KeyHitTest.index(of: CGPoint(x: 50, y: 39), in: frames), 1)
        // In the gap, closer to the second key.
        XCTAssertEqual(KeyHitTest.index(of: CGPoint(x: 37, y: 20), in: frames), 1)
        // Just below the keys.
        XCTAssertEqual(KeyHitTest.index(of: CGPoint(x: 15, y: 50), in: frames), 0)
        // Far away: nothing.
        XCTAssertNil(KeyHitTest.index(of: CGPoint(x: 300, y: 300), in: frames))
    }
}
