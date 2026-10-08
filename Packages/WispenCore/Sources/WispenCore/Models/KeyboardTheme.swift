import Foundation

/// How the Wispen keyboard looks, and what happens when you touch a key.
public struct KeyboardTheme: Codable, Equatable, Sendable {
    public enum Look: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, minimalLight, minimalDark, black, glass, neon, aurora, sunset, retro, custom

        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .system: return "Classic"
            case .minimalLight: return "Minimal Light"
            case .minimalDark: return "Minimal Dark"
            case .black: return "Black"
            case .glass: return "Liquid Glass"
            case .neon: return "Neon"
            case .aurora: return "Aurora"
            case .sunset: return "Sunset"
            case .retro: return "Retro 8-bit"
            case .custom: return "Your own"
            }
        }
    }

    public enum Effect: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, fire, ice, arcane, storm, ripple

        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .none: return "None"
            case .fire: return "Fire"
            case .ice: return "Ice"
            case .arcane: return "Arcane"
            case .storm: return "Storm"
            case .ripple: return "Ripple"
            }
        }
        public var emoji: String {
            switch self {
            case .none: return "○"
            case .fire: return "🔥"
            case .ice: return "❄️"
            case .arcane: return "🔮"
            case .storm: return "⚡"
            case .ripple: return "💧"
            }
        }
    }

    public enum Font: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, rounded, mono, pixel
        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .system: return "System"
            case .rounded: return "Rounded"
            case .mono: return "Mono"
            case .pixel: return "Pixel"
            }
        }
    }

    public enum Weight: String, Codable, CaseIterable, Identifiable, Sendable {
        case thin, regular, bold
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
    }

    /// The "Your own" look.
    public struct Custom: Codable, Equatable, Sendable {
        public var background = "#10131C"
        public var keys = "#1D2233"
        public var letters = "#F4E9FF"
        public var glow = "#FF3DF2"
        /// Key corner radius in points (0–22).
        public var roundness: Double = 12
        /// 0 = no glow, 1 = strong glow.
        public var glowStrength: Double = 0.6
        public var font: Font = .rounded
        public var weight: Weight = .regular

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Custom()
            background = HexColor.normalized(try c.decodeIfPresent(String.self, forKey: .background)) ?? d.background
            keys = HexColor.normalized(try c.decodeIfPresent(String.self, forKey: .keys)) ?? d.keys
            letters = HexColor.normalized(try c.decodeIfPresent(String.self, forKey: .letters)) ?? d.letters
            glow = HexColor.normalized(try c.decodeIfPresent(String.self, forKey: .glow)) ?? d.glow
            roundness = min(22, max(0, try c.decodeIfPresent(Double.self, forKey: .roundness) ?? d.roundness))
            glowStrength = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .glowStrength) ?? d.glowStrength))
            font = (try? c.decodeIfPresent(Font.self, forKey: .font)) ?? d.font
            weight = (try? c.decodeIfPresent(Weight.self, forKey: .weight)) ?? d.weight
        }
    }

    public static let neonColors = ["#39F3FF", "#FF3DF2", "#B6FF3B", "#FFB22E", "#9D7BFF", "#FF4B4B"]

    /// Default: black keys with hairline outlines, and arcane sparks.
    public var look: Look = .black
    public var effect: Effect = .arcane
    /// Effects grow the faster you type.
    public var combo = true
    /// Show the enlarged letter above a key while it's pressed.
    public var popups = true
    public var neon = KeyboardTheme.neonColors[0]
    public var custom = Custom()

    public init(look: Look = .black, effect: Effect = .arcane) {
        self.look = look
        self.effect = effect
    }

    /// Effects drawn as square pixels instead of soft glows.
    public var isPixel: Bool { look == .retro || (look == .custom && custom.font == .pixel) }

    /// Effect strength from how fast you're typing: 1 normally, up to 3 on a long fast streak.
    public static func intensity(streak: Int, combo: Bool) -> Double {
        guard combo else { return 1 }
        return 1 + Double(min(max(streak, 0), 30)) / 15
    }

    // Tolerant decoding: unknown looks/effects (from a newer version) fall back instead of failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = (try? c.decodeIfPresent(Look.self, forKey: .look)) ?? .black
        effect = (try? c.decodeIfPresent(Effect.self, forKey: .effect)) ?? .arcane
        combo = (try? c.decodeIfPresent(Bool.self, forKey: .combo)) ?? true
        popups = (try? c.decodeIfPresent(Bool.self, forKey: .popups)) ?? true
        neon = HexColor.normalized(try? c.decodeIfPresent(String.self, forKey: .neon)) ?? KeyboardTheme.neonColors[0]
        custom = (try? c.decodeIfPresent(Custom.self, forKey: .custom)) ?? Custom()
    }
}

/// "#RRGGBB" colors, shared by the app and keyboard.
public enum HexColor {
    /// Red, green, blue in 0…1, or nil if the string isn't a 3- or 6-digit hex color.
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Double(n >> 16 & 0xFF) / 255, Double(n >> 8 & 0xFF) / 255, Double(n & 0xFF) / 255)
    }

    public static func string(r: Double, g: Double, b: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// "#abc" → "#AABBCC"; nil for anything that isn't a color.
    public static func normalized(_ hex: String?) -> String? {
        guard let hex, let c = components(hex) else { return nil }
        return string(r: c.r, g: c.g, b: c.b)
    }

    /// Perceived brightness, 0 (black) … 1 (white).
    public static func luminance(_ hex: String) -> Double {
        guard let c = components(hex) else { return 0 }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Blend two colors: t = 0 gives `a`, t = 1 gives `b`.
    public static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        guard let x = components(a), let y = components(b) else { return a }
        return string(r: x.r + (y.r - x.r) * t, g: x.g + (y.g - x.g) * t, b: x.b + (y.b - x.b) * t)
    }
}
