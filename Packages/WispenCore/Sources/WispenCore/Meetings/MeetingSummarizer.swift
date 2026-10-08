import Foundation

/// Produces a smart recap from a transcript of any length, built the way research meeting-recap
/// systems are (topic segmentation → per-topic notes → synthesis), sized for a small on-device model:
///
///  1. **Topic notes** – each transcript part (as big as the context allows) becomes notes per subject:
///     a synthesized summary plus any decisions / actions / open questions / concerns.
///  2. **Group** – subjects that continue across parts are grouped (one tiny call over titles only).
///  3. **Merge** – each group's notes become one story; later statements override earlier ones, so a
///     question answered later is no longer "open".
///  4. **Recap** – the final recap is written from the merged subjects with strict section rules,
///     and the subjects themselves become the "Topics discussed" outline.
///
/// Every model step has a mechanical fallback so a recap is always produced.
public struct MeetingSummarizer: Sendable {
    public typealias Progress = @Sendable (_ completed: Int, _ total: Int, _ stage: String) -> Void

    public var generator: TextGenerator
    /// Tokens reserved for instructions + response.
    public var reservedTokens: Int

    public init(generator: TextGenerator, reservedTokens: Int = 1600) {
        self.generator = generator
        self.reservedTokens = reservedTokens
    }

    var inputBudget: Int { max(600, generator.contextTokens - reservedTokens) }

    public func summarize(transcript: String, progress: Progress? = nil) async throws -> MeetingRecap {
        let text = transcript.trimmed
        guard !text.isEmpty else { throw LLMError.failed("The transcript is empty.") }

        let chunks = TranscriptChunker.chunk(text, maxTokens: inputBudget)
        let total = chunks.count + (chunks.count > 1 ? 2 : 0) + 1
        var done = 0

        // 1. Topic notes per part.
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
            topics = []
            for group in groups {
                let members = group.indices.map { notes[$0] }
                topics.append(members.count == 1 ? members[0] : await mergeTopic(members, title: group.title))
            }
            done += 1
        }

        // 4. Final recap.
        progress?(done, total, "Writing recap")
        let recap = await finalRecap(topics)
        progress?(total, total, "Done")
        return recap
    }

    // MARK: Steps

    private func topicNotes(_ chunk: String, part: Int, of total: Int, depth: Int) async throws -> [TopicNote] {
        do {
            let output = try await generator.generate(
                instructions: Prompts.topicNotesInstructions(part: part, of: total),
                prompt: Prompts.transcriptPrompt(chunk),
                temperature: 0.2)
            return TopicNotesParser.parse(OutputSanitizer.clean(output))
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
                                                         prompt: prompt, temperature: 0) else {
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
                                                         prompt: prompt, temperature: 0.2),
              var merged = TopicNotesParser.parse(OutputSanitizer.clean(output)).first,
              !merged.summary.isEmpty else {
            return fallback
        }
        if merged.title.isEmpty { merged.title = fallback.title }
        // Small models sometimes drop commitments while merging; keep them.
        if merged.actions.isEmpty { merged.actions = fallback.actions }
        if merged.decisions.isEmpty { merged.decisions = fallback.decisions }
        return merged
    }

    private func finalRecap(_ topics: [TopicNote]) async -> MeetingRecap {
        var input = topics
        if TokenEstimator.estimate(Prompts.notesPrompt(input)) > inputBudget {
            // Shorten each subject's story to its first two sentences.
            input = topics.map { t in
                var t = t
                t.summary = t.summary.components(separatedBy: ". ").prefix(2).joined(separator: ". ")
                return t
            }
        }
        var recap = MeetingRecap()
        var modelWroteRecap = false
        if TokenEstimator.estimate(Prompts.notesPrompt(input)) <= inputBudget,
           let output = try? await generator.generate(instructions: Prompts.finalRecapInstructions,
                                                      prompt: Prompts.notesPrompt(input), temperature: 0.2) {
            recap = RecapParser.parse(OutputSanitizer.clean(output))
            modelWroteRecap = !recap.isEmpty
        }

        // Fill gaps from the topic notes themselves.
        let merged = TopicNotesParser.mechanicalMerge(topics)
        if recap.title.isEmpty { recap.title = topics.first?.title ?? "" }
        if recap.summary.isEmpty {
            recap.summary = topics.prefix(3).compactMap { $0.summary.components(separatedBy: ". ").first }
                .joined(separator: ". ")
        }
        if recap.keyPoints.isEmpty {
            recap.keyPoints = topics.prefix(6).compactMap { $0.summary.isEmpty ? nil : "\($0.title): \($0.summary)" }
        }
        // Commitments and agreements are too important to lose if the model drops them.
        if recap.actionItems.isEmpty { recap.actionItems = merged.actions }
        if recap.decisions.isEmpty { recap.decisions = merged.decisions }
        if !modelWroteRecap {
            // Leaving these out can be a deliberate judgment call, so only fill them when the model failed.
            recap.openQuestions = merged.open
            recap.risks = merged.concerns
            recap.followUps = merged.later
        }
        recap.topics = topics.map { RecapTopic(title: $0.title, summary: $0.summary) }

        // Keep it scannable.
        recap.keyPoints = Array(recap.keyPoints.prefix(6))
        recap.decisions = Array(recap.decisions.prefix(8))
        recap.actionItems = Array(recap.actionItems.prefix(12))
        recap.openQuestions = Array(recap.openQuestions.prefix(6))
        recap.risks = Array(recap.risks.prefix(6))
        recap.followUps = Array(recap.followUps.prefix(6))
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
