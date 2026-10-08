import Foundation

/// Parses the heading/bullet format the prompts ask for, tolerating the usual small-model drift
/// (markdown headings, bold, numbering, "None" placeholders, missing sections).
public enum RecapParser {
    enum Section: CaseIterable {
        case title, summary, keyPoints, decisions, actionItems, openQuestions, risks, followUps

        var aliases: [String] {
            switch self {
            case .title: return ["title", "meeting title"]
            case .summary: return ["summary", "overview", "tldr", "tl;dr"]
            case .keyPoints: return ["key points", "key discussion points", "discussion points", "highlights", "main points"]
            case .decisions: return ["decisions", "decisions made", "key decisions"]
            case .actionItems: return ["action items", "actions", "next steps", "tasks", "to-dos", "todos"]
            case .openQuestions: return ["open questions", "questions", "unresolved questions", "unresolved"]
            case .risks: return ["risks", "risks and concerns", "concerns", "blockers", "risks / concerns"]
            case .followUps: return ["follow-ups", "follow ups", "followups", "follow-up", "revisit", "for next time"]
            }
        }
    }

    public static func parse(_ text: String) -> MeetingRecap {
        var recap = MeetingRecap()
        var current: Section?
        var summaryLines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmed
            if line.isEmpty { continue }
            line = line.replacingRegex("^#+\\s*", with: "").replacingRegex("\\*\\*", with: "")

            if let (section, inline) = heading(in: line) {
                current = section
                if let inline, !inline.isEmpty { add(inline, to: section, recap: &recap, summary: &summaryLines) }
                continue
            }
            guard let section = current else { continue }
            add(line, to: section, recap: &recap, summary: &summaryLines)
        }
        recap.summary = summaryLines.joined(separator: " ").trimmed
        return recap
    }

    private static func heading(in line: String) -> (Section, String?)? {
        let lower = line.lowercased()
        for section in Section.allCases {
            for alias in section.aliases {
                guard lower.hasPrefix(alias) else { continue }
                let rest = line.dropFirst(alias.count)
                let trimmedRest = rest.trimmingCharacters(in: .whitespaces)
                if trimmedRest.isEmpty { return (section, nil) }
                if trimmedRest.hasPrefix(":") {
                    return (section, String(trimmedRest.dropFirst()).trimmed)
                }
            }
        }
        return nil
    }

    private static func isNone(_ s: String) -> Bool {
        let n = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .()-*_"))
        return ["none", "n/a", "na", "nothing", "none mentioned", "none noted", "no action items", "not discussed",
                "none identified", "none discussed", "none stated", "none in this part"].contains(n)
    }

    private static func bulletText(_ line: String) -> String {
        line.replacingRegex("^(?:[-•*▪︎◦]|\\d+[.)]|\\[[ xX]?\\])\\s*", with: "").trimmed
    }

    private static func add(_ line: String, to section: Section, recap: inout MeetingRecap, summary: inout [String]) {
        let item = bulletText(line)
        guard !item.isEmpty, !isNone(item), !item.hasPrefix("<") else { return }
        switch section {
        case .title: if recap.title.isEmpty { recap.title = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        case .summary: summary.append(item)
        case .keyPoints: appendUnique(item, to: &recap.keyPoints)
        case .decisions: appendUnique(item, to: &recap.decisions)
        case .openQuestions: appendUnique(item, to: &recap.openQuestions)
        case .risks: appendUnique(item, to: &recap.risks)
        case .followUps: appendUnique(item, to: &recap.followUps)
        case .actionItems:
            let parsed = parseActionItem(item)
            if !recap.actionItems.contains(where: { $0.task.lowercased() == parsed.task.lowercased() }) {
                recap.actionItems.append(parsed)
            }
        }
    }

    private static func appendUnique(_ item: String, to list: inout [String]) {
        if !list.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) { list.append(item) }
    }

    static func parseActionItem(_ item: String) -> ActionItem {
        var text = item
        var due: String?
        if let regex = try? NSRegularExpression(pattern: "\\s*\\((?:due|by|deadline)\\s*:?\\s*([^)]+)\\)\\s*$", options: [.caseInsensitive]),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text), let d = Range(m.range(at: 1), in: text) {
            due = String(text[d]).trimmed
            text.removeSubrange(whole)
        }
        if let d = due, isNone(d) || ["tbd", "unknown", "not specified", "none given"].contains(d.lowercased()) { due = nil }

        var owner: String?
        if let regex = try? NSRegularExpression(pattern: "^\\[?([^:\\]]{1,40}?)\\]?\\s*:\\s+(.+)$", options: []),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let o = Range(m.range(at: 1), in: text), let t = Range(m.range(at: 2), in: text) {
            let candidate = String(text[o]).trimmed
            // Owners are short names, not sentences.
            if candidate.wordCount <= 4 {
                owner = candidate
                text = String(text[t])
            }
        }
        if let o = owner, ["unassigned", "tbd", "none", "unknown", "owner", "n/a", "team", "everyone"].contains(o.lowercased()) {
            owner = o.lowercased() == "team" || o.lowercased() == "everyone" ? o : nil
        }
        return ActionItem(task: text.trimmed, owner: owner, due: due)
    }

    /// Back to the text format (used to feed partial notes into the merge step).
    public static func render(_ recap: MeetingRecap, includeTitle: Bool = true) -> String {
        var lines: [String] = []
        if includeTitle, !recap.title.isEmpty { lines.append("TITLE: \(recap.title)") }
        if !recap.summary.isEmpty { lines.append("SUMMARY: \(recap.summary)") }
        func list(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\(heading):")
            lines.append(contentsOf: items.map { "- \($0)" })
        }
        list("KEY POINTS", recap.keyPoints)
        list("DECISIONS", recap.decisions)
        list("ACTION ITEMS", recap.actionItems.map { item in
            var s = "\(item.owner ?? "Unassigned"): \(item.task)"
            if let due = item.due { s += " (due: \(due))" }
            return s
        })
        list("OPEN QUESTIONS", recap.openQuestions)
        list("RISKS", recap.risks)
        list("FOLLOW-UPS", recap.followUps)
        return lines.joined(separator: "\n")
    }

    /// Mechanical merge used when the model can't do the final merge.
    public static func mechanicalMerge(_ parts: [MeetingRecap]) -> MeetingRecap {
        var out = MeetingRecap()
        out.title = parts.first(where: { !$0.title.isEmpty })?.title ?? ""
        out.summary = parts.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        for p in parts {
            p.keyPoints.forEach { appendUnique($0, to: &out.keyPoints) }
            p.decisions.forEach { appendUnique($0, to: &out.decisions) }
            p.openQuestions.forEach { appendUnique($0, to: &out.openQuestions) }
            p.risks.forEach { appendUnique($0, to: &out.risks) }
            p.followUps.forEach { appendUnique($0, to: &out.followUps) }
            for a in p.actionItems where !out.actionItems.contains(where: { $0.task.lowercased() == a.task.lowercased() }) {
                out.actionItems.append(a)
            }
        }
        return out
    }
}

