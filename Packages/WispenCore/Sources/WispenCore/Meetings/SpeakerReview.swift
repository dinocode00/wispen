import Foundation

/// Helpers for the "Who's who?" step after a meeting: sample lines per voice, applying the names
/// you give (two voices with the same name become one person), and fixing individual lines.
public enum SpeakerReview {
    /// Up to `count` representative lines for a speaker, spread across the meeting and preferring
    /// full sentences (roughly 6–40 words) so they're easy to recognize.
    public static func samples(in segments: [TranscriptSegment], for speaker: String, count: Int = 3) -> [TranscriptSegment] {
        let lines = segments.filter { $0.speaker == speaker }.sorted { $0.start < $1.start }
        guard lines.count > count else { return lines }

        func score(_ s: TranscriptSegment) -> Int {
            let words = s.text.wordCount
            if words < 4 { return words }
            return words <= 40 ? 100 + words : 100 - (words - 40)
        }
        // Best line from each part of the meeting (beginning / middle / end).
        var picked: [TranscriptSegment] = []
        for i in 0..<count {
            let lo = lines.count * i / count
            let hi = lines.count * (i + 1) / count
            if let best = lines[lo..<hi].max(by: { score($0) < score($1) }) { picked.append(best) }
        }
        return picked.sorted { $0.start < $1.start }
    }

    /// Renames speakers (empty names are ignored). Giving two voices the same name merges them.
    public static func apply(names: [String: String], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let renamed = segments.map { seg -> TranscriptSegment in
            var seg = seg
            if let old = seg.speaker, let new = names[old]?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty {
                seg.speaker = new
            }
            return seg
        }
        return mergeAdjacent(renamed)
    }

    /// Moves one line to another speaker.
    public static func reassign(segmentID: String, to speaker: String, in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        mergeAdjacent(segments.map { seg in
            var seg = seg
            if seg.id == segmentID { seg.speaker = speaker }
            return seg
        })
    }

    /// Joins consecutive lines from the same speaker into one paragraph (up to ~90 s).
    public static func mergeAdjacent(_ segments: [TranscriptSegment], maxGap: Double = 2, maxLength: Double = 90) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.speaker == seg.speaker, seg.start - last.end <= maxGap,
               seg.end - last.start <= maxLength {
                last.text = TextTidy.tidy(last.text + " " + seg.text)
                last.end = max(last.end, seg.end)
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    private static let notNames: Set<String> = [
        "You", "Everyone", "Everybody", "Guys", "All", "Team", "There", "Folks", "Again", "So", "And", "The",
        "I", "We", "It", "That", "This", "Yeah", "Okay", "Ok", "Good", "Great", "God", "Man",
    ]

    /// First names people were addressed by ("Thanks, Sam", "Hi Maria"), most frequent first.
    public static func mentionedNames(in segments: [TranscriptSegment], limit: Int = 6) -> [String] {
        let pattern = "\\b(?:thanks|thank you|hi|hey|hello|bye|morning|sorry|right|okay|ok|so|yes|no)[, ]+([A-Z][a-z]{1,15})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var counts: [String: Int] = [:]
        for seg in segments {
            let text = seg.text
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                // Must really be capitalized in the transcript (the regex itself is case-insensitive).
                guard name.first?.isUppercase == true, !notNames.contains(name) else { continue }
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }
}
