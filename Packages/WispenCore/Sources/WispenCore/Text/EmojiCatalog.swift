import Foundation

/// Every standard emoji, in the order and groups the system keyboard uses.
/// From Unicode's emoji-test.txt (Emoji 15.1, Unicode License v3), without skin-tone variants.
public final class EmojiCatalog: @unchecked Sendable {
    public static let shared = EmojiCatalog(resource: "emoji")

    public struct Emoji: Hashable, Sendable {
        public let character: String
        public let name: String
    }

    public struct Group: Identifiable, Sendable {
        public let name: String
        public let emoji: [Emoji]
        public var id: String { name }

        /// SF Symbol for the group's tab.
        public var symbol: String {
            switch name {
            case "Smileys & Emotion": return "face.smiling"
            case "People & Body": return "hand.wave"
            case "Animals & Nature": return "leaf"
            case "Food & Drink": return "fork.knife"
            case "Travel & Places": return "car"
            case "Activities": return "soccerball"
            case "Objects": return "lightbulb"
            case "Symbols": return "heart"
            case "Flags": return "flag"
            default: return "circle"
            }
        }
    }

    public let groups: [Group]

    public init(text: String) {
        var groups: [Group] = []
        var name: String?
        var emoji: [Emoji] = []
        func flush() {
            if let name, !emoji.isEmpty { groups.append(Group(name: name, emoji: emoji)) }
            emoji = []
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("@") {
                flush()
                name = String(line.dropFirst())
            } else {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard let c = parts.first else { continue }
                emoji.append(Emoji(character: String(c), name: parts.count > 1 ? String(parts[1]) : ""))
            }
        }
        flush()
        self.groups = groups
    }

    convenience init(resource: String) {
        let url = Bundle.module.url(forResource: resource, withExtension: "txt")
        self.init(text: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }

    public var count: Int { groups.reduce(0) { $0 + $1.emoji.count } }

    /// Recently used emoji, newest first, capped at `limit`.
    public static func recordUse(_ emoji: String, in recents: [String], limit: Int = 30) -> [String] {
        Array(([emoji] + recents.filter { $0 != emoji }).prefix(limit))
    }
}