public extension MeetingRecap {
    /// Shareable Markdown (Notes, email, Slack…).
    func markdown(date: Date? = nil, duration: Double? = nil) -> String {
        var s = "# \(title.isEmpty ? "Meeting recap" : title)\n"
        var meta: [String] = []
        if let date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            meta.append(f.string(from: date))
        }
        if let duration, duration > 0 { meta.append("\(Int((duration / 60).rounded())) min") }
        if !meta.isEmpty { s += "_\(meta.joined(separator: " · "))_\n" }
        if !summary.isEmpty { s += "\n\(summary)\n" }
        func section(_ name: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            s += "\n## \(name)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        section("Key points", keyPoints)
        if !topics.isEmpty {
            s += "\n## Topics discussed\n"
            for t in topics { s += "- **\(t.title)**: \(t.summary)\n" }
        }
        section("Decisions", decisions)
        if !actionItems.isEmpty {
            s += "\n## Action items\n"
            for a in actionItems {
                var line = "- [\(a.done ? "x" : " ")] "
                if let o = a.owner { line += "**\(o)**: " }
                line += a.task
                if let d = a.due { line += " _(due \(d))_" }
                s += line + "\n"
            }
        }
        section("Open questions", openQuestions)
        section("Risks & concerns", risks)
        section("Follow-ups", followUps)
        return s
    }
}
