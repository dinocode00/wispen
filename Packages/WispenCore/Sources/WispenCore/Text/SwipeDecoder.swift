import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Swipeable words, grouped by the keys a swipe must start and end on.
public final class SwipeIndex: @unchecked Sendable {
    public static let english = SwipeIndex(words: .english)

    struct Entry {
        let text: String
        /// Letter codes with repeats collapsed ("hello" → h e l o): a swipe can't show a double letter.
        let keys: [UInt8]
        let rank: Int
    }

    private var entries: [Entry] = []
    /// Entry indexes by first key * 26 + last key, most common first.
    private var buckets: [Int: [Int32]] = [:]

    init(words: WordList) {
        var seen: Set<String> = []
        for e in words.allEntries() { add(e.text, rank: e.rank, seen: &seen) }
        // Swiping "dont" means "don't" (the word list has no apostrophes).
        let contractions = Autocorrector.fixed.merging(Autocorrector.fixedBalanced) { a, _ in a }
        for (typed, word) in contractions where word.contains("'") {
            add(word, keysFrom: typed, rank: 150, seen: &seen)
        }
        for i in buckets.keys { buckets[i]!.sort { entries[Int($0)].rank < entries[Int($1)].rank } }
    }

    private func add(_ text: String, keysFrom typed: String? = nil, rank: Int, seen: inout Set<String>) {
        guard let keys = Self.keys(typed ?? text), seen.insert(text).inserted else { return }
        buckets[Int(keys[0]) * 26 + Int(keys[keys.count - 1]), default: []].append(Int32(entries.count))
        entries.append(Entry(text: text, keys: keys, rank: rank))
    }

    /// Collapsed letter codes, or nil if the word can't be swiped (non-letters, or a single key).
    static func keys(_ word: String) -> [UInt8]? {
        var out: [UInt8] = []
        for c in KeyGeometry.codes(word.lowercased()) {
            guard c < 26 else { return nil }
            if out.last != c { out.append(c) }
        }
        return out.count >= 2 ? out : nil
    }

    func bucket(first: UInt8, last: UInt8) -> [Int32] { buckets[Int(first) * 26 + Int(last)] ?? [] }
    func entry(_ i: Int32) -> Entry { entries[Int(i)] }
}

/// Turns a finger's path across the letter keys into the words it most likely spells
/// ("gesture typing", like the system keyboard's swipe).
///
/// Each candidate word has an ideal path through its letters' key centers. A word scores well when
/// the swipe starts and ends on its first and last keys, passes near each of its letters in order,
/// and follows the same route; common words get a small head start. Only words starting and ending
/// near the swipe's ends are compared, so a guess takes a millisecond or two.
public struct SwipeDecoder: Sendable {
    struct P {
        var x: Double, y: Double
        func distance(to o: P) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
    }

    /// Letter key centers, in key units (one key is 1 × 1).
    private let centers: [P]
    private let unit: CGSize
    private let index: SwipeIndex

    /// - Parameters:
    ///   - keyCenters: where each letter key's center is on screen.
    ///   - keySize: the distance from one key to the next, across and down.
    public init?(keyCenters: [Character: CGPoint], keySize: CGSize, index: SwipeIndex = .english) {
        guard keySize.width > 0, keySize.height > 0 else { return nil }
        var centers = [P](repeating: P(x: 0, y: 0), count: 26)
        var found = 0
        for (c, p) in keyCenters {
            let code = KeyGeometry.code(Character(c.lowercased()))
            guard code < 26 else { continue }
            centers[Int(code)] = P(x: Double(p.x / keySize.width), y: Double(p.y / keySize.height))
            found += 1
        }
        guard found == 26 else { return nil }
        self.centers = centers
        self.unit = keySize
        self.index = index
    }

    /// How far (in keys) the finger must travel before a touch counts as a swipe rather than a tap.
    public static let swipeThreshold = 0.8

