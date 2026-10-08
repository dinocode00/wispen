import Foundation

/// A word (or short phrase) with its time in the meeting, from Whisper's word timestamps.
public struct TimedText: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// "Who spoke when", from speaker diarization (SpeakerKit).
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: Int
    public var start: Double
    public var end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Combines timed words with speaker turns into a readable, speaker-labelled transcript:
/// each word goes to the speaker talking at that moment, and consecutive words from the same
/// speaker become one segment ("Speaker 1: …", "Speaker 2: …").
public enum SpeakerAssigner {
    public static func label(_ words: [TimedText], turns: [SpeakerTurn], prefix: String = "Speaker",
                             maxSegmentSeconds: Double = 60) -> [TranscriptSegment] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return [] }
        let turns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }

        // 1. Raw speaker id per word (nil when nobody was detected nearby).
        var ids: [Int?] = words.map { speaker(for: $0, in: turns) }
        // Unknown words belong to the surrounding speaker.
        var last: Int?
        for i in ids.indices {
            if let id = ids[i] { last = id } else { ids[i] = last }
        }
        if let firstKnown = ids.first(where: { $0 != nil }) ?? nil {
            for i in ids.indices where ids[i] == nil { ids[i] = firstKnown }
        }

        // 2. Number speakers by first appearance: Speaker 1 talks first.
        var names: [Int: String] = [:]
        for id in ids.compactMap({ $0 }) where names[id] == nil {
            names[id] = "\(prefix) \(names.count + 1)"
        }

        // 3. Group consecutive words by speaker.
        var segments: [TranscriptSegment] = []
        var current: (speaker: String?, words: [TimedText])?
        func flush() {
            guard let c = current, let first = c.words.first, let lastWord = c.words.last else { return }
            let text = TextTidy.tidy(c.words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
            segments.append(TranscriptSegment(start: first.start, end: lastWord.end, speaker: c.speaker, text: text))
        }
        for (word, id) in zip(words, ids) {
            let name = id.flatMap { names[$0] }
            if let c = current, c.speaker == name, word.end - (c.words.first?.start ?? word.start) <= maxSegmentSeconds {
                current?.words.append(word)
            } else {
                flush()
                current = (name, [word])
            }
        }
        flush()
        return segments
    }

    /// The speaker overlapping a word the most; or the nearest turn within a second.
    static func speaker(for word: TimedText, in turns: [SpeakerTurn]) -> Int? {
        var best: (id: Int, overlap: Double)?
        for t in turns {
            if t.start > word.end { break }
            let overlap = min(t.end, word.end) - max(t.start, word.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speaker, overlap) }
        }
        if let best { return best.id }
        let mid = (word.start + word.end) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
        if let nearest, distance(mid, nearest) <= 1.0 { return nearest.speaker }
        return nil
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        if t < turn.start { return turn.start - t }
        if t > turn.end { return t - turn.end }
        return 0
    }
}
