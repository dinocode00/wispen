import XCTest
@testable import WispenCore

final class CursorNavigatorTests: XCTestCase {
    func testUpAndDownAcrossLineBreaksKeepsTheColumn() {
        // Cursor after "wor" on the last line.
        var nav = CursorNavigator(before: "first line\nab\nthe wor", after: "ld", lineWidth: 40)
        XCTAssertEqual(nav.move(lines: -1), -8) // to the end of "ab" (column 7 doesn't fit)
        XCTAssertEqual(nav.position, 13)
        XCTAssertEqual(nav.move(lines: -1), -6) // back to column 7, remembered: "first l|ine"
        XCTAssertEqual(nav.position, 7)
        XCTAssertEqual(nav.move(lines: 2), 14) // down to "the wor|ld"
        XCTAssertEqual(nav.position, 21)
    }

    func testStopsAtTheFirstAndLastLine() {
        var nav = CursorNavigator(before: "one\ntwo", after: "", lineWidth: 40)
        XCTAssertEqual(nav.move(lines: -5), -4)
        XCTAssertEqual(nav.position, 3)
        XCTAssertEqual(nav.move(lines: 1), 4)
        XCTAssertEqual(nav.move(lines: 1), 0)
    }

    func testLongParagraphsWrapAtWords() {
        let text = "the quick brown fox jumps over the lazy dog"
        let lines = CursorNavigator.layout(Array(text), width: 15)
        XCTAssertEqual(lines.map { String(Array(text)[$0]) }, ["the quick brown ", "fox jumps over ", "the lazy dog"])
        // From "the lazy| dog" up one line: "fox jump|s over".
        var nav = CursorNavigator(before: "the quick brown fox jumps over the lazy", after: " dog", lineWidth: 15)
        _ = nav.move(lines: -1)
        XCTAssertEqual(nav.position, 24)
        XCTAssertEqual(String(Array(text)[16..<nav.position]), "fox jump")
    }

    func testWrappedLineEndDoesNotSkipToTheNextLine() {
        // Column 15 on "fox jumps over " would be the start of the next line; it stops before the space.
        var nav = CursorNavigator(before: "the quick brown", after: " fox jumps over the lazy dog", lineWidth: 15)
        _ = nav.move(lines: 1)
        XCTAssertEqual(nav.position, 30)
    }

    func testSidewaysMovesAndEmojiWidth() {
        var nav = CursorNavigator(before: "hi 👋🏽", after: " there", lineWidth: 40)
        XCTAssertEqual(nav.move(characters: -1), -4, "an emoji with a skin tone is 4 UTF-16 units")
        XCTAssertEqual(nav.move(characters: -100), -3)
        XCTAssertEqual(nav.move(characters: 100), 13)
    }

    func testEmptyText() {
        var nav = CursorNavigator(before: "", after: "", lineWidth: 40)
        XCTAssertEqual(nav.move(characters: -3, lines: -2), 0)
    }
}
