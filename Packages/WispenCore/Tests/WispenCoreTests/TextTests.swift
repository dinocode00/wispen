import XCTest
@testable import WispenCore

final class TextTests: XCTestCase {
    let opts = CleanupOptions(useAI: false)

    func rules(_ s: String, style: DictationStyle = .polished, dictionary: [DictionaryEntry] = [],
               snippets: [Snippet] = [], options: CleanupOptions? = nil) -> String {
        RuleBasedCleaner.clean(s, options: options ?? opts, style: style, dictionary: dictionary, snippets: snippets)
    }

    // MARK: Fillers

    func testRemovesFillers() {
        XCTAssertEqual(rules("um so I think uh we should go"), "So I think we should go.")
        XCTAssertEqual(rules("Hmm, let me check. Uhm, yes."), "Let me check. Yes.")
    }

    func testRemovesParentheticalFillersButKeepsMeaningfulLike() {
        XCTAssertEqual(rules("it was, you know, pretty good"), "It was, pretty good.")
        XCTAssertEqual(rules("I like apples"), "I like apples.")
    }

    func testRemovesStuttersButKeepsLegitRepeats() {
        XCTAssertEqual(rules("I I think the the plan works"), "I think the plan works.")
        XCTAssertEqual(rules("I know that that is true"), "I know that that is true.")
    }

    // MARK: Self-corrections

    func testCorrectionReplacesTime() {
        XCTAssertEqual(SelfCorrectionResolver.apply("let's meet at 5pm no wait 6pm"), "let's meet at 6pm")
    }

    func testCorrectionReplacesDay() {
        XCTAssertEqual(SelfCorrectionResolver.apply("let's do Tuesday, I mean Wednesday"), "let's do Wednesday")
    }

    func testCorrectionRestartsPhrase() {
        XCTAssertEqual(SelfCorrectionResolver.apply("send it to John, no wait, send it to Mary"), "send it to Mary")
    }

    func testCorrectionAlignsOnLastWord() {
        XCTAssertEqual(SelfCorrectionResolver.apply("we need 3 copies, I mean 4 copies"), "we need 4 copies")
    }

    func testCorrectionNumberOnly() {
        XCTAssertEqual(SelfCorrectionResolver.apply("we need 3 copies, no wait, 4"), "we need 4 copies")
    }

    func testScratchThatDropsSentence() {
        XCTAssertEqual(SelfCorrectionResolver.apply("Hello team. The launch is Monday. Scratch that. See you soon."),
                       "Hello team. See you soon.")
    }

    func testCorrectionKeepsEarlierSentences() {
        XCTAssertEqual(SelfCorrectionResolver.apply("Hi Sam. Lunch at noon, no wait, 1pm. Thanks."),
                       "Hi Sam. Lunch at 1pm. Thanks.")
    }

    func testIMeanWithoutCommaIsNotACorrection() {
        XCTAssertEqual(SelfCorrectionResolver.apply("I mean it when I say thanks"), "I mean it when I say thanks")
    }

    // MARK: Lists & spoken commands

    func testOrdinalList() {
        XCTAssertEqual(rules("my goals are first ship the app second write docs and third rest"),
                       "My goals are:\n1. Ship the app\n2. Write docs\n3. Rest")
    }

    func testFirstOfAllIsNotAList() {
        XCTAssertEqual(rules("first of all thanks, second the deadline moved"),
                       "First of all thanks, second the deadline moved.")
    }

    func testNewLineAndParagraph() {
        XCTAssertEqual(rules("dear Sam new paragraph thanks for the update new line best Rex"),
                       "Dear Sam\n\nThanks for the update\nBest Rex.")
    }

    func testSpokenPunctuationOptIn() {
        var o = opts
        o.spokenPunctuation = true
        XCTAssertEqual(rules("are you coming question mark", options: o), "Are you coming?")
        XCTAssertEqual(rules("a trial period"), "A trial period.")
    }

    // MARK: Dictionary & snippets

    func testDictionaryFixesMishearingsAndCasing() {
        let d = [DictionaryEntry(term: "Wispen", soundsLike: ["why spin", "wisp in"]), DictionaryEntry(term: "iPhone")]
        XCTAssertEqual(rules("open why, spin on my iphone", dictionary: d), "Open Wispen on my iPhone.")
    }

    func testSnippetPlaceholdersRoundTrip() {
        let s = [Snippet(trigger: "my email", expansion: "rex@example.com"),
                 Snippet(trigger: "my address", expansion: "1 Main St, $5 Town")]
        let p = SnippetEngine.insertPlaceholders("send it to my email and my address", snippets: s)
        XCTAssertEqual(p.placeholders.count, 2)
        XCTAssertFalse(p.text.contains("my email"))
        XCTAssertEqual(SnippetEngine.expand(p.text, placeholders: p.placeholders), "send it to rex@example.com and 1 Main St, $5 Town")
    }

