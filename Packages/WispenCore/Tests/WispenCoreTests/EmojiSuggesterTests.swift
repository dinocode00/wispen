import XCTest
@testable import WispenCore

final class EmojiSuggesterTests: XCTestCase {
    let s = EmojiSuggester.shared

    func testCommonWordsGetTheExpectedEmoji() {
        XCTAssertGreaterThan(s.count, 3000)
        XCTAssertEqual(s.emoji(for: "cool").first, "😎")
        XCTAssertEqual(s.emoji(for: "Pizza").first, "🍕")
        XCTAssertEqual(s.emoji(for: "love").first, "❤️")
        XCTAssertEqual(s.emoji(for: "beer").first, "🍺")
        XCTAssertEqual(s.emoji(for: "france").first, "🇫🇷")
        XCTAssertEqual(s.emoji(for: "unicorn").first, "🦄")
        XCTAssertEqual(s.emoji(for: "cool", limit: 3), ["😎", "🆒", "🤙"])
    }

    func testPluralsAndPossessives() {
        XCTAssertEqual(s.emoji(for: "dogs").first, "🐶")
        XCTAssertEqual(s.emoji(for: "parties").first, s.emoji(for: "party").first)
        XCTAssertEqual(s.emoji(for: "dog’s").first, "🐶")
    }

    func testEverydayWordsStayQuiet() {
        for w in ["the", "and", "a", "it", "of", "with", "was", "zxqv", "x"] {
            XCTAssertEqual(s.emoji(for: w), [], w)
        }
    }

    func testEveryEmojiIsInTheCatalog() {
        let catalog = Set(EmojiCatalog.shared.groups.flatMap(\.emoji).map(\.character))
        let text = try! String(contentsOf: Bundle.module.url(forResource: "emoji_words", withExtension: "txt")!, encoding: .utf8)
        for line in text.split(separator: "\n") {
            for e in line.split(separator: "\t")[1].split(separator: " ") { XCTAssertTrue(catalog.contains(String(e)), "\(line)") }
        }
    }

    func testShortcutMatch() {
        let snippets = [Snippet(trigger: "my address", expansion: "123 Main St", shortcut: "123m"),
                        Snippet(trigger: "my email", expansion: "rex@example.com"),
                        Snippet(trigger: "", expansion: "Thanks!", shortcut: " tx ")]
        XCTAssertEqual(TextShortcuts.match(before: "Ship to 123M", in: snippets)?.expansion, "123 Main St")
        XCTAssertEqual(TextShortcuts.match(before: "ok\ntx", in: snippets)?.expansion, "Thanks!")
        XCTAssertNil(TextShortcuts.match(before: "Ship to 123m ", in: snippets), "only right after the shortcut")
        XCTAssertNil(TextShortcuts.match(before: "x123m", in: snippets))
        XCTAssertNil(TextShortcuts.match(before: "my email", in: snippets), "spoken triggers aren't typed shortcuts")
        XCTAssertNil(TextShortcuts.match(before: nil, in: snippets))
    }

    func testSnippetsSavedBeforeShortcutsStillLoad() throws {
        let old = #"[{"id":"1","trigger":"my email","expansion":"a@b.c"}]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([Snippet].self, from: old)
        XCTAssertNil(decoded[0].typedShortcut)
    }

    func testMergeKeepsKeyboardOnlySnippetsApart() {
        var a = LibraryBundle(snippets: [Snippet(id: "1", trigger: "", expansion: "A", shortcut: "aa")])
        a.merge(LibraryBundle(snippets: [Snippet(id: "2", trigger: "", expansion: "B", shortcut: "bb")]))
        XCTAssertEqual(a.snippets.count, 2)
    }
}
