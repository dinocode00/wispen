import Foundation

/// How eagerly the Wispen keyboard fixes typos.
public enum AutocorrectStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, gentle, balanced, strong

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    public var detail: String {
        switch self {
        case .off: return "Never changes what you type."
        case .gentle: return "Only obvious one-letter slips in longer words."
        case .balanced: return "Fixes most fast-typing slips, short words, contractions and missing spaces."
        case .strong: return "Fixes anything close to a common word. Backspace undoes it."
        }
    }
}

/// Common English words, most frequent first (OpenSubtitles frequencies, FrequencyWords project, MIT).
public final class WordList: @unchecked Sendable {
    public static let english = WordList(resource: "en_words")

    struct Entry {
        let text: String
        let chars: [UInt8]
        let rank: Int
    }

    private let ranks: [String: Int]
    /// Words grouped by length, in frequency order.
    private let byLength: [Int: [Entry]]

    public init(words: [String]) {
        var ranks: [String: Int] = [:]
        var byLength: [Int: [Entry]] = [:]
        for (i, w) in words.enumerated() where ranks[w] == nil {
            ranks[w] = i
            byLength[w.count, default: []].append(Entry(text: w, chars: KeyGeometry.codes(w), rank: i))
        }
        self.ranks = ranks
        self.byLength = byLength
    }

    convenience init(resource: String) {
        let url = Bundle.module.url(forResource: resource, withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        self.init(words: text.split(separator: "\n").map(String.init))
    }

    public var count: Int { ranks.count }

    /// 0 for the most common word; nil if it isn't in the list.
    public func rank(of word: String) -> Int? { ranks[word.lowercased()] }

    func entries(ofLength n: Int) -> [Entry] { byLength[n] ?? [] }
    func allEntries() -> [Entry] { byLength.values.flatMap { $0 } }
}

/// Where each letter sits on the QWERTY keyboard, in key widths. Letters are coded 0–25 (other
/// characters 255) so costs are table lookups.
enum KeyGeometry {
    static let other: UInt8 = 255

    static func code(_ c: Character) -> UInt8 {
        guard let a = c.asciiValue, a >= 97, a <= 122 else { return other }
        return a - 97
    }

    static func codes(_ s: String) -> [UInt8] { s.map(code) }

    /// distance[a * 26 + b] between letter keys.
    private static let distances: [Double] = {
        var pos = [(Double, Double)](repeating: (0, 0), count: 26)
        for (row, (letters, offset)) in [("qwertyuiop", 0.0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5)].enumerated() {
            for (i, c) in letters.enumerated() { pos[Int(code(c))] = (Double(i) + offset, Double(row)) }
        }
        var d = [Double](repeating: 0, count: 26 * 26)
        for a in 0..<26 {
            for b in 0..<26 {
                let dx = pos[a].0 - pos[b].0, dy = pos[a].1 - pos[b].1
                d[a * 26 + b] = (dx * dx + dy * dy).squareRoot()
            }
        }
        return d
    }()

    static func distance(_ a: UInt8, _ b: UInt8) -> Double? {
        guard a < 26, b < 26 else { return nil }
        return distances[Int(a) * 26 + Int(b)]
    }

    static func areNeighbors(_ a: UInt8, _ b: UInt8) -> Bool {
        guard let d = distance(a, b) else { return false }
        return d > 0 && d < 1.2
    }
}

/// Fixes fast-typing slips the way phone keyboards do: by how likely each slip is on a QWERTY
/// keyboard (neighbouring keys, swapped or doubled letters, a missed key) and how common each
/// candidate word is.
public struct Autocorrector: Sendable {
    public var strength: AutocorrectStrength
    public var words: WordList

    public init(strength: AutocorrectStrength, words: WordList = .english) {
        self.strength = strength
        self.words = words
    }

    /// Unambiguous contractions and fixes, applied at any strength except Off.
    static let fixed: [String: String] = [
        "i": "I", "im": "I'm", "ive": "I've", "i'm": "I'm", "i've": "I've", "i'll": "I'll", "i'd": "I'd",
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
        "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
        "couldnt": "couldn't", "wouldnt": "wouldn't", "shouldnt": "shouldn't", "mustnt": "mustn't",
        "youre": "you're", "youve": "you've", "youll": "you'll", "youd": "you'd",
        "theyre": "they're", "theyve": "they've", "theyll": "they'll", "theyd": "they'd", "weve": "we've",
        "thats": "that's", "whats": "what's", "wheres": "where's", "theres": "there's", "heres": "here's",
        "whos": "who's", "hows": "how's", "aint": "ain't", "yall": "y'all", "hes": "he's", "shes": "she's",
        "itll": "it'll", "thatll": "that'll", "teh": "the", "adn": "and", "hte": "the",
    ]
    /// Real words too, so only corrected from Balanced up.
    static let fixedBalanced: [String: String] = ["cant": "can't", "wont": "won't"]

