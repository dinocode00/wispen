import XCTest
@testable import WispenCore

/// Scripted fake model.
final class FakeGenerator: TextGenerator, @unchecked Sendable {
    var available = true
    var contextTokens: Int
    var handler: (String, String) throws -> String
    private(set) var calls: [(instructions: String, prompt: String)] = []

    init(contextTokens: Int = 4096, handler: @escaping (String, String) throws -> String) {
        self.contextTokens = contextTokens
        self.handler = handler
    }

    var isAvailable: Bool { get async { available } }

    func generate(instructions: String, prompt: String, temperature: Double?) async throws -> String {
        calls.append((instructions, prompt))
        return try handler(instructions, prompt)
    }
}

final class AITests: XCTestCase {
    func testCleanupUsesModelAndExpandsSnippets() async {
        let gen = FakeGenerator { _, prompt in
            XCTAssertTrue(prompt.contains("{{snippet_1}}"))
            return "Here's the cleaned text: Please email me at {{snippet_1}} by Friday."
        }
        let ctx = CleanupContext(style: .polished, snippets: [Snippet(trigger: "my email", expansion: "a@b.co")])
        let r = await CleanupPipeline(generator: gen).clean("um please email me at my email by friday", context: ctx)
        XCTAssertEqual(r.text, "Please email me at a@b.co by Friday.")
        XCTAssertTrue(r.usedAI)
    }

    func testCleanupFallsBackWhenModelAnswersInstead() async {
        let gen = FakeGenerator { _, _ in "I'm sorry, but I can't access real-time weather information right now." }
        let r = await CleanupPipeline(generator: gen).clean("what's the weather going to be like tomorrow",
                                                             context: CleanupContext(style: .polished))
        XCTAssertFalse(r.usedAI)
        XCTAssertEqual(r.text, "What's the weather going to be like tomorrow.")
    }

    func testCleanupFallsBackOnError() async {
        let gen = FakeGenerator { _, _ in throw LLMError.refused }
        let r = await CleanupPipeline(generator: gen).clean("uh this is a test of the fallback", context: CleanupContext(style: .polished))
        XCTAssertEqual(r.text, "This is a test of the fallback.")
        XCTAssertFalse(r.usedAI)
    }

    func testVerbatimSkipsModel() async {
        let gen = FakeGenerator { _, _ in XCTFail("should not be called"); return "" }
        let r = await CleanupPipeline(generator: gen).clean("this is exactly what I said", context: CleanupContext(style: .verbatimStyle))
        XCTAssertEqual(r.text, "This is exactly what I said.")
    }

    func testStyleEnforcedAfterModel() async {
        let gen = FakeGenerator { _, _ in "Running late. Be there in 10." }
        let r = await CleanupPipeline(generator: gen).clean("running late be there in ten", context: CleanupContext(style: .texting))
        XCTAssertEqual(r.text, "running late. be there in 10")
    }

    func testCommandMode() async throws {
        let gen = FakeGenerator { _, prompt in
            XCTAssertTrue(prompt.contains("Instruction: Make it shorter"))
            XCTAssertTrue(prompt.contains("long text"))
            return "\"short text\""
        }
        let out = try await CommandProcessor(generator: gen).run(instruction: "um make it shorter", selectedText: "long text", dictionary: [])
        XCTAssertEqual(out, "short text")
    }

    // MARK: Meetings

    static let chunkNotes = """
    TITLE: Part
    SUMMARY: The team discussed the launch.
    KEY POINTS:
    - Launch moved to May 3
    DECISIONS:
    - None
    ACTION ITEMS:
    - Sam: Update the roadmap (due: Friday)
    - Unassigned: Book a room
    OPEN QUESTIONS:
    None
    RISKS:
    - Vendor delay
    FOLLOW-UPS:
    - None
    """

    func testRecapParser() {
        let r = RecapParser.parse("**TITLE:** Launch sync\n## Summary\nWe met.\n" + Self.chunkNotes)
        XCTAssertEqual(r.title, "Launch sync")
        XCTAssertEqual(r.keyPoints, ["Launch moved to May 3"])
        XCTAssertEqual(r.decisions, [])
        XCTAssertEqual(r.actionItems.count, 2)
        XCTAssertEqual(r.actionItems[0].owner, "Sam")
        XCTAssertEqual(r.actionItems[0].task, "Update the roadmap")
        XCTAssertEqual(r.actionItems[0].due, "Friday")
        XCTAssertNil(r.actionItems[1].owner)
        XCTAssertEqual(r.risks, ["Vendor delay"])
        XCTAssertTrue(r.openQuestions.isEmpty)
        XCTAssertTrue(r.summary.contains("We met."))
    }

