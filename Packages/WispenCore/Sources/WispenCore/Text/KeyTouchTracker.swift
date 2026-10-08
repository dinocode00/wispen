import Foundation

/// Decides when each key press is typed, so fast typing never drops a letter.
///
/// Like the system keyboard, a key is typed when its finger lifts — or earlier, the moment another
/// finger comes down ("rollover"), since fast typists press the next key before releasing the last.
/// A touch iOS cancels is still typed.
public struct KeyTouchTracker<Touch: Hashable, Key> {
    private struct Active {
        let key: Key
        let rollsOver: Bool
        var done: Bool
    }

    private var active: [Touch: Active] = [:]
    private var order: [Touch] = []

    public init() {}

    public var isEmpty: Bool { active.isEmpty }

    /// A finger came down on `key`. Returns earlier keys, still held, that must be typed right now (oldest first).
    /// `rollsOver`: whether this key is typed early when another finger lands (letters and space; not shift or delete).
    public mutating func begin(_ touch: Touch, key: Key, rollsOver: Bool) -> [Key] {
        var typeNow: [Key] = []
        for t in order {
            guard var a = active[t], a.rollsOver, !a.done else { continue }
            a.done = true
            active[t] = a
            typeNow.append(a.key)
        }
        if active[touch] != nil { order.removeAll { $0 == touch } }
        active[touch] = Active(key: key, rollsOver: rollsOver, done: false)
        order.append(touch)
        return typeNow
    }

    /// The finger lifted, or iOS cancelled the touch. Returns the key to type, unless it was already typed.
    public mutating func end(_ touch: Touch) -> Key? {
        guard let a = active.removeValue(forKey: touch) else { return nil }
        order.removeAll { $0 == touch }
        return a.done ? nil : a.key
    }

    /// Don't type this touch's key (e.g. the space bar was used to move the cursor).
    public mutating func suppress(_ touch: Touch) {
        active[touch]?.done = true
    }

    public func key(for touch: Touch) -> Key? { active[touch]?.key }
}

public enum KeyHitTest {
    /// The key a touch belongs to: the one containing the point, otherwise the nearest one within `slop`
    /// points (touches that land in the gaps or margins still count).
    public static func index(of point: CGPoint, in frames: [CGRect], slop: CGFloat = 24) -> Int? {
        if let i = frames.firstIndex(where: { $0.contains(point) }) { return i }
        var best: (index: Int, distance: CGFloat)?
        for (i, f) in frames.enumerated() {
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= slop, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }
}
