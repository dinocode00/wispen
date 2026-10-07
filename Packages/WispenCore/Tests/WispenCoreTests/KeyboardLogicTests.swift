import XCTest
@testable import WispenCore

final class KeyboardLogicTests: XCTestCase {
    typealias K = KeyboardTextLogic

    func testCurrentWord() {
        XCTAssertEqual(K.currentWord(before: "say hel"), "hel")
        XCTAssertEqual(K.currentWord(before: "it's don't"), "don't")
        XCTAssertEqual(K.currentWord(before: "hi "), "")
        XCTAssertEqual(K.currentWord(before: "'quo"), "quo")
        XCTAssertEqual(K.currentWord(before: nil), "")
    }

    func testAutoCapitalization() {
        XCTAssertTrue(K.shouldCapitalize(before: "", mode: .sentences))
        XCTAssertTrue(K.shouldCapitalize(before: nil, mode: .sentences))
        XCTAssertTrue(K.shouldCapitalize(before: "Hi there. ", mode: .sentences))
        XCTAssertTrue(K.shouldCapitalize(before: "Done!\n", mode: .sentences))
        XCTAssertFalse(K.shouldCapitalize(before: "Hi there ", mode: .sentences))
        XCTAssertFalse(K.shouldCapitalize(before: "Hi there.", mode: .sentences))
        XCTAssertFalse(K.shouldCapitalize(before: "", mode: .none))
        XCTAssertTrue(K.shouldCapitalize(before: "john ", mode: .words))
        XCTAssertFalse(K.shouldCapitalize(before: "jo", mode: .words))
    }

    func testDoubleSpacePeriod() {
        XCTAssertTrue(K.shouldInsertDoubleSpacePeriod(before: "hello "))
        XCTAssertFalse(K.shouldInsertDoubleSpacePeriod(before: "hello. "))
        XCTAssertFalse(K.shouldInsertDoubleSpacePeriod(before: "hello  "))
        XCTAssertFalse(K.shouldInsertDoubleSpacePeriod(before: " "))
    }

    func testEditDistance() {
        XCTAssertEqual(K.editDistance("teh", "the"), 1) // transposition
        XCTAssertEqual(K.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(K.editDistance("", "abc"), 3)
    }

    func testAutocorrection() {
        XCTAssertEqual(K.autocorrection(for: "teh", guesses: ["the", "tech"], protectedTerms: []), "the")
        XCTAssertEqual(K.autocorrection(for: "Teh", guesses: ["the"], protectedTerms: []), "The")
        XCTAssertEqual(K.autocorrection(for: "recieve", guesses: ["receive"], protectedTerms: []), "receive")
        XCTAssertNil(K.autocorrection(for: "Wispen", guesses: ["Wisped"], protectedTerms: ["Wispen"]))
        XCTAssertNil(K.autocorrection(for: "NASA", guesses: ["NASAL"], protectedTerms: []))
        XCTAssertNil(K.autocorrection(for: "ok", guesses: ["oak"], protectedTerms: []))
        XCTAssertNil(K.autocorrection(for: "xyzzy", guesses: ["fuzzy"], protectedTerms: []))
        XCTAssertNil(K.autocorrection(for: "abt", guesses: ["a bt"], protectedTerms: []))
    }

    func testSuggestions() {
        let s = K.suggestions(for: "Wis", vocabulary: ["Wispen"], corrections: [], completions: ["wish", "wisdom"])
        XCTAssertEqual(s, ["Wispen", "Wish"])
        XCTAssertEqual(K.suggestions(for: "the", vocabulary: [], corrections: ["the"], completions: ["then", "there"]), ["then", "there"])
        XCTAssertEqual(K.suggestions(for: "", vocabulary: ["x"], corrections: [], completions: []), [])
    }
}
