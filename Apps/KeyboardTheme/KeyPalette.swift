import CoreText
import SwiftUI
import UIKit
import WispenCore

/// Everything a look decides about how keys are drawn. Built from a `KeyboardTheme`.
struct KeyPalette {
    enum Background {
        /// The system keyboard backdrop shows through.
        case clear
        case color(Color)
        /// A 3×3 mesh gradient that drifts while you type.
        case mesh([Color])
    }

    var background: Background = .clear
    var key: Color
    /// Optional lighter top for a glossy key (glass).
    var keyTop: Color?
    var mod: Color
    var text: Color
    var border: Color?
    var glow: Color?
    var glowRadius: CGFloat = 0
    var textGlow: Color?
    /// Retro: a solid shadow under each key.
    var hardShadow: Color?
    /// Classic: the system keyboard's 1pt shadow.
    var softShadow = false
    var radius: CGFloat = 6
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var pixelFont = false
    var pressed: Color
    var popup: Color
    var popupText: Color
    var accent: Color
    var accentText: Color
    var ripple: Color
    /// iOS 26 Liquid Glass keys.
    var liquidGlass = false
    var pixelEffects = false

    func font(_ size: CGFloat) -> Font {
        if pixelFont {
            PixelFont.register()
            return .custom(PixelFont.name, size: size * 0.5)
        }
        return .system(size: size, weight: weight, design: design)
    }

    var toolbarText: Color { text.opacity(0.9) }

    static func make(_ theme: KeyboardTheme) -> KeyPalette {
        switch theme.look {
        case .system:
            return KeyPalette(key: KeyColors.character, mod: KeyColors.function, text: .primary, softShadow: true,
                              pressed: KeyColors.function, popup: KeyColors.character, popupText: .primary,
                              accent: KeyColors.accent, accentText: .white, ripple: KeyColors.accent)
        case .minimalLight:
            return KeyPalette(background: .color(Color(hex: "#ECEEF2")), key: .black.opacity(0.04), mod: .black.opacity(0.08),
                              text: Color(hex: "#17191E"), radius: 10, weight: .light, pressed: .black.opacity(0.14),
                              popup: .white, popupText: Color(hex: "#17191E"), accent: Color(hex: "#17191E"),
                              accentText: .white, ripple: Color(hex: "#3653F0"))
        case .minimalDark:
            return KeyPalette(background: .color(Color(hex: "#1B1C20")), key: .white.opacity(0.06), mod: .white.opacity(0.11),
                              text: Color(hex: "#ECEEF2"), radius: 10, weight: .light, pressed: .white.opacity(0.2),
                              popup: Color(hex: "#2C2E34"), popupText: .white, accent: Color(hex: "#ECEEF2"),
                              accentText: Color(hex: "#1B1C20"), ripple: Color(hex: "#9FB2FF"))
        case .black:
            // Floating letters, each drawn with a faint hairline outline.
            return KeyPalette(background: .color(.black), key: .black, mod: .white.opacity(0.03), text: Color(hex: "#D6D6D6"),
                              border: .white.opacity(0.16), radius: 10, weight: .thin, pressed: .white.opacity(0.14), popup: Color(hex: "#161616"),
                              popupText: .white, accent: .white, accentText: .black, ripple: .white)
        case .glass:
            return KeyPalette(background: .mesh(["#7FB2FF", "#C59BFF", "#FF9FC2", "#5AD1C9", "#9CC3FF", "#FFB38A",
                                                 "#3D7BFF", "#8C6CFF", "#FF7A9A"].map { Color(hex: $0) }),
                              key: .white.opacity(0.16), keyTop: .white.opacity(0.42), mod: .white.opacity(0.1),
                              text: .white, border: .white.opacity(0.45), textGlow: .black.opacity(0.25), radius: 13,
                              pressed: .white.opacity(0.45), popup: .white.opacity(0.75), popupText: Color(hex: "#0F1222"),
                              accent: .white.opacity(0.9), accentText: Color(hex: "#15182A"), ripple: .white, liquidGlass: true)
        case .neon:
            let glow = Color(hex: theme.neon)
            return KeyPalette(background: .color(Color(hex: "#07060C")), key: .white.opacity(0.015), mod: .white.opacity(0.035),
                              text: glow, border: glow, glow: glow.opacity(0.55), glowRadius: 5, textGlow: glow,
                              radius: 8, pressed: glow.opacity(0.35), popup: Color(hex: "#0D0B16"), popupText: glow,
                              accent: glow, accentText: Color(hex: "#07060C"), ripple: glow)
        case .aurora:
            return KeyPalette(background: .mesh(["#0A3B3A", "#17806D", "#33257A", "#0E5A74", "#1D9A7A", "#3B2A7A",
                                                 "#0A3B3A", "#2A6F9A", "#17806D"].map { Color(hex: $0) }),
                              key: Color(hex: "#040A18").opacity(0.32), mod: Color(hex: "#040A18").opacity(0.5),
                              text: Color(hex: "#E9FFF8"), border: .white.opacity(0.14), radius: 10,
                              pressed: .white.opacity(0.22), popup: Color(hex: "#12324A"), popupText: Color(hex: "#E9FFF8"),
                              accent: Color(hex: "#E9FFF8"), accentText: Color(hex: "#0A3B3A"), ripple: Color(hex: "#8FF5D4"))
        case .sunset:
            return KeyPalette(background: .mesh(["#FF7A59", "#FF4F8B", "#FFA34D", "#FF4F8B", "#7B3FE4", "#FF7A59",
                                                 "#FFA34D", "#C2378F", "#5B2BC4"].map { Color(hex: $0) }),
                              key: Color(hex: "#280828").opacity(0.24), mod: Color(hex: "#280828").opacity(0.4),
                              text: .white, border: .white.opacity(0.2), radius: 10, pressed: .white.opacity(0.28),
                              popup: Color(hex: "#6A2A72"), popupText: .white, accent: .white,
                              accentText: Color(hex: "#A3305E"), ripple: Color(hex: "#FFF3C4"))
        case .retro:
            let ink = Color(hex: "#0F380F")
            return KeyPalette(background: .color(Color(hex: "#8BAC0F")), key: Color(hex: "#9BBC0F"), mod: Color(hex: "#7A9A0C"),
                              text: ink, border: ink, hardShadow: Color(hex: "#306230"), radius: 0, pixelFont: true,
                              pressed: Color(hex: "#C4DD5A"), popup: Color(hex: "#C4DD5A"), popupText: ink,
                              accent: ink, accentText: Color(hex: "#9BBC0F"), ripple: ink, pixelEffects: true)
        case .custom:
            let c = theme.custom
            let glow = Color(hex: c.glow)
            let s = c.glowStrength
            let weight: Font.Weight = c.weight == .thin ? .thin : (c.weight == .bold ? .bold : .regular)
            let design: Font.Design = c.font == .rounded ? .rounded : (c.font == .mono ? .monospaced : .default)
            return KeyPalette(background: .color(Color(hex: c.background)), key: Color(hex: c.keys),
                              mod: Color(hex: HexColor.mix(c.keys, c.background, 0.45)), text: Color(hex: c.letters),
                              border: s > 0 ? glow.opacity(0.25 + 0.6 * s) : nil, glow: s > 0 ? glow.opacity(0.55 * s) : nil,
                              glowRadius: 2 + 6 * s, textGlow: s > 0.3 ? glow.opacity(s) : nil, radius: c.roundness,
                              weight: weight, design: design, pixelFont: c.font == .pixel, pressed: glow.opacity(0.35),
                              popup: Color(hex: HexColor.mix(c.keys, "#FFFFFF", HexColor.luminance(c.keys) > 0.5 ? 0 : 0.08)),
                              popupText: Color(hex: c.letters), accent: glow,
                              accentText: HexColor.luminance(c.glow) > 0.55 ? .black : .white, ripple: glow,
                              pixelEffects: c.font == .pixel)
        }
    }
}

