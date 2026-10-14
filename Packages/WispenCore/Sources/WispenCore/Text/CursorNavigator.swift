import Foundation

/// Moves the cursor around text for the space-bar trackpad, including up and down a line.
///
/// A keyboard can't see where the app wraps lines; it only sees the text around the cursor. So this
/// lays the text out itself: real line breaks exactly, and long paragraphs wrapped at word
/// boundaries every `lineWidth` characters (an estimate of the app's line length). Moving up or
/// down keeps the column you started from, like a text editor.
///
/// Take a snapshot when the trackpad starts and keep using it: the text around the cursor that
/// iOS reports lags behind cursor moves.
public struct CursorNavigator: Sendable {
    private let text: [Character]
    private let lines: [Range<Int>]
    /// Cursor position, in characters from the start of the snapshot.
    public private(set) var position: Int
    /// The column to return to when moving up or down through shorter lines.
    private var goalColumn: Int?

    public init(before: String, after: String, lineWidth: Int) {
        text = Array(before + after)
        position = before.count
        lines = Self.layout(text, width: max(8, lineWidth))
    }

    /// Moves by `characters` (left is negative), then by `lines` (up is negative).
    /// Returns how far the cursor moved, in UTF-16 units, for `adjustTextPosition(byCharacterOffset:)`.
    public mutating func move(characters: Int = 0, lines delta: Int = 0) -> Int {
        let start = position
        if characters != 0 {
            position = min(max(0, position + characters), text.count)
            goalColumn = nil
        }
        if delta != 0 {
            let current = lineIndex(of: position)
            let column = goalColumn ?? (position - lines[current].lowerBound)
            let target = min(max(0, current + delta), lines.count - 1)
            if target != current {
                let line = lines[target]
                // On a wrapped line, stop before its last character: the end of a wrapped line is the
                // same spot as the start of the next one.
                let wraps = line.upperBound < text.count && text[line.upperBound] != "\n"
                let maxColumn = wraps ? max(0, line.count - 1) : line.count
                position = line.lowerBound + min(column, maxColumn)
                goalColumn = column
            }
        }
        return utf16Distance(from: start, to: position)
    }

    /// Visual lines as character ranges (without their line breaks).
    static func layout(_ text: [Character], width: Int) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var lineStart = 0
        var lastSpace: Int?
        var i = 0
        while i < text.count {
            let c = text[i]
            if c == "\n" {
                lines.append(lineStart..<i)
                lineStart = i + 1
                lastSpace = nil
            } else {
                if c == " " { lastSpace = i }
                if i - lineStart >= width {
                    // Wrap after the last space, or mid-word if a word is longer than a line.
                    let breakAt = lastSpace.map { $0 + 1 } ?? i
                    if breakAt > lineStart {
                        lines.append(lineStart..<breakAt)
                        lineStart = breakAt
                    }
                    lastSpace = nil
                    if c == " ", i >= lineStart { lastSpace = i }
                }
            }
            i += 1
        }
        lines.append(lineStart..<text.count)
        return lines
    }

    private func lineIndex(of position: Int) -> Int {
        // The last line that starts at or before the position.
        var index = 0
        for (i, line) in lines.enumerated() where line.lowerBound <= position { index = i }
        return index
    }

    private func utf16Distance(from a: Int, to b: Int) -> Int {
        guard a != b else { return 0 }
        let lo = min(a, b), hi = max(a, b)
        let n = text[lo..<hi].reduce(0) { $0 + $1.utf16.count }
        return b > a ? n : -n
    }
}
