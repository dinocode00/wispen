import UIKit

/// Shapes for the Arcane effect, after Tolkien's Middle-earth: Tengwar (the elvish letters, with
/// their vowel marks), Cirth (the dwarf runes of Moria), the Star of Fëanor, a mallorn leaf, and
/// now and then the One Ring in gold.
///
/// Drawn as vector paths (no font), in a box about 20 units tall around (0, 0), y pointing down.
/// Tengwar letters sit on a body from y −4 to 4, with stems reaching to ±10.
enum ElvishGlyphs {
    enum Kind { case tengwa, certh, star, leaf, ring }

    struct Glyph {
        let kind: Kind
        let path: CGPath
    }

    /// A random glyph: mostly letters, sometimes a symbol.
    static func random() -> Glyph {
        let roll = Double.random(in: 0..<1)
        if roll < 0.04 { return Glyph(kind: .ring, path: ring) }
        if roll < 0.13 { return Glyph(kind: .star, path: star) }
        if roll < 0.20 { return Glyph(kind: .leaf, path: leaf) }
        if roll < 0.42 { return Glyph(kind: .certh, path: cirth.randomElement()!) }
        return Glyph(kind: .tengwa, path: tengwar.randomElement()!)
    }

    /// Every Tengwar letter alone, and again with each vowel mark above its bow.
    private static let tengwar: [CGPath] = tengwarSources.flatMap { entry -> [CGPath] in
        let (source, tehtaX) = entry
        let letter = parse(source)
        return [letter] + tehtar.map { tehta in
            let p = CGMutablePath()
            p.addPath(letter)
            p.addPath(tehta, transform: CGAffineTransform(translationX: tehtaX, y: 0))
            return p
        }
    }
    private static let cirth = cirthSources.map(parse)
    private static let tehtar = tehtarSources.map(parse)
    private static let star = parse("M0 -10 L1.3 -3.14 L7.07 -7.07 L3.14 -1.3 L10 0 L3.14 1.3 L7.07 7.07 L1.3 3.14 L0 10 L-1.3 3.14 L-7.07 7.07 L-3.14 1.3 L-10 0 L-3.14 -1.3 L-7.07 -7.07 L-1.3 -3.14 Z M1.4 0 C1.4 0.77 0.77 1.4 0 1.4 C-0.77 1.4 -1.4 0.77 -1.4 0 C-1.4 -0.77 -0.77 -1.4 0 -1.4 C0.77 -1.4 1.4 -0.77 1.4 0 Z")
    private static let leaf = parse("M0 10 C6.5 4 5.5 -5 0 -10 C-5.5 -5 -6.5 4 0 10 Z M0 10 L0 -7 M0 3 L3 0 M0 3 L-3 0 M0 -2 L2.4 -4.6 M0 -2 L-2.4 -4.6")
    private static let ring = parse("M9 0 C9 4.97 4.97 9 0 9 C-4.97 9 -9 4.97 -9 0 C-9 -4.97 -4.97 -9 0 -9 C4.97 -9 9 -4.97 9 0 Z M7.2 0 C7.2 3.98 3.98 7.2 0 7.2 C-3.98 7.2 -7.2 3.98 -7.2 0 C-7.2 -3.98 -3.98 -7.2 0 -7.2 C3.98 -7.2 7.2 -3.98 7.2 0 Z")

    /// The 24 primary letters (4 series of bows × 6 grades of stems), then stemless letters and
    /// carriers; each with where its vowel mark goes.
    private static let tengwarSources: [(String, CGFloat)] = [
        ("M0 -4 L0 10 M0 -4 C4.6 -4.8 4.6 4.8 0 4", 2.3),
        ("M0 -10 L0 4 M0 -4 C4.6 -4.8 4.6 4.8 0 4", 2.3),
        ("M0 -4 L0 4 M0 -4 C4.6 -4.8 4.6 4.8 0 4", 2.3),
        ("M0 -4 L0 10 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.6 -4.6 6.6 4.6 2.3 3.6", 3.2),
        ("M0 -10 L0 4 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.6 -4.6 6.6 4.6 2.3 3.6", 3.2),
        ("M0 -4 L0 4 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.6 -4.6 6.6 4.6 2.3 3.6", 3.2),
        ("M0 -4 L0 10 M0 -4 C5 -4.8 5.4 2.6 1.6 4.2", 2.3),
        ("M0 -10 L0 4 M0 -4 C5 -4.8 5.4 2.6 1.6 4.2", 2.3),
        ("M0 -4 L0 4 M0 -4 C5 -4.8 5.4 2.6 1.6 4.2", 2.3),
        ("M0 -4 L0 10 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.8 -4.6 7 2.8 3.8 4.2", 3.2),
        ("M0 -10 L0 4 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.8 -4.6 7 2.8 3.8 4.2", 3.2),
        ("M0 -4 L0 4 M0 -4 C3.4 -4.8 3.4 4.8 0 4 M2.3 -3.6 C6.8 -4.6 7 2.8 3.8 4.2", 3.2),
        ("M0 -4 L0 10 M0 -4 C-4.6 -4.8 -4.6 4.8 0 4", -2.3),
        ("M0 -10 L0 4 M0 -4 C-4.6 -4.8 -4.6 4.8 0 4", -2.3),
        ("M0 -4 L0 4 M0 -4 C-4.6 -4.8 -4.6 4.8 0 4", -2.3),
        ("M0 -4 L0 10 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.6 -4.6 -6.6 4.6 -2.3 3.6", -3.2),
        ("M0 -10 L0 4 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.6 -4.6 -6.6 4.6 -2.3 3.6", -3.2),
        ("M0 -4 L0 4 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.6 -4.6 -6.6 4.6 -2.3 3.6", -3.2),
        ("M0 -4 L0 10 M0 -4 C-5 -4.8 -5.4 2.6 -1.6 4.2", -2.3),
        ("M0 -10 L0 4 M0 -4 C-5 -4.8 -5.4 2.6 -1.6 4.2", -2.3),
        ("M0 -4 L0 4 M0 -4 C-5 -4.8 -5.4 2.6 -1.6 4.2", -2.3),
        ("M0 -4 L0 10 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.8 -4.6 -7 2.8 -3.8 4.2", -3.2),
        ("M0 -10 L0 4 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.8 -4.6 -7 2.8 -3.8 4.2", -3.2),
        ("M0 -4 L0 4 M0 -4 C-3.4 -4.8 -3.4 4.8 0 4 M-2.3 -3.6 C-6.8 -4.6 -7 2.8 -3.8 4.2", -3.2),
        ("M-3 4 C-3.4 -5 3.4 -5 3 -1 C2.7 2 0.5 3.4 -0.5 4.2", 0),
        ("M-3.5 4 C-3.8 -4.6 3.8 -4.6 3.5 4 M3.5 4 L3.5 6", 0),
        ("M-3 -4 C-3.4 1 2.6 1.6 3 -3 M3 -3 C3.4 2 1 4.8 -2 5", 0),
        ("M3 -3.4 C-0.5 -6 -5 -1 -2 2 C0 4 3 3 3 -3.4 L3 4.5", 0),
        ("M-3.2 -4 C-4.2 3.6 4.2 4.2 3 -4 M-3.2 -4 L-4.4 -2.6", 0),
        ("M-3 -4 C-3.5 3 3.5 3 3 -4 M-3 -4 L-3 10", 0),
        ("M-3 4 C-3.5 -4 0 -5 0 0 C0 -5 3.5 -4 3 4", 0),
        ("M0 -4 L0 4 M0 -4 L1.2 -4.6", 0),
        ("M0 -4 L0 10 M0 -4 L1.2 -4.6", 0),
    ]

