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
        for i in 0..<(minutes * 9) { lines.append("\(i % 2 == 0 ? "Speaker 1" : "Speaker 2"): \(sentence) Item \(i).") }
        return lines.joined(separator: "\n")
    }

    /// Fake model that answers each pipeline step like a well-behaved small model.
    func pipelineModel(expectResolved: Bool = true, onCall: @escaping (String) -> Void = { _ in }) -> FakeGenerator {
        FakeGenerator(contextTokens: 4096) { instructions, prompt in
            XCTAssertLessThanOrEqual(TokenEstimator.estimate(instructions + prompt), 4096 - 400, "prompt overflowed context")
            if instructions.contains("You take notes on part 1 ") {
                onCall("notes1")
                return """
                TOPIC: Launch date
                SUMMARY: The team debated moving the launch. Sam worried QA is behind.
                OPEN: Will QA finish in time?
                CONCERN: QA is two weeks behind

                TOPIC: Small talk
                SUMMARY: None
                """
            }
            if instructions.contains("You take notes on part") {
                onCall("notes")
                return """
                TOPIC: Launch timing
                SUMMARY: QA confirmed they will finish by April 28, so the launch stays on May 3.
                DECISION: Launch stays on May 3
                ACTION: Sam: Send the launch checklist (due: Friday)
                """
            }
            if instructions.contains("Group the numbers") {
                onCall("group")
                XCTAssertTrue(prompt.contains("1. Launch date"))
                let count = prompt.components(separatedBy: "\n").filter { $0.first?.isNumber == true }.count
                return (1...count).map(String.init).joined(separator: ", ") + " = Launch timing"
            }
            if instructions.contains("SAME subject") {
                onCall("merge")
                return """
                TOPIC: Launch timing
                SUMMARY: The team debated moving the launch because QA was behind. QA later confirmed April 28, so the launch stays on May 3.
                DECISION: Launch stays on May 3
                ACTION: Sam: Send the launch checklist (due: Friday)
                """
            }
            if instructions.contains("final recap") {
                onCall("final")
                if expectResolved {
                    XCTAssertFalse(prompt.contains("Will QA finish in time?"), "resolved question should not reach the final step")
                }
                return """
                TITLE: Launch go/no-go
                SUMMARY: The team confirmed the May 3 launch after QA committed to April 28.
                KEY POINTS:
                - QA's April 28 commitment removes the main schedule risk.
                DECISIONS:
                - Launch stays on May 3
                ACTION ITEMS:
                - Sam: Send the launch checklist (due: Friday)
                OPEN QUESTIONS:
                None
                RISKS:
                None
                FOLLOW-UPS:
                None
                """
            }
            XCTFail("unexpected step: \(instructions.prefix(60))")
            return ""
        }
    }

    func testTopicPipelineConnectsTheDots() async throws {
        final class Calls: @unchecked Sendable { var list: [String] = [] }
        let calls = Calls()
        let gen = pipelineModel { calls.list.append($0) }
        let transcript = makeTranscript(minutes: 30)
        final class Stages: @unchecked Sendable { var list: [String] = [] }
        let stages = Stages()
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: transcript) { _, _, s in stages.list.append(s) }

        XCTAssertTrue(calls.list.contains("group"))
        XCTAssertTrue(calls.list.contains("merge"))
        XCTAssertEqual(calls.list.last, "final")
        XCTAssertEqual(recap.title, "Launch go/no-go")
        XCTAssertEqual(recap.decisions, ["Launch stays on May 3"])
        XCTAssertEqual(recap.actionItems.first?.owner, "Sam")
        XCTAssertEqual(recap.actionItems.first?.due, "Friday")
        XCTAssertTrue(recap.openQuestions.isEmpty)
        XCTAssertEqual(recap.topics.map(\.title), ["Launch timing"])
        XCTAssertTrue(recap.topics[0].summary.contains("April 28"))
        XCTAssertEqual(stages.list.last, "Done")
    }

    func testShortMeetingSkipsGrouping() async throws {
        final class Calls: @unchecked Sendable { var list: [String] = [] }
        let calls = Calls()
        let gen = pipelineModel(expectResolved: false) { calls.list.append($0) }
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 2))
        XCTAssertEqual(calls.list, ["notes1", "final"])
        XCTAssertEqual(recap.topics.map(\.title), ["Launch date"], "empty small-talk topic is dropped")
    }

    func testPipelineFallsBackWhenLaterStepsFail() async throws {
        let gen = FakeGenerator { instructions, _ in
            if instructions.contains("You take notes on part") {
                return "TOPIC: Budget\nSUMMARY: Budget is 40k.\nACTION: Ana: Draft the budget\nOPEN: Who approves it?"
            }
            throw LLMError.failed("boom")
        }
        let recap = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 30))
        XCTAssertEqual(recap.topics.count, 1, "same-title topics are grouped without the model")
        XCTAssertEqual(recap.actionItems.map(\.task), ["Draft the budget"])
        XCTAssertEqual(recap.openQuestions, ["Who approves it?"])
        XCTAssertFalse(recap.keyPoints.isEmpty)
    }

    func testSummarizerSplitsOnContextOverflow() async throws {
        final class Flag: @unchecked Sendable { var overflowed = false }
        let flag = Flag()
        let base = pipelineModel()
        let gen = FakeGenerator { instructions, prompt in
            if instructions.contains("You take notes on part 1 "), !flag.overflowed {
                flag.overflowed = true
                throw LLMError.contextOverflow
            }
            return try base.handler(instructions, prompt)
        }
        _ = try await MeetingSummarizer(generator: gen).summarize(transcript: makeTranscript(minutes: 20))
        XCTAssertTrue(flag.overflowed)
    }

    func testTopicNotesParser() {
        let notes = TopicNotesParser.parse("""
        **TOPIC:** Hiring
        SUMMARY: We need two engineers.
        The budget allows one now.
        - ACTION: Unassigned: Post the job
        DECISION: None
        OPEN: When does the second role open?

        TOPIC: Offsite
        SUMMARY: Planning the June offsite.
        LATER: Venue choice
        """)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].title, "Hiring")
        XCTAssertEqual(notes[0].summary, "We need two engineers. The budget allows one now.")
        XCTAssertNil(notes[0].actions.first?.owner)
        XCTAssertTrue(notes[0].decisions.isEmpty)
        XCTAssertEqual(notes[1].later, ["Venue choice"])
        let rendered = TopicNotesParser.render(notes)
        XCTAssertEqual(TopicNotesParser.render(TopicNotesParser.parse(rendered)), rendered)
    }

    func testGroupParsing() {
        let g = TopicNotesParser.parseGroups("1, 3 = Pricing\n- 2 = Hiring\n3 = dup\n9 = out of range", count: 4)
        XCTAssertEqual(g.map(\.indices), [[0, 2], [1], [3]])
        XCTAssertEqual(g[0].title, "Pricing")
    }

    func testSpeakerAssignment() {
        let words = [
            TimedText(text: " Hi", start: 0.0, end: 0.3), TimedText(text: " Sam.", start: 0.3, end: 0.6),
            TimedText(text: " Hey!", start: 1.0, end: 1.3), TimedText(text: " Ready?", start: 1.4, end: 1.8),
            TimedText(text: " Yes", start: 2.5, end: 2.8),
        ]
        let turns = [SpeakerTurn(speaker: 7, start: 0, end: 0.8), SpeakerTurn(speaker: 3, start: 0.9, end: 2.0),
                     SpeakerTurn(speaker: 7, start: 2.4, end: 3.0)]
        let segs = SpeakerAssigner.label(words, turns: turns)
        XCTAssertEqual(segs.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(segs.map(\.text), ["Hi Sam.", "Hey! Ready?", "Yes"])
        XCTAssertEqual(segs[1].start, 1.0)
    }

    func testSpeakerAssignmentFillsGaps() {
        let words = [TimedText(text: "a", start: 0, end: 0.2), TimedText(text: "b", start: 10, end: 10.2)]
        let segs = SpeakerAssigner.label(words, turns: [SpeakerTurn(speaker: 0, start: 0, end: 0.3)])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].speaker, "Speaker 1")
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
        XCTAssertTrue(chunks[0].hasPrefix("Speaker 1:"))
    }
}