    /// The fix for `typed`, or nil to leave it alone.
    /// - Parameters:
    ///   - systemKnows: the iOS spell checker accepts the word.
    ///   - protected: your dictionary words and words you've taught the keyboard (never corrected).
    ///   - extraCandidates: more spellings to consider (the iOS spell checker's guesses).
    public func correction(for typed: String, systemKnows: Bool = false, protected: Set<String> = [],
                           extraCandidates: [String] = []) -> String? {
        guard strength != .off, !typed.isEmpty, typed.count < 30 else { return nil }
        guard typed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        let letters = typed.filter(\.isLetter)
        // ACRONYMS and names in caps stay as typed (but "I" is fine).
        if letters.count > 1, letters == letters.uppercased() { return nil }
        let lower = typed.lowercased().replacingOccurrences(of: "’", with: "'")
        if protected.contains(lower) { return nil }

        if let fix = Self.fixed[lower] ?? (strength != .gentle ? Self.fixedBalanced[lower] : nil) {
            return fix == typed ? nil : KeyboardTextLogic.matchCase(fix, to: typed, keepCapitalI: true)
        }
        if lower.contains("'") || isKnown(lower, systemKnows: systemKnows) { return nil }

        let n = lower.count
        guard n >= (strength == .gentle ? 4 : 2) else { return nil }

        var scored = ranked(lower, extraCandidates: extraCandidates)
        // A rare real word competes as itself: only a clearly more likely word replaces it.
        if let rank = words.rank(of: lower) {
            scored.removeAll { $0.word == lower }
            scored.append((lower, 0, Self.rarityPenalty(rank: rank)))
            scored.sort { $0.score < $1.score }
        }

        // Two words run together ("thisis" → "this is", "iam" → "I am").
        if strength != .gentle, n >= 3, let split = bestSplit(lower), split.score < (scored.first?.score ?? .infinity) {
            return KeyboardTextLogic.matchCase(split.text, to: typed, keepCapitalI: true)
        }

        guard let best = scored.first, best.word != lower else { return nil }
        if scored.count > 1, scored[1].score - best.score < minMargin { return nil }
        return KeyboardTextLogic.matchCase(best.word, to: typed, keepCapitalI: true)
    }

    /// Candidate fixes for a lowercase word, best first.
    func ranked(_ lower: String, extraCandidates: [String] = []) -> [(word: String, cost: Double, score: Double)] {
        let typedChars = KeyGeometry.codes(lower)
        let n = typedChars.count
        var scored: [(word: String, cost: Double, score: Double)] = []
        let maxCost = maxCost(forLength: n)
        func consider(_ word: String, _ chars: [UInt8], rank: Int) {
            let c = Self.cost(typed: typedChars, candidate: chars, limit: maxCost)
            guard c <= maxCost else { return }
            scored.append((word, c, c + Self.rarityPenalty(rank: rank)))
        }
        // A fast-typing slip almost never changes the first letter to a far-away key, so only words
        // starting near what was typed are scored (keeps this well under a millisecond on a phone).
        let t0 = typedChars[0], t1 = n > 1 ? typedChars[1] : t0
        func plausibleStart(_ c: [UInt8]) -> Bool {
            let c0 = c[0]
            return c0 == t0 || c0 == t1 || KeyGeometry.areNeighbors(c0, t0) || (c.count > 1 && c[1] == t0)
        }
        let spread = n <= 4 ? 1 : 2
        for len in max(1, n - spread)...(n + spread) {
            for e in words.entries(ofLength: len) {
                // Skip rare words for very short input: "ot" shouldn't become "oti".
                if n <= 3, e.rank > 8000 { break }
                guard plausibleStart(e.chars) else { continue }
                consider(e.text, e.chars, rank: e.rank)
            }
        }
        for guess in extraCandidates {
            let g = guess.lowercased()
            guard !g.contains(" "), !g.contains("-"), g != lower, !scored.contains(where: { $0.word == g }) else { continue }
            consider(g, KeyGeometry.codes(g), rank: words.rank(of: g) ?? 25000)
        }
        return scored.sorted { $0.score < $1.score }
    }

    /// A word the keyboard shouldn't change.
    func isKnown(_ lower: String, systemKnows: Bool) -> Bool {
        let n = lower.count
        if let rank = words.rank(of: lower) {
            // Very short "words" deep in the list are mostly noise ("ot", "fo").
            let limit = n <= 2 ? 1500 : (n == 3 ? 8000 : (n == 4 ? 15000 : 25000))
            if rank < limit { return true }
        }
        return systemKnows && n >= 4
    }

