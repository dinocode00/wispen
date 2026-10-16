import Foundation

/// Produces a smart recap from a transcript of any length, built the way research meeting-recap
/// systems are (topic segmentation → per-topic notes → synthesis), sized for a small on-device model:
///
///  1. **Topic notes** – each transcript part (as big as the context allows) becomes notes per subject:
///     a summary, the information worth keeping (POINT), and any decisions / actions / open questions /
///     concerns, each with the exact words it is based on. Items whose words aren't in the transcript
///     are dropped right away.
///  2. **Group** – subjects that continue across parts are grouped (one tiny call over titles only).
///  3. **Merge** – each group's notes become one story; later statements override earlier ones, so a
///     question answered later is no longer "open".
///  4. **Verify** – every remaining decision / action / question / concern gets a second look in a fresh
///     context, with only its quote: is this really a promise, an agreement, an unanswered question?
///     Ideas and opinions are dropped. Items you removed from earlier recaps guide this check.
///  5. **Recap** – the model writes the title, summary, key points and what kind of conversation it was;
///     the lists are the verified items. Nothing is padded to fill a section: an informational
///     conversation simply has no action items.
///
/// Every model step has a mechanical fallback so a recap is always produced.
public struct MeetingSummarizer: Sendable {
    public typealias Progress = @Sendable (_ completed: Int, _ total: Int, _ stage: String) -> Void

    public var generator: TextGenerator
    public var guidance: RecapGuidance
    /// Tokens reserved for instructions + response.
    public var reservedTokens: Int

    public init(generator: TextGenerator, guidance: RecapGuidance = RecapGuidance(), reservedTokens: Int = 2000) {
        self.generator = generator
        self.guidance = guidance
        self.reservedTokens = reservedTokens
    }

    var inputBudget: Int { max(600, generator.contextTokens - reservedTokens) }

    public func summarize(transcript: String, progress: Progress? = nil) async throws -> MeetingRecap {
        let text = transcript.trimmed
        guard !text.isEmpty else { throw LLMError.failed("The transcript is empty.") }

        let chunks = TranscriptChunker.chunk(text, maxTokens: inputBudget)
        let total = chunks.count + (chunks.count > 1 ? 2 : 0) + 2
        var done = 0

        // 1. Topic notes per part, checked against that part.
        var notes: [TopicNote] = []
        for (i, chunk) in chunks.enumerated() {
            progress?(done, total, chunks.count == 1 ? "Reading the conversation" : "Reading part \(i + 1) of \(chunks.count)")
            notes += try await topicNotes(chunk, part: i + 1, of: chunks.count, depth: 0)
            done += 1
        }
        notes = notes.filter { !$0.isEmpty }
        guard !notes.isEmpty else { throw LLMError.failed("Couldn't find any discussion in the transcript.") }

        // 2–3. Connect subjects across parts.
        var topics = notes
        if chunks.count > 1, notes.count > 1 {
            progress?(done, total, "Connecting topics")
            let groups = await groupTopics(notes)
            done += 1
            progress?(done, total, "Combining notes per topic")
            let source = Grounding.Source(text)
            topics = []
            for group in groups {
                let members = group.indices.map { notes[$0] }
                if members.count == 1 {
                    topics.append(members[0])
                } else {
                    // The merge may reword items; they still have to match what was said.
                    topics.append(TopicNotesParser.grounded(await mergeTopic(members, title: group.title), in: source))
                }
            }
            done += 1
        }

        // 4. Second look at every decision / action / question / concern.
        progress?(done, total, "Checking action items")
        let items = await verifiedItems(topics)
        done += 1

        // 5. Final recap.
        progress?(done, total, "Writing recap")
        let recap = await finalRecap(topics, items: items)
        progress?(total, total, "Done")
        return recap
    }

    // MARK: Steps

