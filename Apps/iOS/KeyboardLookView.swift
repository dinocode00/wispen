import SwiftUI
import UIKit
import WispenCore

/// Pick the Wispen keyboard's look and touch effect, and try them right here.
struct KeyboardLookView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var effects = KeyEffectsEngine()
    @State private var tryText = ""

    private var theme: KeyboardTheme { app.settings.keyboardTheme }

    var body: some View {
        Form {
            Section {
                ThemePlayground(theme: theme, effects: effects)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if effects.effectsAllowed {
                    Text("Touch the keys to try the effect. Tap the mic to see the listening screen.")
                } else {
                    Text("Touch effects are off while Low Power Mode or Reduce Motion is on.")
                }
            }

            Section("Look") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(KeyboardTheme.Look.allCases) { look in
                        Button { app.settings.keyboardTheme.look = look } label: {
                            LookCard(theme: theme, look: look, effects: effects, selected: theme.look == look)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            if theme.look == .neon {
                Section("Neon color") {
                    HStack(spacing: 14) {
                        ForEach(KeyboardTheme.neonColors, id: \.self) { hex in
                            Button { app.settings.keyboardTheme.neon = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                    .overlay { Circle().strokeBorder(.primary, lineWidth: theme.neon == hex ? 2.5 : 0).padding(-4) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Neon color \(hex)")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if theme.look == .custom {
                Section("Your own look") {
                    ColorPicker("Background", selection: hex(\.background), supportsOpacity: false)
                    ColorPicker("Keys", selection: hex(\.keys), supportsOpacity: false)
                    ColorPicker("Letters", selection: hex(\.letters), supportsOpacity: false)
                    ColorPicker("Glow", selection: hex(\.glow), supportsOpacity: false)
                    LabeledContent("Roundness") {
                        Slider(value: $app.settings.keyboardTheme.custom.roundness, in: 0...22)
                    }
                    LabeledContent("Glow strength") {
                        Slider(value: $app.settings.keyboardTheme.custom.glowStrength, in: 0...1)
                    }
                    Picker("Font", selection: $app.settings.keyboardTheme.custom.font) {
                        ForEach(KeyboardTheme.Font.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Letter weight", selection: $app.settings.keyboardTheme.custom.weight) {
                        ForEach(KeyboardTheme.Weight.allCases) { Text($0.name).tag($0) }
                    }
                }
            }

            Section("Touch effect") {
                ForEach(KeyboardTheme.Effect.allCases) { effect in
                    Button { app.settings.keyboardTheme.effect = effect } label: {
                        HStack {
                            Text(effect.emoji).frame(width: 28)
                            Text(effect.name).foregroundStyle(.primary)
                            Spacer()
                            if theme.effect == effect { Image(systemName: "checkmark").foregroundStyle(Color.wispenAccent) }
                        }
                    }
                }
            }

            Section {
                Toggle("Combo mode", isOn: $app.settings.keyboardTheme.combo)
                Toggle("Key pop-ups", isOn: $app.settings.keyboardTheme.popups)
            } footer: {
                Text("Combo mode makes effects grow the faster you type. Effects only animate while you touch a key or Wispen is listening, and switch off in Low Power Mode and with Reduce Motion.")
            }

            Section {
                TextField("Type here with the Wispen keyboard", text: $tryText, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Try it for real")
            } footer: {
                Text("Switch to the Wispen keyboard with 🌐. Changes here show up on it right away.")
            }
        }
        .navigationTitle("Keyboard look")
        .onAppear { effects.apply(theme) }
        .onChange(of: app.settings.keyboardTheme) {
            effects.apply(app.settings.keyboardTheme)
            DarwinNotifier.shared.post(.theme)
        }
    }

    /// A color picker binding for one of the custom look's hex colors.
    private func hex(_ path: WritableKeyPath<KeyboardTheme.Custom, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: app.settings.keyboardTheme.custom[keyPath: path]) },
            set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                app.settings.keyboardTheme.custom[keyPath: path] = HexColor.string(r: Double(r), g: Double(g), b: Double(b))
            })
    }
}

/// A small picture of a look: two rows of keys on its background.
private struct LookCard: View {
    let theme: KeyboardTheme
    let look: KeyboardTheme.Look
    let effects: KeyEffectsEngine
    let selected: Bool

    var body: some View {
        var t = theme
        t.look = look
        let palette = KeyPalette.make(t)
        return VStack(spacing: 6) {
            ZStack {
                Color(uiColor: .systemGray5)
                ThemeBackground(palette: palette, effects: effects)
                VStack(spacing: 6) {
                    row(Array("QWERT"), palette)
                    row(Array("ASDFG"), palette)
                }
                .padding(8)
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.wispenAccent : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1)
            }
            Text(look.name)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.wispenAccent : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ letters: [Character], _ palette: KeyPalette) -> some View {
        HStack(spacing: 5) {
            ForEach(letters, id: \.self) { c in
                ThemedKeyCap(palette: palette) {
                    Text(String(c)).font(palette.font(15))
                }
            }
        }
    }
}

/// A working mini keyboard for trying effects without switching keyboards.
private struct ThemePlayground: View {
    let theme: KeyboardTheme
    @ObservedObject var effects: KeyEffectsEngine
    @State private var listening = false

    var body: some View {
        let palette = KeyPalette.make(theme)
        ZStack(alignment: .topTrailing) {
            Color(uiColor: .systemGray5)
            ThemeBackground(palette: palette, effects: effects)
            VStack(spacing: 0) {
                HStack {
                    Text("Polished")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.text.opacity(0.8))
                    Spacer()
                    Button { toggleListening() } label: {
                        ZStack {
                            Circle().fill(listening ? Color.red : palette.accent).frame(width: 34, height: 34)
                            Image(systemName: listening ? "stop.fill" : "mic.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(listening ? .white : palette.accentText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listening ? "Stop the listening preview" : "Preview the listening screen")
                }
                .padding(.horizontal, 12)
                .frame(height: 44)

                if listening {
                    VStack(spacing: 10) {
                        Text("Listening… tap to finish")
                            .font(.callout)
                            .foregroundStyle(palette.text.opacity(0.7))
                        Button { toggleListening() } label: {
                            ZStack {
                                Circle().fill(Color.red).frame(width: 96, height: 96)
                                PulsingBars()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        let unit = geo.size.width / 10
                        let rowHeight = geo.size.height / 3
                        VStack(spacing: 0) {
                            keyRow("qwertyuiop", unit: unit, height: rowHeight)
                            keyRow("asdfghjkl", unit: unit, height: rowHeight)
                            HStack(spacing: 0) {
                                PlaygroundKey(label: "shift", width: unit * 1.5, height: rowHeight, isMod: true, effects: effects)
                                ForEach(Array("zxcvbnm"), id: \.self) { c in
                                    PlaygroundKey(label: String(c), width: unit, height: rowHeight, effects: effects)
                                }
                                PlaygroundKey(label: "delete", width: unit * 1.5, height: rowHeight, isMod: true, effects: effects)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            EffectsLayer(effects: effects)
                .allowsHitTesting(false)
            ComboBadge(effects: effects)
                .padding(.top, 48)
                .padding(.trailing, 10)
                .allowsHitTesting(false)
        }
        .frame(height: 220)
        .coordinateSpace(name: KeyEffectsEngine.space)
        .environment(\.keyPalette, palette)
        .onDisappear { if listening { effects.stopAmbient() } }
    }

    private func keyRow(_ letters: String, unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(letters), id: \.self) { c in
                PlaygroundKey(label: String(c), width: unit, height: height, effects: effects)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleListening() {
        listening.toggle()
        // Start once the keys have been swapped for the mic, so the effect centers on it.
        if listening {
            DispatchQueue.main.async { effects.startAmbient() }
        } else {
            effects.stopAmbient()
        }
    }
}

private struct PlaygroundKey: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    var isMod = false
    let effects: KeyEffectsEngine
    @Environment(\.keyPalette) private var palette
    @State private var pressed = false
    @State private var lit = false
    @State private var touchID = UUID()

    var body: some View {
        ThemedKeyCap(palette: palette, isMod: isMod, lit: lit, effect: effects.effect) {
            if label == "shift" {
                Image(systemName: "shift").font(.system(size: 16, weight: .medium))
            } else if label == "delete" {
                Image(systemName: "delete.left").font(.system(size: 16, weight: .medium))
            } else {
                Text(label).font(palette.font(21))
            }
        }
        .scaleEffect(pressed ? 0.96 : 1)
        .frame(width: width - 6, height: height - 10)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyEffectsEngine.space))
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        lit = true
                        touchID = UUID()
                        effects.began(touchID, at: value.location, keySize: CGSize(width: width, height: height),
                                      isDelete: label == "delete")
                    } else {
                        effects.moved(touchID, to: value.location)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    withAnimation(.easeOut(duration: 0.5)) { lit = false }
                    effects.ended(touchID)
                }
        )
        .accessibilityLabel(label)
    }
}