    func testRecapRoundTrip() {
        let r = RecapParser.parse(Self.chunkNotes)
        let rendered = RecapParser.render(r)
        XCTAssertEqual(RecapParser.render(RecapParser.parse(rendered)), rendered)
    }

    func testMarkdownHidesEmptySections() {
        let md = RecapParser.parse(Self.chunkNotes).markdown()
        XCTAssertTrue(md.contains("## Action items"))
        XCTAssertTrue(md.contains("- [ ] **Sam**: Update the roadmap _(due Friday)_"))
        XCTAssertFalse(md.contains("## Decisions"))
        XCTAssertFalse(md.contains("## Open questions"))
    }

    func makeTranscript(minutes: Int) -> String {
        // ~150 spoken words per minute.
        let sentence = "We talked about the launch plan and the budget for the next quarter in some detail today."
        var lines: [String] = []
        for i in 0..<(minutes * 9) { lines.append("\(i % 2 == 0 ? "Me" : "Others"): \(sentence) Item \(i).") }
        return lines.joined(separator: "\n")
    }

    func testSummarizerMapReduceFitsSmallContext() async throws {
        let gen = FakeGenerator(contextTokens: 4096) { instructions, prompt in
            XCTAssertLessThanOrEqual(TokenEstimator.estimate(instructions + prompt), 4096 - 500, "prompt overflowed context")
            if instructions.contains("single final recap") {
                return "TITLE: Quarterly launch planning\nSUMMARY: Big picture.\nKEY POINTS:\n- Launch plan\nACTION ITEMS:\n- Sam: Ship it"
            }
            return Self.chunkNotes
        }
        let transcript = makeTranscript(minutes: 60)
        XCTAssertGreaterThan(TokenEstimator.estimate(transcript), 12_000)
        final class Stages: @unchecked Sendable { var list: [String] = [] }
        let stages = Stages()
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: transcript) { _, _, stage in stages.list.append(stage) }
        XCTAssertEqual(recap.title, "Quarterly launch planning")
        XCTAssertEqual(recap.actionItems.first?.owner, "Sam")
        XCTAssertGreaterThan(gen.calls.count, 5)
        XCTAssertEqual(stages.list.last, "Done")
    }

    func testSummarizerSinglePassForShortMeeting() async throws {
        let gen = FakeGenerator { instructions, _ in
            XCTAssertTrue(instructions.contains("recap of a meeting transcript"))
            return "TITLE: Standup\nSUMMARY: Quick sync.\nDECISIONS:\n- Ship Friday"
        }
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 2))
        XCTAssertEqual(gen.calls.count, 1)
        XCTAssertEqual(recap.decisions, ["Ship Friday"])
    }

    func testSummarizerFallsBackToMechanicalMerge() async throws {
        let gen = FakeGenerator { instructions, _ in
            if instructions.contains("combine partial notes") { throw LLMError.failed("boom") }
            return Self.chunkNotes
        }
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 30))
        XCTAssertEqual(recap.keyPoints, ["Launch moved to May 3"])
        XCTAssertEqual(recap.actionItems.count, 2)
    }

    func testSummarizerSplitsOnContextOverflow() async throws {
        var overflowed = false
        let gen = FakeGenerator { instructions, prompt in
            if instructions.contains("part 1 of"), !overflowed { overflowed = true; throw LLMError.contextOverflow }
            return Self.chunkNotes
        }
        _ = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 20))
        XCTAssertTrue(overflowed)
    }

    func testQARetrievesRelevantExcerpt() {
        var lines = (0..<200).map { "Others: Filler discussion about many unrelated topics number \($0)." }
        lines.insert("Sam: The marketing budget will be 40 thousand dollars for Q3.", at: 137)
        let excerpts = MeetingQA.relevantExcerpts(question: "What did Sam say about the budget?",
                                                  transcript: lines.joined(separator: "\n"), summary: nil, budget: 600)
        XCTAssertTrue(excerpts.first?.contains("40 thousand") ?? false)
        XCTAssertLessThanOrEqual(excerpts.reduce(0) { $0 + TokenEstimator.estimate($1) }, 600)
    }

    func testChunkerRespectsBudget() {
        let chunks = TranscriptChunker.chunk(makeTranscript(minutes: 10), maxTokens: 500)
        XCTAssertGreaterThan(chunks.count, 3)
        for c in chunks { XCTAssertLessThanOrEqual(TokenEstimator.estimate(c), 520) }
        XCTAssertTrue(chunks[0].hasPrefix("Me:"))
    }
}