final class SpeakerReviewTests: XCTestCase {
    func seg(_ speaker: String, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, speaker: speaker, text: text)
    }

    func testSmoothingRemovesShortIslands() {
        let words = (0..<9).map { TimedText(text: "w\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let ids: [Int?] = [1, 1, 1, 2, 2, 1, 1, 1, 1]
        XCTAssertEqual(SpeakerAssigner.smoothIslands(ids, words: words), [1, 1, 1, 1, 1, 1, 1, 1, 1])
        // A real reply (long enough) is kept.
        let long: [Int?] = [1, 1, 2, 2, 2, 2, 1, 1, 1]
        XCTAssertEqual(SpeakerAssigner.smoothIslands(long, words: words), long)
    }

    func testSamplesSpreadAcrossMeeting() {
        var segs: [TranscriptSegment] = []
        for i in 0..<30 {
            let words = i % 5 == 0 ? "This is a nice long and clear sentence from me number \(i)" : "ok"
            segs.append(seg(i % 2 == 0 ? "Speaker 1" : "Speaker 2", Double(i * 10), words))
        }
        let picks = SpeakerReview.samples(in: segs, for: "Speaker 1")
        XCTAssertEqual(picks.count, 3)
        XCTAssertTrue(picks.allSatisfy { $0.text.wordCount > 5 })
        XCTAssertLessThan(picks[0].start, 100)
        XCTAssertGreaterThanOrEqual(picks[2].start, 200)
    }

    func testApplyNamesMergesSamePerson() {
        let segs = [seg("Speaker 1", 0, "Hi."), seg("Speaker 3", 2.5, "I'm also Speaker 1 really."), seg("Speaker 2", 6, "Hello.")]
        let out = SpeakerReview.apply(names: ["Speaker 1": "Rex", "Speaker 3": "Rex", "Speaker 2": " Sam "], to: segs)
        XCTAssertEqual(out.map(\.speaker), ["Rex", "Sam"])
        XCTAssertEqual(out[0].text, "Hi. I'm also Speaker 1 really.")
    }

    func testReassign() {
        let segs = [seg("A", 0, "One."), seg("B", 10, "Two."), seg("A", 20, "Three.")]
        let out = SpeakerReview.reassign(segmentID: segs[1].id, to: "A", in: segs)
        XCTAssertEqual(out.map(\.speaker), ["A", "A", "A"], "gaps over 2 s stay separate lines")
    }

    func testMentionedNames() {
        let segs = [seg("Speaker 1", 0, "Thanks, Sam. Hi Maria, can you hear me?"), seg("Speaker 2", 3, "Yeah, thanks Sam. Okay everyone.")]
        XCTAssertEqual(SpeakerReview.mentionedNames(in: segs), ["Sam", "Maria"])
    }
}