    private func topicNotes(_ chunk: String, part: Int, of total: Int, depth: Int) async throws -> [TopicNote] {
        do {
            let output = try await generator.generate(
                instructions: Prompts.topicNotesInstructions(part: part, of: total),
                prompt: Prompts.transcriptPrompt(chunk),
                temperature: 0.2, maxTokens: 900)
            let source = Grounding.Source(chunk)
            return TopicNotesParser.parse(OutputSanitizer.clean(output)).map { TopicNotesParser.grounded($0, in: source) }
        } catch LLMError.contextOverflow where depth < 3 {
            // Our estimate was off for this chunk: split it and try again.
            let halves = TranscriptChunker.chunk(chunk, maxTokens: max(200, TokenEstimator.estimate(chunk) / 2))
            var out: [TopicNote] = []
            for h in halves { out += try await topicNotes(h, part: part, of: total, depth: depth + 1) }
            return out
        } catch LLMError.refused {
            // Guardrails tripped on this part; keep going without it.
            return []
        }
    }

    private func groupTopics(_ notes: [TopicNote]) async -> [(indices: [Int], title: String?)] {
        let prompt = Prompts.groupTopicsPrompt(notes)
        guard TokenEstimator.estimate(prompt) <= inputBudget,
              let output = try? await generator.generate(instructions: Prompts.groupTopicsInstructions,
                                                         prompt: prompt, temperature: 0, maxTokens: 300) else {
            return Self.groupByTitle(notes)
        }
        let groups = TopicNotesParser.parseGroups(OutputSanitizer.clean(output), count: notes.count)
        // If the model returned nothing usable, every topic is its own group: fall back to titles.
        return groups.count == notes.count ? Self.groupByTitle(notes) : groups
    }

