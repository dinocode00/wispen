import Foundation

/// Notes about one subject of a meeting: the unit the recap pipeline works in.
///
/// Organizing by subject (instead of sorting each transcript chunk straight into recap sections)
/// is what lets the recap "connect the dots": a question raised early and answered later is
/// resolved when the subject's notes are merged, and each section is written from whole subjects.
public struct TopicNote: Sendable, Equatable {
    public var title: String
    public var summary: String
    public var decisions: [String] = []
    public var actions: [ActionItem] = []
    public var open: [String] = []
    public var concerns: [String] = []
    public var later: [String] = []

    public init(title: String, summary: String, decisions: [String] = [], actions: [ActionItem] = [],
                open: [String] = [], concerns: [String] = [], later: [String] = []) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.open = open
        self.concerns = concerns
        self.later = later
    }

    var isEmpty: Bool { summary.isEmpty && decisions.isEmpty && actions.isEmpty && open.isEmpty && concerns.isEmpty }
}

public enum TopicNotesParser {
    private enum Tag { case topic, summary, decision, action, open, concern, later }

    private static func tag(_ word: String) -> Tag? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "topic", "subject", "title": return .topic
        case "summary", "discussion": return .summary
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

    private static func add(_ value: String, as tag: Tag, to note: inout TopicNote) {
        let v = clean(value)
        guard !isNone(v) else { return }
        switch tag {
        case .topic: note.title = v
        case .summary: note.summary = note.summary.isEmpty ? v : note.summary + " " + v
        case .decision: appendUnique(v, &note.decisions)
        case .open: appendUnique(v, &note.open)
        case .concern: appendUnique(v, &note.concerns)
        case .later: appendUnique(v, &note.later)
        case .action:
            let item = RecapParser.parseActionItem(v)
            if !note.actions.contains(where: { $0.task.caseInsensitiveCompare(item.task) == .orderedSame }) {
                note.actions.append(item)
            }
        }
    }

    static func appendUnique(_ item: String, _ list: inout [String]) {
        if !list.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) { list.append(item) }
    }

    public static func render(_ note: TopicNote) -> String {
        var lines = ["TOPIC: \(note.title)"]
        if !note.summary.isEmpty { lines.append("SUMMARY: \(note.summary)") }
        lines += note.decisions.map { "DECISION: \($0)" }
        lines += note.actions.map { a in
            var s = "ACTION: \(a.owner ?? "Unassigned"): \(a.task)"
            if let due = a.due { s += " (due: \(due))" }
            return s
        }
        lines += note.open.map { "OPEN: \($0)" }
        lines += note.concerns.map { "CONCERN: \($0)" }
        lines += note.later.map { "LATER: \($0)" }
        return lines.joined(separator: "\n")
    }

    public static func render(_ notes: [TopicNote]) -> String {
        notes.map(render).joined(separator: "\n\n")
    }

    /// Combine notes without a model (fallback).
    public static func mechanicalMerge(_ notes: [TopicNote], title: String? = nil) -> TopicNote {
        var out = TopicNote(title: title ?? notes.first?.title ?? "", summary: "")
        out.summary = notes.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        for n in notes {
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