    private static let cirthSources = [
        "M0 -8 L0 8 M0 -8 L4 -4",
        "M0 -8 L0 8 M0 -8 L4 -4 M0 -1 L4 3",
        "M0 -8 L0 8 M0 -8 L-4 -4 M0 -8 L4 -4",
        "M0 -8 L0 8 M0 -4 L3 0 L0 4 L-3 0 Z",
        "M-4 -8 L4 8 M4 -8 L-4 8 M-4 0 L4 0",
        "M0 -8 L0 8 M0 -6 L3.5 -2.5 L0 1",
        "M0 -8 L0 8 M0 -8 L4 -5 L0 -2 L4 8",
        "M0 8 L0 -8 M0 -2 L-4 -7 M0 -2 L4 -7",
        "M0 -8 L0 8 M0 0 L4 -4 M0 0 L-4 4",
        "M-4 -8 L-4 8 L4 -8 L4 8",
        "M-3 -8 L-3 8 M3 -8 L3 8 M-3 -3 L3 3",
        "M0 -8 L0 8 M-3.5 -5 L3.5 -1 M3.5 -5 L-3.5 -1",
    ]

    private static let tehtarSources = [
        "M-1.05 -6.6 C-1.05 -6.3 -1.3 -6.05 -1.6 -6.05 C-1.9 -6.05 -2.15 -6.3 -2.15 -6.6 C-2.15 -6.9 -1.9 -7.15 -1.6 -7.15 C-1.3 -7.15 -1.05 -6.9 -1.05 -6.6 Z M2.15 -6.6 C2.15 -6.3 1.9 -6.05 1.6 -6.05 C1.3 -6.05 1.05 -6.3 1.05 -6.6 C1.05 -6.9 1.3 -7.15 1.6 -7.15 C1.9 -7.15 2.15 -6.9 2.15 -6.6 Z M0.55 -8.8 C0.55 -8.5 0.3 -8.25 0 -8.25 C-0.3 -8.25 -0.55 -8.5 -0.55 -8.8 C-0.55 -9.1 -0.3 -9.35 0 -9.35 C0.3 -9.35 0.55 -9.1 0.55 -8.8 Z", // a
        "M-1.2 -6.2 L1.4 -8.8", // e
        "M0.6 -7.2 C0.6 -6.87 0.33 -6.6 0 -6.6 C-0.33 -6.6 -0.6 -6.87 -0.6 -7.2 C-0.6 -7.53 -0.33 -7.8 0 -7.8 C0.33 -7.8 0.6 -7.53 0.6 -7.2 Z", // i
        "M-1.8 -6.2 C-2.4 -9.6 2.6 -9.8 1.6 -7.2", // o
        "M1.8 -6.2 C2.4 -9.6 -2.6 -9.8 -1.6 -7.2", // u
    ]

    /// Reads the M, L, C and Z commands of an SVG path (absolute coordinates).
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        func flush() {
            switch command {
            case "M" where numbers.count >= 2: path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L" where numbers.count >= 2: path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C" where numbers.count >= 6:
                path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]), control1: CGPoint(x: numbers[0], y: numbers[1]),
                              control2: CGPoint(x: numbers[2], y: numbers[3]))
            default: break
            }
            numbers = []
        }
        for token in d.split(separator: " ") {
            guard let first = token.first else { continue }
            if first.isLetter {
                flush()
                command = first
                if command == "Z" { path.closeSubpath() }
                if let n = Double(token.dropFirst()) { numbers.append(CGFloat(n)) }
            } else if let n = Double(token) {
                numbers.append(CGFloat(n))
            }
        }
        flush()
        return path
    }
}