extension Color {
    init(hex: String) {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        self.init(red: c.r, green: c.g, blue: c.b)
    }
}

enum KeyColors {
    static let character = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
    static let function = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    })
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.95)
}

/// "Press Start 2P" (SIL Open Font License), bundled for the Retro look.
enum PixelFont {
    static let name = "PressStart2P-Regular"
    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
    static func register() { _ = registered }
}

private struct KeyPaletteKey: EnvironmentKey {
    static let defaultValue = KeyPalette.make(KeyboardTheme())
}

extension EnvironmentValues {
    var keyPalette: KeyPalette {
        get { self[KeyPaletteKey.self] }
        set { self[KeyPaletteKey.self] = newValue }
    }
}

// MARK: - Drawing

/// The visible key cap for a look, with the effect's flash on top while `lit`.
struct ThemedKeyCap<Label: View>: View {
    let palette: KeyPalette
    var isMod = false
    var fillOverride: Color?
    var lit = false
    var effect: KeyboardTheme.Effect = .none
    @ViewBuilder var label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
        base(shape)
            .overlay {
                if lit {
                    EffectFlash(effect: effect, palette: palette, shape: shape)
                        .transition(.opacity)
                }
            }
            .overlay {
                label()
                    .foregroundStyle(lit ? EffectFlash.textColor(effect, palette: palette) : palette.text)
                    .shadow(color: palette.textGlow ?? .clear, radius: palette.textGlow == nil ? 0 : 3)
            }
    }

    @ViewBuilder
    private func base(_ shape: RoundedRectangle) -> some View {
        if palette.liquidGlass {
            if #available(iOS 26.0, *) {
                shape.fill(fill.opacity(0.35)).glassEffect(.regular, in: shape)
            } else {
                drawn(shape)
            }
        } else {
            drawn(shape)
        }
    }

    private var fill: Color { fillOverride ?? (isMod ? palette.mod : palette.key) }

    private func drawn(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(fill)
            .overlay {
                if let top = palette.keyTop, fillOverride == nil {
                    shape.fill(LinearGradient(colors: [top, .clear], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                if let border = palette.border { shape.strokeBorder(border, lineWidth: palette.pixelFont ? 2 : (palette.weight == .thin ? 0.75 : 1)) }
            }
            .shadow(color: palette.glow ?? .clear, radius: palette.glow == nil ? 0 : palette.glowRadius)
            .shadow(color: palette.hardShadow ?? (palette.softShadow ? .black.opacity(0.3) : .clear),
                    radius: 0, y: palette.hardShadow != nil ? 3 : (palette.softShadow ? 1 : 0))
    }
}

/// What a key looks like for a moment after you touch it.
struct EffectFlash: View {
    let effect: KeyboardTheme.Effect
    let palette: KeyPalette
    let shape: RoundedRectangle

    var body: some View {
        switch effect {
        case .none:
            shape.fill(palette.pressed)
        case .fire:
            shape.fill(RadialGradient(colors: [Color(hex: "#FFF4B8"), Color(hex: "#FFA531"), Color(hex: "#E9421C"), Color(hex: "#7D1406")],
                                      center: UnitPoint(x: 0.5, y: 0.85), startRadius: 0, endRadius: 34))
                .shadow(color: Color(hex: "#FF781E").opacity(0.85), radius: 8)
        case .ice:
            shape.fill(LinearGradient(colors: [Color(hex: "#F6FCFF"), Color(hex: "#B2DCFF"), Color(hex: "#76B0EE")],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { shape.strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                .shadow(color: Color(hex: "#96D2FF").opacity(0.9), radius: 7)
        case .arcane:
            shape.fill(RadialGradient(colors: [Color(hex: "#8CC8FF").opacity(0.75), Color(hex: "#2E56FF").opacity(0.6), Color(hex: "#12125A").opacity(0.5)],
                                      center: .center, startRadius: 0, endRadius: 28))
                .overlay { shape.strokeBorder(Color(hex: "#AAD7FF"), lineWidth: 1) }
                .shadow(color: Color(hex: "#5096FF"), radius: 9)
        case .storm:
            shape.fill(LinearGradient(colors: [Color(hex: "#F0ECFF"), Color(hex: "#9680FF")], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(hex: "#AA96FF"), radius: 10)
        case .ripple:
            shape.strokeBorder(palette.ripple, lineWidth: 1.5)
                .background(shape.fill(palette.ripple.opacity(0.18)))
        }
    }

    static func textColor(_ effect: KeyboardTheme.Effect, palette: KeyPalette) -> Color {
        switch effect {
        case .none, .ripple: return palette.text
        case .fire: return Color(hex: "#FFF8E4")
        case .ice: return Color(hex: "#0D3A63")
        case .arcane: return Color(hex: "#F0F7FF")
        case .storm: return Color(hex: "#1B1140")
        }
    }
}

/// The keyboard's background. Mesh gradients move a step each time `drift` changes (while you type).
struct ThemeBackground: View {
    let palette: KeyPalette
    @ObservedObject var effects: KeyEffectsEngine

    var body: some View {
        switch palette.background {
        case .clear:
            Color.clear
        case .color(let c):
            c
        case .mesh(let colors):
            MeshGradient(width: 3, height: 3, points: Self.points(effects.drift), colors: colors)
        }
    }

    static func points(_ d: Double) -> [SIMD2<Float>] {
        func f(_ x: Double) -> Float { Float(x) }
        return [
            [0, 0], [f(0.5 + 0.2 * sin(d * 0.9)), 0], [1, 0],
            [0, f(0.5 + 0.2 * cos(d * 1.1))], [f(0.5 + 0.22 * sin(d * 1.3)), f(0.5 + 0.18 * cos(d * 0.7))], [1, f(0.5 + 0.2 * sin(d * 0.8))],
            [0, 1], [f(0.5 + 0.2 * cos(d)), 1], [1, 1],
        ]
    }
}

/// "COMBO ×12" while you type fast with an effect on.
struct ComboBadge: View {
    @ObservedObject var effects: KeyEffectsEngine

    var body: some View {
        if effects.comboShown {
            HStack(spacing: 4) {
                Text("COMBO").font(.system(size: 11, weight: .bold))
                Text("×\(effects.streak)").font(.system(size: 15, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .scaleEffect(effects.bump ? 1.25 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.5), value: effects.bump)
            .transition(.opacity)
        }
    }
}

/// The effects canvas, placed over the keyboard. It never takes touches.
struct EffectsLayer: UIViewRepresentable {
    let effects: KeyEffectsEngine

    func makeUIView(context: Context) -> EffectsCanvasView {
        let v = EffectsCanvasView()
        effects.canvas = v
        return v
    }

    func updateUIView(_ uiView: EffectsCanvasView, context: Context) {
        if effects.canvas !== uiView { effects.canvas = uiView }
    }
}

/// Animated bars shown while recording (the keyboard doesn't get live audio levels).
struct PulsingBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    let h = 10 + 22 * abs(sin(t * 3 + Double(i) * 0.9))
                    Capsule().fill(.white).frame(width: 5, height: h)
                }
            }
        }
    }
}