    private func maxCost(forLength n: Int) -> Double {
        switch strength {
        case .off: return 0
        case .gentle: return n <= 5 ? 0.6 : (n <= 8 ? 1.0 : 1.5)
        case .balanced: return n <= 3 ? 0.75 : (n <= 5 ? 1.2 : (n <= 8 ? 1.8 : 2.4))
        case .strong: return n <= 3 ? 1.0 : (n <= 5 ? 1.7 : (n <= 8 ? 2.5 : 3.2))
        }
    }

    /// How clearly the best fix must beat the runner-up.
    private var minMargin: Double {
        switch strength {
        case .off: return .infinity
        case .gentle: return 0.5
        case .balanced: return 0.12
        case .strong: return 0.04
        }
    }

    /// Common words cost less: the 1st word ≈ 0.3, the 1,000th ≈ 0.8, the 30,000th ≈ 1.2.
    static func rarityPenalty(rank: Int) -> Double { 0.12 * log(Double(rank) + 10) }

    /// The most likely way to split a word into two common words, scored like a correction.
    private func bestSplit(_ s: String) -> (text: String, score: Double)? {
        let chars = Array(s)
        var best: (text: String, score: Double)?
        for i in 1..<chars.count {
            let a = String(chars[..<i]), b = String(chars[i...])
            guard let ra = splitRank(a), let rb = splitRank(b) else { continue }
            let score = 0.5 + Self.rarityPenalty(rank: max(ra, rb))
            if score < (best?.score ?? .infinity) { best = ((a == "i" ? "I" : a) + " " + b, score) }
        }
        return best
    }

    private func splitRank(_ w: String) -> Int? {
        if w == "i" { return 0 }
        guard w.count >= 2 || w == "a", let r = words.rank(of: w), r < 5000 else { return nil }
        return r
    }

    /// Weighted Damerau–Levenshtein distance between what was typed and a candidate word, with
    /// QWERTY-aware costs. Returns early once it's certain to exceed `limit`.
    static func cost(typed t: [UInt8], candidate c: [UInt8], limit: Double = .infinity) -> Double {
        let n = t.count, m = c.count
        if abs(n - m) > 2 { return .infinity }
        let w = m + 1
        var d = [Double](repeating: 0, count: (n + 1) * w)
        if n > 0 { for i in 1...n { d[i * w] = d[(i - 1) * w] + extraCost(t, i - 1) } }
        if m > 0 { for j in 1...m { d[j] = d[j - 1] + missingCost(c, j - 1) } }
        guard n > 0, m > 0 else { return d[n * w + m] }
        for i in 1...n {
            var rowMin = Double.infinity
            let extra = extraCost(t, i - 1)
            for j in 1...m {
                var v = min(d[(i - 1) * w + j] + extra,
                            d[i * w + j - 1] + missingCost(c, j - 1),
                            d[(i - 1) * w + j - 1] + substitutionCost(t[i - 1], c[j - 1], position: j - 1))
                if i > 1, j > 1, t[i - 1] == c[j - 2], t[i - 2] == c[j - 1], t[i - 1] != t[i - 2] {
                    v = min(v, d[(i - 2) * w + j - 2] + 0.4) // swapped letters ("teh")
                }
                d[i * w + j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return .infinity }
        }
        return d[n * w + m]
    }

    /// Hitting a key you didn't mean.
    static func substitutionCost(_ a: UInt8, _ b: UInt8, position: Int) -> Double {
        if a == b { return 0 }
        // The first letter is rarely wrong.
        let first = position == 0 ? 0.25 : 0
        if KeyGeometry.areNeighbors(a, b) { return 0.45 + first }
        if let d = KeyGeometry.distance(a, b), d < 2.3 { return 0.85 + first }
        return 1.0 + first
    }

    /// An extra letter in what was typed (a double press, or brushing a neighbouring key).
    static func extraCost(_ t: [UInt8], _ i: Int) -> Double {
        let ch = t[i]
        if i > 0, t[i - 1] == ch { return 0.4 }
        if i > 0, KeyGeometry.areNeighbors(t[i - 1], ch) { return 0.55 }
        if i + 1 < t.count, KeyGeometry.areNeighbors(t[i + 1], ch) { return 0.55 }
        return 0.9
    }

    /// A letter missing from what was typed (often one half of a double letter).
    static func missingCost(_ c: [UInt8], _ j: Int) -> Double {
        if j > 0, c[j - 1] == c[j] { return 0.4 }
        return 0.7
    }
}
