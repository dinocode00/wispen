import Foundation
import XCTest
@testable import WispenCore

final class SwipeDecoderTests: XCTestCase {
    /// An iPhone-sized QWERTY layout: 39pt keys, 54pt rows; the middle row is inset half a key, the
    /// bottom row starts after shift.
    static let keySize = CGSize(width: 39.3, height: 54)
    static let centers: [Character: CGPoint] = {
        var out: [Character: CGPoint] = [:]
        for (row, (letters, offset)) in [("qwertyuiop", 0.0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5)].enumerated() {
            for (i, c) in letters.enumerated() {
                out[c] = CGPoint(x: (Double(i) + offset + 0.5) * keySize.width, y: (Double(row) + 0.5) * keySize.height)
            }
        }
        return out
    }()

    private let decoder = SwipeDecoder(keyCenters: SwipeDecoderTests.centers, keySize: SwipeDecoderTests.keySize)!

    /// Deterministic noise, so failures reproduce.
    struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func normal() -> Double {
            let u = max(next(), 1e-9), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// A human-like swipe: each letter's key is hit off-center by `wobble` keys (std dev), the
    /// corners are rounded off, and points arrive every few points like touch events.
    static func swipe(_ word: String, wobble: Double, rng: inout RNG) -> [CGPoint] {
        var anchors: [CGPoint] = []
        for c in word {
            let p = centers[c]!
            if let last = anchors.last, last == p { continue }
            anchors.append(CGPoint(x: p.x + rng.normal() * wobble * keySize.width,
                                   y: p.y + rng.normal() * wobble * keySize.height))
        }
        if anchors.count == 1 { anchors.append(anchors[0]) }
        // Fingers round off each corner by about a third of a key.
        var pts = [anchors[0]]
        for i in 1..<anchors.count {
            let a = anchors[i - 1], b = anchors[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard i < anchors.count - 1, len > 0 else { pts.append(b); continue }
            let c = anchors[i + 1]
            let len2 = hypot(c.x - b.x, c.y - b.y)
            let cut = min(0.35 * keySize.width, 0.4 * len, 0.4 * max(len2, 0.01))
            pts.append(CGPoint(x: b.x - (b.x - a.x) / len * cut, y: b.y - (b.y - a.y) / len * cut))
            if len2 > 0 { pts.append(CGPoint(x: b.x + (c.x - b.x) / len2 * cut, y: b.y + (c.y - b.y) / len2 * cut)) }
        }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 6))
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                out.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    func testCleanSwipesOfEverydayWords() {
        var rng = RNG(state: 1)
        var failures: [String] = []
        for w in ["hello", "the", "and", "you", "thanks", "meeting", "tomorrow", "because", "keyboard", "about",
                  "great", "people", "really", "work", "please", "what", "good", "time", "know", "love"] {
            let got = decoder.candidates(for: Self.swipe(w, wobble: 0, rng: &rng)).first
            if got != w { failures.append("\(w) → \(got ?? "nil")") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
    }

    func testSloppySwipesOfCommonWords() {
        var rng = RNG(state: 42)
        let words = WordList.english.allEntries().filter { $0.rank < 600 && SwipeIndex.keys($0.text) != nil }
            .sorted { $0.rank < $1.rank }.map(\.text)
        var top1 = 0, top4 = 0
        var misses: [String] = []
        for w in words {
            let got = decoder.candidates(for: Self.swipe(w, wobble: 0.22, rng: &rng))
            if got.first == w { top1 += 1 } else if misses.count < 40 { misses.append("\(w)→\(got.first ?? "nil")") }
            if got.contains(w) { top4 += 1 }
        }
        let n = Double(words.count)
        print("swipe accuracy: top-1 \(Double(top1) / n), top-4 \(Double(top4) / n) over \(words.count); misses: \(misses.joined(separator: " "))")
        // Some swipes are truly ambiguous ("to"/"too", "for"/"four"): the suggestion bar offers the others.
        XCTAssertGreaterThan(Double(top1) / n, 0.85)
        XCTAssertGreaterThan(Double(top4) / n, 0.97)
    }

    func testContractionsAndYourOwnWords() {
        var rng = RNG(state: 7)
        XCTAssertEqual(decoder.candidates(for: Self.swipe("dont", wobble: 0, rng: &rng)).first, "don't")
        XCTAssertEqual(decoder.candidates(for: Self.swipe("wispen", wobble: 0, rng: &rng), extraWords: ["Wispen"]).first, "Wispen")
    }

    func testTapLikeMovementGivesNothing() {
        let c = Self.centers["g"]!
        XCTAssertTrue(decoder.candidates(for: [c, CGPoint(x: c.x + 5, y: c.y)]).isEmpty)
    }

    func testIncompleteLayoutIsRejected() {
        XCTAssertNil(SwipeDecoder(keyCenters: ["a": .zero], keySize: Self.keySize))
    }

    func testSpeed() {
        var rng = RNG(state: 3)
        let paths = ["something", "the", "probably", "tomorrow", "thanks", "said", "were", "keyboard"]
            .map { Self.swipe($0, wobble: 0.15, rng: &rng) }
        _ = decoder.candidates(for: paths[0])
        let start = Date()
        for p in paths { _ = decoder.candidates(for: p) }
        // Runs once when the finger lifts; generous bound for unoptimised test builds.
        XCTAssertLessThan(Date().timeIntervalSince(start) / Double(paths.count), 0.25)
    }
}

final class EmojiCatalogTests: XCTestCase {
    func testCatalogLoadsInGroups() {
        let c = EmojiCatalog.shared
        XCTAssertEqual(c.groups.first?.name, "Smileys & Emotion")
        XCTAssertEqual(c.groups.first?.emoji.first?.character, "😀")
        XCTAssertEqual(c.groups.count, 9)
        XCTAssertGreaterThan(c.count, 1800)
        XCTAssertTrue(c.groups.contains { $0.emoji.contains { $0.character == "🍕" } })
        XCTAssertFalse(c.groups.flatMap(\.emoji).contains { $0.character == "👍🏽" }, "skin tones are left out")
    }

    func testRecents() {
        var r: [String] = []
        r = EmojiCatalog.recordUse("😀", in: r)
        r = EmojiCatalog.recordUse("🍕", in: r)
        r = EmojiCatalog.recordUse("😀", in: r)
        XCTAssertEqual(r, ["😀", "🍕"])
        XCTAssertEqual(EmojiCatalog.recordUse("x", in: Array(repeating: "y", count: 40).enumerated().map { "\($0.offset)" }).count, 30)
    }
}