    func testSnippetExpandFailsWhenPlaceholderLost() {
        let p = SnippetEngine.Prepared(text: "x", placeholders: ["{{snippet_1}}": "y"])
        XCTAssertNil(SnippetEngine.expand("nothing here", placeholders: p.placeholders))
        XCTAssertEqual(SnippetEngine.expand("ok {{ snippet_1 }}", placeholders: p.placeholders), "ok y")
    }

    // MARK: Styles & artifacts

    func testTextingStyle() {
        XCTAssertEqual(rules("Sounds good. I'll be there at 6.", style: .texting), "sounds good. I'll be there at 6")
    }

    func testTextingKeepsAcronymsAndTerms() {
        let d = [DictionaryEntry(term: "Wispen")]
        XCTAssertEqual(StyleFormatter.apply("Wispen works. NASA too. Cool.", style: .texting, protectedTerms: d.map(\.term)),
                       "Wispen works. NASA too. cool")
    }

    func testWhisperArtifacts() {
        XCTAssertEqual(WhisperArtifactFilter.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperArtifactFilter.clean(" Thanks for watching!"), "")
        XCTAssertEqual(WhisperArtifactFilter.clean("(music) Hello there [Music]"), "Hello there")
        XCTAssertEqual(WhisperArtifactFilter.clean("<|startoftranscript|> Hi"), "Hi")
    }

    func testCapitalization() {
        XCTAssertEqual(TextTidy.capitalizeSentences("hello. i'm here! version 3.5 is out"),
                       "Hello. I'm here! Version 3.5 is out")
    }

    func testOutputSanitizer() {
        XCTAssertEqual(OutputSanitizer.clean("Sure! Here's the cleaned text:\n\"Hello there.\""), "Hello there.")
        XCTAssertEqual(OutputSanitizer.clean("<transcript>Hi.</transcript>"), "Hi.")
        XCTAssertEqual(OutputSanitizer.clean("Here is the polished version: Done."), "Done.")
    }

    func testRewriteGuard() {
        XCTAssertTrue(RewriteGuard.isFaithfulCleanup(input: "um what is the weather like today", output: "What is the weather like today?"))
        XCTAssertFalse(RewriteGuard.isFaithfulCleanup(input: "what is the weather like today",
                                                      output: "I'm sorry, I can't check the weather."))
        XCTAssertFalse(RewriteGuard.isFaithfulCleanup(
            input: "write me a poem",
            output: "Roses are red, violets are blue, here is a long poem that goes on and on and on forever and ever"))
    }
}

final class InsertionTests: XCTestCase {
    func testInsertAfterWordAddsSpaceAndLowercases() {
        XCTAssertEqual(InsertionFormatter.prepare("Tomorrow works.", before: "Let's talk"), " tomorrow works.")
    }

    func testInsertAfterSentenceKeepsCapital() {
        XCTAssertEqual(InsertionFormatter.prepare("Tomorrow works.", before: "Hi Sam."), " Tomorrow works.")
        XCTAssertEqual(InsertionFormatter.prepare("Tomorrow works.", before: "Hi Sam. "), "Tomorrow works.")
        XCTAssertEqual(InsertionFormatter.prepare("Tomorrow works.", before: ""), "Tomorrow works.")
    }

    func testKeepsIAndAcronyms() {
        XCTAssertEqual(InsertionFormatter.prepare("I agree.", before: "well,"), " I agree.")
        XCTAssertEqual(InsertionFormatter.prepare("NASA called.", before: "and"), " NASA called.")
        XCTAssertEqual(InsertionFormatter.prepare("Wispen rocks.", before: "and", protectedTerms: ["Wispen"]), " Wispen rocks.")
    }

    func testTrailingSpaceBeforeWord() {
        XCTAssertEqual(InsertionFormatter.prepare("Very", before: "", after: "nice"), "Very ")
    }

    func testEchoDetection() {
        let others = [TranscriptSegment(start: 0, end: 10, speaker: "Others", text: "We should ship the beta to customers on Friday.")]
        let echo = TranscriptSegment(start: 2, end: 9, speaker: "Me", text: "ship the beta to customers on Friday")
        let mine = TranscriptSegment(start: 2, end: 9, speaker: "Me", text: "I disagree, the docs aren't ready yet.")
        XCTAssertTrue(TranscriptMerger.isMicEcho(echo, among: others))
        XCTAssertFalse(TranscriptMerger.isMicEcho(mine, among: others))
        let late = TranscriptSegment(start: 200, end: 209, speaker: "Me", text: "ship the beta to customers on Friday")
        XCTAssertFalse(TranscriptMerger.isMicEcho(late, among: others))
    }
}