    /// Fallback grouping: identical titles (ignoring case) are the same subject.
    static func groupByTitle(_ notes: [TopicNote]) -> [(indices: [Int], title: String?)] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (i, n) in notes.enumerated() {
            let key = n.title.lowercased().trimmed
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(i)
        }
        return order.map { (map[$0]!, notes[map[$0]![0]].title) }
    }

    private func mergeTopic(_ members: [TopicNote], title: String?) async -> TopicNote {
        let fallback = TopicNotesParser.mechanicalMerge(members, title: title)
        let prompt = TopicNotesParser.render(members) + "\n\nCombined:"
        if TokenEstimator.estimate(prompt) > inputBudget {
            // Too much for one call: merge each half, then the two results.
            let mid = members.count / 2
            guard mid > 0 else { return fallback }
            let a = await mergeTopic(Array(members[..<mid]), title: title)
            let b = await mergeTopic(Array(members[mid...]), title: title)
            return await mergeTopic([a, b], title: title)
        }
        guard let output = try? await generator.generate(instructions: Prompts.mergeTopicInstructions,
                                                         prompt: prompt, temperature: 0.2, maxTokens: 700),
              var merged = TopicNotesParser.parse(OutputSanitizer.clean(output)).first,
              !merged.summary.isEmpty else {
            return fallback
        }
        if merged.title.isEmpty { merged.title = fallback.title }
        if merged.points.isEmpty { merged.points = Array(fallback.points.prefix(6)) }
        // Small models sometimes drop commitments while merging; keep them (they were already checked).
        if merged.actions.isEmpty { merged.actions = fallback.actions }
        if merged.decisions.isEmpty { merged.decisions = fallback.decisions }
        // Items the model kept without repeating their quote keep the original one.
        merged.quotes.merge(fallback.quotes) { mine, _ in mine }
        return merged
    }

    /// The decisions, actions, questions, concerns and postponed subjects that survive a second look.
    struct Items: Equatable {
        var decisions: [String] = []
        var actions: [ActionItem] = []
        var open: [String] = []
        var concerns: [String] = []
        var later: [String] = []
    }

    private struct Candidate {
        var kind: String
        var text: String
        var quote: String?
        var action: ActionItem?
    }

    private func verifiedItems(_ topics: [TopicNote]) async -> Items {
        // Collect, merging near-duplicates from different subjects.
        var candidates: [Candidate] = []
        func add(_ kind: String, _ text: String, _ quote: String?, _ action: ActionItem? = nil) {
            guard !candidates.contains(where: { $0.kind == kind && Grounding.similar($0.text, text) }) else { return }
            candidates.append(Candidate(kind: kind, text: text, quote: quote, action: action))
        }
        for t in topics {
            t.decisions.forEach { add("DECISION", $0, t.quote(for: $0)) }
            t.actions.forEach { add("ACTION", "\($0.owner ?? "Unassigned"): \($0.task)", t.quote(for: $0.task), $0) }
            t.open.forEach { add("OPEN", $0, t.quote(for: $0)) }
            t.concerns.forEach { add("CONCERN", $0, t.quote(for: $0)) }
            t.later.forEach { add("LATER", $0, t.quote(for: $0)) }
        }

        // Ask in batches that fit the context. Anything the model doesn't answer stays: it already
        // matched the transcript.
        var keep = Array(repeating: true, count: candidates.count)
        let instructions = Prompts.verifyItemsInstructions(guidance: guidance)
        var start = 0
        while start < candidates.count {
            var end = start
            var batch: [(kind: String, text: String, quote: String?)] = []
            while end < candidates.count {
                let c = candidates[end]
                let next = batch + [(c.kind, c.text, c.quote)]
                if !batch.isEmpty, TokenEstimator.estimate(instructions + Prompts.verifyItemsPrompt(next)) > inputBudget { break }
                batch = next
                end += 1
            }
            if let output = try? await generator.generate(instructions: instructions,
                                                          prompt: Prompts.verifyItemsPrompt(batch), temperature: 0,
                                                          maxTokens: 8 * batch.count + 40) {
                for (i, verdict) in Self.parseVerdicts(OutputSanitizer.clean(output)) where i < batch.count {
                    keep[start + i] = verdict
                }
            }
            start = end
        }

        var items = Items()
        for (c, kept) in zip(candidates, keep) where kept {
            switch c.kind {
            case "DECISION": items.decisions.append(c.text)
            case "ACTION": if let a = c.action { items.actions.append(a) }
            case "OPEN": items.open.append(c.text)
            case "CONCERN": items.concerns.append(c.text)
            default: items.later.append(c.text)
            }
        }
        return items
    }

    /// "1 = keep", "2: drop", "3. Keep" → [0: true, 1: false, 2: true].
    static func parseVerdicts(_ text: String) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        guard let regex = try? NSRegularExpression(pattern: "^\\D{0,3}(\\d+)[\\s*=:.)\\-–—]*(keep|drop|yes|no)\\b",
                                                   options: [.caseInsensitive]) else { return out }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let n = Range(m.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
                  let v = Range(m.range(at: 2), in: line).map({ line[$0].lowercased() }), n >= 1 else { continue }
            out[n - 1] = v == "keep" || v == "yes"
        }
        return out
    }

    /// Conversations that are mostly about sharing information get fewer secondary lists.
    static let informationalKinds: Set<String> = ["briefing", "learning", "interview", "casual", "brainstorm"]

    private func finalRecap(_ topics: [TopicNote], items: Items) async -> MeetingRecap {
        var input = topics
        if TokenEstimator.estimate(Prompts.notesPrompt(input)) > inputBudget {
            // Shorten each subject to the first two sentences and its top three points.
            input = topics.map { t in
                var t = t
                t.summary = t.summary.components(separatedBy: ". ").prefix(2).joined(separator: ". ")
                t.points = Array(t.points.prefix(3))
                return t
            }
        }
        if TokenEstimator.estimate(Prompts.notesPrompt(input)) > inputBudget {
            input = input.map { t in var t = t; t.points = []; return t }
        }
        var recap = MeetingRecap()
        if TokenEstimator.estimate(Prompts.notesPrompt(input)) <= inputBudget,
           let output = try? await generator.generate(instructions: Prompts.finalRecapInstructions(guidance: guidance),
                                                      prompt: Prompts.notesPrompt(input), temperature: 0.2, maxTokens: 700) {
            let parsed = RecapParser.parse(OutputSanitizer.clean(output))
            recap.kind = parsed.kind
            recap.title = parsed.title
            recap.summary = parsed.summary
            recap.keyPoints = parsed.keyPoints
        }

        // Fill gaps from the topic notes themselves.
        if recap.title.isEmpty { recap.title = topics.first?.title ?? "" }
        if recap.summary.isEmpty {
            recap.summary = topics.prefix(3).compactMap { $0.summary.components(separatedBy: ". ").first }
                .joined(separator: ". ")
        }
        if recap.keyPoints.isEmpty {
            let points = topics.flatMap { $0.points.prefix(2) }
            recap.keyPoints = points.isEmpty
                ? topics.prefix(6).compactMap { $0.summary.isEmpty ? nil : "\($0.title): \($0.summary)" }
                : Array(points.prefix(8))
        }
        recap.topics = topics.map { RecapTopic(title: $0.title, summary: $0.summary) }

        // Only what survived the checks, kept scannable.
        let secondary = recap.kind.map(Self.informationalKinds.contains) == true ? 3 : 6
        recap.keyPoints = Array(recap.keyPoints.prefix(8))
        recap.decisions = Array(items.decisions.prefix(8))
        recap.actionItems = Array(items.actions.prefix(12))
        recap.openQuestions = Array(items.open.prefix(secondary))
        recap.risks = Array(items.concerns.prefix(secondary))
        recap.followUps = Array(items.later.prefix(secondary))
        return recap
    }
}

