import Foundation

/// Notes about one subject of a meeting: the unit the recap pipeline works in.
///
/// Organizing by subject (instead of sorting each transcript chunk straight into recap sections)
/// is what lets the recap "connect the dots": a question raised early and answered later is
/// resolved when the subject's notes are merged, and each section is written from whole subjects.
public struct TopicNote: Sendable, Equatable {
    public var title: String
    public var summary: String
    /// Information worth keeping: facts, numbers, ideas, explanations. Most of a conversation lands here.
    public var points: [String] = []
    public var decisions: [String] = []
    public var actions: [ActionItem] = []
    public var open: [String] = []
    public var concerns: [String] = []
    public var later: [String] = []
    /// The words each decision / action / question / concern is based on, by item text (lowercased).
    public var quotes: [String: String] = [:]

    public init(title: String, summary: String, points: [String] = [], decisions: [String] = [], actions: [ActionItem] = [],
                open: [String] = [], concerns: [String] = [], later: [String] = []) {
        self.title = title
        self.summary = summary
        self.points = points
        self.decisions = decisions
        self.actions = actions
        self.open = open
        self.concerns = concerns
        self.later = later
    }

    func quote(for item: String) -> String? { quotes[item.lowercased()] }

    var isEmpty: Bool { summary.isEmpty && points.isEmpty && decisions.isEmpty && actions.isEmpty && open.isEmpty && concerns.isEmpty }
}

public enum TopicNotesParser {
    private enum Tag { case topic, summary, point, decision, action, open, concern, later }

