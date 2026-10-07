import Foundation

/// Produces a smart recap from a transcript of any length.
///
/// Apple's on-device model has a ~4k-token context, while a 60-minute meeting is ~12k tokens. So:
///  1. **Map** – split the transcript into chunks that fit, and extract structured notes from each.
///  2. **Reduce** – merge notes in groups that fit, repeating until one set remains.
///  3. **Final** – one last merge that writes the title and big-picture summary.
/// Short meetings skip straight to a single pass. If a merge fails, notes are merged mechanically so
/// the user still gets a recap.
public struct MeetingSummarizer: Sendable {
    public typealias Progress = @Sendable (_ completed: Int, _ total: Int, _ stage: String) -> Void

    public var generator: TextGenerator
    /// Tokens reserved for instructions + response.
    public var reservedTokens: Int

    public init(generator: TextGenerator, reservedTokens: Int = 1500) {
        self.generator = generator
        self.reservedTokens = reservedTokens
    }

    var inputBudget: Int { max(600, generator.contextTokens - reservedTokens) }

    public func summarize(transcript: String, progress: Progress? = nil) async throws -> MeetingRecap {
        let text = transcript.trimmed
        guard !text.isEmpty else { throw LLMError.failed("The transcript is empty.") }

        // Single pass when it fits.
        if TokenEstimator.estimate(text) <= inputBudget {
            progress?(0, 1, "Writing recap")
            let recap = try await finalPass(prompt: Prompts.transcriptPrompt(text), instructions: Prompts.singlePassInstructions)
            progress?(1, 1, "Done")
            return recap
        }

        // Map.
        let chunks = TranscriptChunker.chunk(text, maxTokens: inputBudget)
        let mergeEstimate = max(1, chunks.count / 3)
        let total = chunks.count + mergeEstimate + 1
        var done = 0
        var notes: [MeetingRecap] = []
        for (i, chunk) in chunks.enumerated() {
            progress?(done, total, "Reading part \(i + 1) of \(chunks.count)")
            let partNotes = try await notesForChunk(chunk, part: i + 1, of: chunks.count, depth: 0)
            notes.append(contentsOf: partNotes)
            done += 1
        }

        // Reduce until everything fits into one final merge.
        var round = 0
        while notes.count > 1, renderedTokens(notes) > inputBudget, round < 6 {
            round += 1
            var merged: [MeetingRecap] = []
            for group in groupsFitting(notes) {
                progress?(done, total, "Combining notes")
                if group.count == 1 {
                    merged.append(group[0])
                } else {
                    merged.append(await merge(group, final: false))
                    done += 1
                }
            }
            // If nothing could be combined (each note alone is over budget), stop and merge mechanically.
            if merged.count == notes.count { notes = [RecapParser.mechanicalMerge(merged)]; break }
            notes = merged
        }

        progress?(done, total, "Writing recap")
        var final = await merge(notes, final: true)
        if final.title.isEmpty { final.title = notes.first(where: { !$0.title.isEmpty })?.title ?? "" }
        progress?(total, total, "Done")
        return final
    }

    private func notesForChunk(_ chunk: String, part: Int, of total: Int, depth: Int) async throws -> [MeetingRecap] {
        do {
            let output = try await generator.generate(
                instructions: Prompts.chunkNotesInstructions(part: part, of: total),
                prompt: Prompts.transcriptPrompt(chunk),
                temperature: 0.2)
            return [RecapParser.parse(OutputSanitizer.clean(output))]
        } catch LLMError.contextOverflow where depth < 3 {
            // Our estimate was off for this chunk: split it and try again.
            let halves = TranscriptChunker.chunk(chunk, maxTokens: max(200, TokenEstimator.estimate(chunk) / 2))
            var out: [MeetingRecap] = []
            for h in halves { out += try await notesForChunk(h, part: part, of: total, depth: depth + 1) }
            return out
        } catch LLMError.refused {
            // Guardrails tripped on this part; keep going without it.
            return []
        }
    }

    private func merge(_ notes: [MeetingRecap], final: Bool) async -> MeetingRecap {
        let nonEmpty = notes.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return MeetingRecap() }
        if nonEmpty.count == 1 && !final { return nonEmpty[0] }
        let rendered = nonEmpty.map { RecapParser.render($0, includeTitle: false) }
        do {
            let output = try await generator.generate(
                instructions: Prompts.mergeNotesInstructions(final: final),
                prompt: Prompts.notesPrompt(rendered),
                temperature: 0.2)
            let recap = RecapParser.parse(OutputSanitizer.clean(output))
            // A merge that lost almost everything is worse than a mechanical merge.
            let before = itemCount(RecapParser.mechanicalMerge(nonEmpty))
            if recap.isEmpty || (before >= 6 && itemCount(recap) < before / 5) {
                return RecapParser.mechanicalMerge(nonEmpty)
            }
            return recap
        } catch {
            return RecapParser.mechanicalMerge(nonEmpty)
        }
    }

    private func finalPass(prompt: String, instructions: String) async throws -> MeetingRecap {
        let output = try await generator.generate(instructions: instructions, prompt: prompt, temperature: 0.2)
        return RecapParser.parse(OutputSanitizer.clean(output))
    }

    private func itemCount(_ r: MeetingRecap) -> Int {
        r.keyPoints.count + r.decisions.count + r.actionItems.count + r.openQuestions.count + r.risks.count + r.followUps.count
    }

    private func renderedTokens(_ notes: [MeetingRecap]) -> Int {
        TokenEstimator.estimate(Prompts.notesPrompt(notes.map { RecapParser.render($0, includeTitle: false) }))
    }

    func groupsFitting(_ notes: [MeetingRecap]) -> [[MeetingRecap]] {
        var groups: [[MeetingRecap]] = []
        var current: [MeetingRecap] = []
        for n in notes {
            if !current.isEmpty, renderedTokens(current + [n]) > inputBudget {
                groups.append(current)
                current = []
            }
            current.append(n)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
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