/// "What did Sam say about the budget?" — answers questions about a meeting from relevant excerpts.
public struct MeetingQA: Sendable {
    public var generator: TextGenerator

    public init(generator: TextGenerator) {
        self.generator = generator
    }

    public func answer(question: String, meeting: Meeting) async throws -> String {
        let budget = max(500, generator.contextTokens - 1200)
        let excerpts = Self.relevantExcerpts(question: question, transcript: meeting.transcriptText,
                                             summary: meeting.recap?.summary, budget: budget)
        guard !excerpts.isEmpty else { return "I couldn't find anything about that in the meeting." }
        let output = try await generator.generate(
            instructions: Prompts.meetingQAInstructions,
            prompt: Prompts.meetingQAPrompt(question: question, summary: meeting.recap?.summary, excerpts: excerpts),
            temperature: 0.3)
        return OutputSanitizer.clean(output)
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with", "about", "at", "by", "is", "are",
        "was", "were", "be", "it", "this", "that", "what", "who", "when", "where", "why", "how", "did", "do", "does",
        "we", "i", "you", "they", "he", "she", "say", "said", "meeting", "any", "there", "anything", "me", "our",
    ]

    static func terms(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stopwords.contains($0) }
    }

    /// BM25-style keyword retrieval over small transcript windows, returned in meeting order.
    public static func relevantExcerpts(question: String, transcript: String, summary: String?, budget: Int) -> [String] {
        let windows = TranscriptChunker.chunk(transcript, maxTokens: 220, overlapSentences: 1)
        guard !windows.isEmpty else { return [] }
        let q = Set(terms(question))
        let docs = windows.map { terms($0) }
        let avgLen = Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count)
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }

        func score(_ d: [String]) -> Double {
            let k1 = 1.2, b = 0.75
            var s = 0.0
            for t in q {
                let tf = Double(d.filter { $0 == t || $0.hasPrefix(t) }.count)
                guard tf > 0 else { continue }
                let n = Double(df[t] ?? 0)
                let idf = log(1 + (Double(docs.count) - n + 0.5) / (n + 0.5))
                s += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(d.count) / max(avgLen, 1)))
            }
            return s
        }

        let ranked = docs.indices.map { ($0, score(docs[$0])) }.sorted { $0.1 > $1.1 }
        var picked: [Int] = []
        var used = TokenEstimator.estimate(summary ?? "") + TokenEstimator.estimate(question)
        // If nothing matches the keywords (vague question), fall back to the opening of the meeting.
        let candidates = ranked.first.map { $0.1 > 0 } == true ? ranked.filter { $0.1 > 0 }.map(\.0) : Array(windows.indices)
        for i in candidates {
            let cost = TokenEstimator.estimate(windows[i]) + 4
            if used + cost > budget { continue }
            picked.append(i)
            used += cost
        }
        return picked.sorted().map { windows[$0] }
    }
}