    private static func tag(_ word: String) -> Tag? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "topic", "subject", "title": return .topic
        case "summary", "discussion": return .summary
        case "point", "points", "key point", "fact", "insight", "info", "detail": return .point
        case "decision", "decisions", "decided": return .decision
        case "action", "actions", "action item", "action items", "task", "todo", "to-do": return .action
        case "open", "open question", "open questions", "question", "questions": return .open
        case "concern", "concerns", "risk", "risks", "risks and concerns", "blocker": return .concern
        case "later", "follow-up", "follow-ups", "follow up", "followup", "deferred": return .later
        default: return nil
        }
    }

    public static func parse(_ text: String) -> [TopicNote] {
        var notes: [TopicNote] = []
        var lastTag: Tag?

        func current() -> Int {
            if notes.isEmpty { notes.append(TopicNote(title: "", summary: "")) }
            return notes.count - 1
        }

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmed.replacingRegex("\\*\\*", with: "").replacingRegex("^#+\\s*", with: "")
            line = line.replacingRegex("^(?:[-•*]|\\d+[.)])\\s+", with: "")
            guard !line.isEmpty else { continue }

            var tagged: (Tag, String)?
            if let colon = line.firstIndex(of: ":"), let t = tag(String(line[..<colon])) {
                tagged = (t, String(line[line.index(after: colon)...]).trimmed)
            }
            guard let (t, value) = tagged else {
                // Continuation of the previous field.
                guard let lastTag, !notes.isEmpty else { continue }
                add(line, as: lastTag, to: &notes[notes.count - 1])
                continue
            }
            if t == .topic {
                notes.append(TopicNote(title: clean(value), summary: ""))
            } else if !value.isEmpty {
                add(value, as: t, to: &notes[current()])
            }
            lastTag = t
        }
        return notes.filter { !$0.title.isEmpty || !$0.isEmpty }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'<>"))
    }

    private static func isNone(_ s: String) -> Bool {
        let n = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .()-*_<>"))
        return n.isEmpty || n.hasPrefix("none") || ["n/a", "na", "nothing", "no", "not discussed", "not applicable"].contains(n)
    }

    /// Splits `item | "the words it's based on"` into the item and its quote.
    static func splitQuote(_ value: String) -> (String, String?) {
        let pattern = "\\s*(?:\\||—|–|-|;)?\\s*(?:\\(?\\s*(?:quote|said|evidence)\\s*:?\\s*)?[\"“]([^\"“”]{3,})[\"”]\\s*\\)?\\s*\\.?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let whole = Range(m.range, in: value), let q = Range(m.range(at: 1), in: value) else {
            return (value, nil)
        }
        let item = String(value[..<whole.lowerBound]).trimmed
        // A sentence that is entirely a quote isn't an item with evidence.
        guard !item.isEmpty else { return (value, nil) }
        return (item, String(value[q]).trimmed)
    }

    private static func add(_ value: String, as tag: Tag, to note: inout TopicNote) {
        let (raw, quote) = [.topic, .summary, .point].contains(tag) ? (value, nil) : splitQuote(value)
        let v = clean(raw)
        guard !isNone(v) else { return }
        var key = v
        switch tag {
        case .topic: note.title = v
        case .summary: note.summary = note.summary.isEmpty ? v : note.summary + " " + v
        case .point: appendUnique(v, &note.points)
        case .decision: appendUnique(v, &note.decisions)
        case .open: appendUnique(v, &note.open)
        case .concern: appendUnique(v, &note.concerns)
        case .later: appendUnique(v, &note.later)
        case .action:
            let item = RecapParser.parseActionItem(v)
            key = item.task
            if !note.actions.contains(where: { $0.task.caseInsensitiveCompare(item.task) == .orderedSame }) {
                note.actions.append(item)
            }
        }
        if let quote { note.quotes[key.lowercased()] = quote }
    }

    static func appendUnique(_ item: String, _ list: inout [String]) {
        if !list.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) { list.append(item) }
    }

    public static func render(_ note: TopicNote, quotes: Bool = true) -> String {
        func q(_ item: String) -> String {
            guard quotes, let quote = note.quote(for: item) else { return "" }
            return " | \"\(quote)\""
        }
        var lines = ["TOPIC: \(note.title)"]
        if !note.summary.isEmpty { lines.append("SUMMARY: \(note.summary)") }
        lines += note.points.map { "POINT: \($0)" }
        lines += note.decisions.map { "DECISION: \($0)\(q($0))" }
        lines += note.actions.map { a in
            var s = "ACTION: \(a.owner ?? "Unassigned"): \(a.task)"
            if let due = a.due { s += " (due: \(due))" }
            return s + q(a.task)
        }
        lines += note.open.map { "OPEN: \($0)\(q($0))" }
        lines += note.concerns.map { "CONCERN: \($0)\(q($0))" }
        lines += note.later.map { "LATER: \($0)\(q($0))" }
        return lines.joined(separator: "\n")
    }

    public static func render(_ notes: [TopicNote], quotes: Bool = true) -> String {
        notes.map { render($0, quotes: quotes) }.joined(separator: "\n\n")
    }

    /// Drops every decision / action / question / concern whose quote (or, without one, whose
    /// wording) isn't in the transcript part the note was written from.
    public static func grounded(_ note: TopicNote, in source: Grounding.Source) -> TopicNote {
        var n = note
        func keep(_ item: String) -> Bool { Grounding.isSupported(item, quote: note.quote(for: item), in: source) }
        n.decisions = note.decisions.filter(keep)
        n.actions = note.actions.filter { keep($0.task) }
        n.open = note.open.filter(keep)
        n.concerns = note.concerns.filter(keep)
        n.later = note.later.filter(keep)
        return n
    }

    /// Combine notes without a model (fallback).
    public static func mechanicalMerge(_ notes: [TopicNote], title: String? = nil) -> TopicNote {
        var out = TopicNote(title: title ?? notes.first?.title ?? "", summary: "")
        out.summary = notes.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        for n in notes {
            n.points.forEach { appendUnique($0, &out.points) }
            out.quotes.merge(n.quotes) { a, _ in a }
            n.decisions.forEach { appendUnique($0, &out.decisions) }
            n.open.forEach { appendUnique($0, &out.open) }
            n.concerns.forEach { appendUnique($0, &out.concerns) }
            n.later.forEach { appendUnique($0, &out.later) }
            for a in n.actions where !out.actions.contains(where: { $0.task.caseInsensitiveCompare(a.task) == .orderedSame }) {
                out.actions.append(a)
            }
        }
        return out
    }

    /// Parses "1, 3, 4 = Pricing" lines into groups of 0-based indices. Every index appears exactly
    /// once; anything the model forgot becomes its own group. Groups keep meeting order.
    public static func parseGroups(_ text: String, count: Int) -> [(indices: [Int], title: String?)] {
        var seen = Set<Int>()
        var groups: [(indices: [Int], title: String?)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed.replacingRegex("^[-•*]\\s*", with: "").replacingRegex("\\*\\*", with: "")
            guard let regex = try? NSRegularExpression(pattern: "^([\\d\\s,and&]+?)\\s*(?:=|:|->|→|–|-)\\s*(.*)$", options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let numsRange = Range(m.range(at: 1), in: line) else { continue }
            let title = Range(m.range(at: 2), in: line).map { clean(String(line[$0])) }
            let indices = line[numsRange].split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }.map { $0 - 1 }
                .filter { $0 >= 0 && $0 < count && !seen.contains($0) }
            guard !indices.isEmpty else { continue }
            indices.forEach { seen.insert($0) }
            groups.append((Array(Set(indices)).sorted(), title?.isEmpty == true ? nil : title))
        }
        for i in 0..<count where !seen.contains(i) { groups.append(([i], nil)) }
        return groups.sorted { ($0.indices.first ?? 0) < ($1.indices.first ?? 0) }
    }
}