    /// The likeliest words for `path` (screen points, in order), best first.
    /// `extraWords`: your dictionary and learned words, offered like fairly common words.
    public func candidates(for path: [CGPoint], extraWords: [String] = [], limit: Int = 4) -> [String] {
        let points = path.map { P(x: Double($0.x / unit.width), y: Double($0.y / unit.height)) }
        guard points.count >= 2 else { return [] }
        let length = Self.length(points)
        guard length >= 0.6 else { return [] }

        let samples = Self.resample(points, count: Self.sampleCount)
        let start = points[0], end = points[points.count - 1]
        let starts = nearestKeys(to: start), ends = nearestKeys(to: end)

        var scored: [(text: String, score: Double)] = []
        func consider(_ text: String, keys: [UInt8], rank: Int) {
            guard let s = score(keys: keys, rank: rank, samples: samples, length: length, start: start, end: end)
            else { return }
            scored.append((text, s))
        }
        for s in starts {
            for e in ends {
                for i in index.bucket(first: s, last: e) {
                    let entry = index.entry(i)
                    consider(entry.text, keys: entry.keys, rank: entry.rank)
                }
            }
        }
        for word in extraWords {
            guard let keys = SwipeIndex.keys(word), starts.contains(keys[0]), ends.contains(keys[keys.count - 1])
            else { continue }
            consider(word, keys: keys, rank: 1500)
        }

        scored.sort { $0.score < $1.score }
        var out: [String] = []
        var seen: Set<String> = []
        for s in scored where seen.insert(s.text.lowercased()).inserted {
            out.append(s.text)
            if out.count == limit { break }
        }
        return out
    }

    static let sampleCount = 48

    /// Letter keys near a point, nearest first.
    private func nearestKeys(to p: P) -> [UInt8] {
        var near: [(UInt8, Double)] = []
        for (i, c) in centers.enumerated() {
            let d = c.distance(to: p)
            if d < 1.15 { near.append((UInt8(i), d)) }
        }
        near.sort { $0.1 < $1.1 }
        return near.prefix(4).map(\.0)
    }

    /// Lower is better; nil if the swipe can't be this word.
    private func score(keys: [UInt8], rank: Int, samples: [P], length: Double, start: P, end: P) -> Double? {
        let route = keys.map { centers[Int($0)] }
        let ideal = Self.length(route)
        // A swipe much shorter than the word's route skipped some letters.
        if ideal > length * 1.5 + 1 { return nil }
        // …and one much longer went somewhere else.
        if length > ideal * 2.2 + 2 { return nil }

        // Every letter must be passed near, in order.
        var at = 0
        for c in route {
            var hit = false
            while at < samples.count {
                if samples[at].distance(to: c) <= 1.1 { hit = true; break }
                at += 1
            }
            if !hit { return nil }
        }

        let template = Self.resample(route, count: Self.sampleCount)
        var location = 0.0
        for i in 0..<Self.sampleCount { location += samples[i].distance(to: template[i]) }
        location /= Double(Self.sampleCount)

        let ends = start.distance(to: route[0]) + end.distance(to: route[route.count - 1])
        return location + 0.5 * ends + 0.08 * log(Double(rank + 10))
    }

    static func length(_ points: [P]) -> Double {
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }

    /// `count` points spaced evenly along the path.
    static func resample(_ points: [P], count: Int) -> [P] {
        let total = length(points)
        guard total > 0 else { return [P](repeating: points[0], count: count) }
        let step = total / Double(count - 1)
        var out = [points[0]]
        out.reserveCapacity(count)
        var carried = 0.0
        var prev = points[0]
        var i = 1
        while i < points.count, out.count < count {
            let next = points[i]
            let d = prev.distance(to: next)
            if d > 0, carried + d >= step {
                let t = (step - carried) / d
                let p = P(x: prev.x + t * (next.x - prev.x), y: prev.y + t * (next.y - prev.y))
                out.append(p)
                prev = p
                carried = 0
            } else {
                carried += d
                prev = next
                i += 1
            }
        }
        while out.count < count { out.append(points[points.count - 1]) }
        return out
    }
}
