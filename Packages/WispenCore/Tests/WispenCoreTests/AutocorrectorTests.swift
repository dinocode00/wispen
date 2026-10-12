import XCTest
@testable import WispenCore

final class AutocorrectorTests: XCTestCase {
    private let balanced = Autocorrector(strength: .balanced)

    func testWordListLoads() {
        XCTAssertGreaterThan(WordList.english.count, 20000)
        XCTAssertEqual(WordList.english.rank(of: "you"), 0)
        XCTAssertNil(WordList.english.rank(of: "dont"), "apostrophe-less contractions are removed")
    }

    func testFastTypingSlips() {
        let cases: [(String, String)] = [
            ("tge", "the"), ("thw", "the"), ("teh", "the"), ("hwllo", "hello"),
            ("wprk", "work"), ("becuase", "because"), ("beacuse", "because"), ("realy", "really"),
            ("tommorow", "tomorrow"), ("goign", "going"), ("abd", "and"), ("jsut", "just"),
            ("knwo", "know"), ("somethign", "something"), ("probaly", "probably"), ("thnak", "thank"),
            ("meeitng", "meeting"), ("wiht", "with"), ("yuo", "you"), ("whst", "what"),
            ("fo", "of"), ("si", "is"), ("waht", "what"), ("frist", "first"), ("peopel", "people"),
            ("agian", "again"), ("thign", "thing"), ("cna", "can"), ("lnow", "know"),
        ]
        var failures: [String] = []
        for (typed, expected) in cases {
            let got = balanced.correction(for: typed)
            if got != expected { failures.append("\(typed) → \(got ?? "nil") (want \(expected))") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
    }

    func testRealWordsAreLeftAlone() {
        for w in ["the", "ok", "lol", "gonna", "yeah", "hey", "cool", "text", "an", "as", "at", "it's", "Wispen"] {
            XCTAssertNil(balanced.correction(for: w, protected: ["wispen"]), w)
        }
        XCTAssertNil(balanced.correction(for: "kubernetes", systemKnows: true))
    }

    func testContractionsAndCapitalI() {
        XCTAssertEqual(balanced.correction(for: "dont"), "don't")
        XCTAssertEqual(balanced.correction(for: "Dont"), "Don't")
        XCTAssertEqual(balanced.correction(for: "im"), "I'm")
        XCTAssertEqual(balanced.correction(for: "i"), "I")
        XCTAssertEqual(balanced.correction(for: "youre"), "you're")
        XCTAssertEqual(balanced.correction(for: "cant"), "can't")
        XCTAssertNil(Autocorrector(strength: .gentle).correction(for: "cant"), "cant is a word; Gentle leaves it")
        XCTAssertNil(balanced.correction(for: "I"))
    }

    func testMissingSpace() {
        XCTAssertEqual(balanced.correction(for: "thisis"), "this is")
        XCTAssertEqual(balanced.correction(for: "iam"), "I am")
        XCTAssertNotEqual(Autocorrector(strength: .gentle).correction(for: "thisis"), "this is")
    }

    func testCasingIsKept() {
        XCTAssertEqual(balanced.correction(for: "Tge"), "The")
        XCTAssertNil(balanced.correction(for: "NASA"))
        XCTAssertNil(balanced.correction(for: "TGE"), "all caps is left alone")
    }

    func testOffAndProtected() {
        XCTAssertNil(Autocorrector(strength: .off).correction(for: "tge"))
        XCTAssertNil(balanced.correction(for: "siobhan", protected: ["siobhan"]))
        XCTAssertNil(balanced.correction(for: "abc123"))
    }

    func testStrengthsAreOrdered() {
        // Gentle skips short words; Strong reaches further.
        XCTAssertNil(Autocorrector(strength: .gentle).correction(for: "tge"))
        XCTAssertEqual(Autocorrector(strength: .strong).correction(for: "tge"), "the")
        XCTAssertEqual(Autocorrector(strength: .gentle).correction(for: "becuase"), "because")
        // Ambiguous ("of"? "to"?): Balanced leaves it, Strong takes the best guess.
        XCTAssertNil(balanced.correction(for: "ot"))
        XCTAssertNotNil(Autocorrector(strength: .strong).correction(for: "ot"))
    }

    func testCostPrefersNeighbouringKeys() {
        let typed = KeyGeometry.codes("tge")
        XCTAssertLessThan(Autocorrector.cost(typed: typed, candidate: KeyGeometry.codes("the")),
                          Autocorrector.cost(typed: typed, candidate: KeyGeometry.codes("toe")))
    }

    func testSpeed() {
        _ = WordList.english.count
        let start = Date()
        for w in ["tge", "becuase", "somethign", "meeitng", "thisis", "probaly", "abd", "wprk", "tommorow", "jsut"] {
            _ = balanced.correction(for: w)
        }
        // Runs on every keystroke for the suggestion bar; generous bound for unoptimised test builds.
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
