import SwiftUI
import UIKit
import WispenCore

/// One key on the QWERTY keyboard.
struct KeySpec: Identifiable {
    enum Kind: Equatable {
        case character(String)
        case shift
        case delete
        case layer(String)   // "123" / "ABC"
        case symbols(String) // "#+=" / "123" on the symbols row
        case globe
        case space
        case returnKey
    }

    let id: String
    let kind: Kind
    /// Width in key units (a letter key is 1).
    let width: CGFloat

    init(_ kind: Kind, width: CGFloat = 1) {
        self.kind = kind
        self.width = width
        switch kind {
        case .character(let c): id = "c-\(c)"
        case .layer(let l): id = "layer-\(l)"
        case .symbols(let l): id = "sym-\(l)"
        default: id = "\(kind)"
        }
    }

    static func chars(_ s: String, width: CGFloat = 1) -> [KeySpec] {
        s.map { KeySpec(.character(String($0)), width: width) }
    }
}

enum KeyboardLayout {
    static func rows(for layer: KeyboardModel.Layer, globe: Bool) -> [[KeySpec]] {
        let bottomLeft: KeySpec = layer == .letters ? KeySpec(.layer("123"), width: 1.25) : KeySpec(.layer("ABC"), width: 1.25)
        var bottom = [bottomLeft]
        if globe { bottom.append(KeySpec(.globe, width: 1.25)) }
        bottom.append(KeySpec(.space, width: globe ? 5.25 : 6.5))
        bottom.append(KeySpec(.returnKey, width: 2.25))

        switch layer {
        case .letters:
            return [
                KeySpec.chars("qwertyuiop"),
                KeySpec.chars("asdfghjkl"),
                [KeySpec(.shift, width: 1.5)] + KeySpec.chars("zxcvbnm") + [KeySpec(.delete, width: 1.5)],
                bottom,
            ]
        case .numbers:
            return [
                KeySpec.chars("1234567890"),
                KeySpec.chars("-/:;()$&@\""),
                [KeySpec(.symbols("#+="), width: 1.5)] + KeySpec.chars(".,?!'", width: 1.4) + [KeySpec(.delete, width: 1.5)],
                bottom,
            ]
        case .symbols:
            return [
                KeySpec.chars("[]{}#%^*+="),
                KeySpec.chars("_\\|~<>€£¥•"),
                [KeySpec(.symbols("123"), width: 1.5)] + KeySpec.chars(".,?!'", width: 1.4) + [KeySpec(.delete, width: 1.5)],
                bottom,
            ]
        }
    }
}

struct KeysView: View {
    @ObservedObject var model: KeyboardModel
    let globeKey: GlobeKey

    var body: some View {
        GeometryReader { geo in
            let rows = KeyboardLayout.rows(for: model.layer, globe: model.needsGlobeKey)
            let unit = geo.size.width / 10
            let rowHeight = geo.size.height / CGFloat(rows.count)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        // The middle letter row is inset by half a key; widen its outer keys' touch areas instead.
                        let rowUnits = row.reduce(0) { $0 + $1.width }
                        let slack = max(0, 10 - rowUnits) / 2
                        ForEach(Array(row.enumerated()), id: \.element.id) { i, key in
                            let extra = (i == 0 || i == row.count - 1) ? slack : 0
                            KeyCell(model: model, key: key, globeKey: globeKey,
                                    width: (key.width + extra) * unit, height: rowHeight,
                                    visualWidth: key.width * unit,
                                    alignment: i == 0 && extra > 0 ? .trailing : (i == row.count - 1 && extra > 0 ? .leading : .center))
                        }
                    }
                    .zIndex(Double(index))
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

/// A key's touch area (the whole cell, so gaps between keys still register) and its visible cap.
struct KeyCell: View {
    @ObservedObject var model: KeyboardModel
    let key: KeySpec
    let globeKey: GlobeKey
    let width: CGFloat
    let height: CGFloat
    let visualWidth: CGFloat
    let alignment: Alignment

    @Environment(\.keyPalette) private var palette
    @State private var pressed = false
    /// Stays on briefly after release so the effect's glow fades out.
    @State private var lit = false
    @State private var touchID = UUID()
    @State private var repeatTimer: Timer?
    @State private var repeats = 0
    @State private var dragOrigin: CGFloat?
    @State private var movedCursor = false

    var body: some View {
        Group {
            if key.kind == .globe {
                globeKey
                    .frame(width: visualWidth - 6, height: height - 10)
                    .frame(width: width, height: height)
            } else {
                cap
                    .frame(width: visualWidth - 6, height: height - 10)
                    .frame(width: width, height: height, alignment: alignment)
                    .contentShape(Rectangle())
                    .gesture(gesture)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: Appearance

    private var isCharacter: Bool {
        if case .character = key.kind { return true }
        return false
    }

    private var isAccentReturn: Bool { key.kind == .returnKey && model.returnKeyLabel != nil }

    private var isMod: Bool { !(isCharacter || key.kind == .space) }

    /// Only special states override the look's key color.
    private var fillOverride: Color? {
        if isAccentReturn { return pressed ? palette.pressed : palette.accent }
        if key.kind == .shift, model.shift != .off, model.layer == .letters { return palette.softShadow ? palette.key : palette.pressed }
        return nil
    }

    private var showsPopup: Bool { isCharacter && pressed && model.theme.popups }

    private var cap: some View {
        ThemedKeyCap(palette: palette, isMod: isMod, fillOverride: fillOverride,
                     lit: lit && !(showsPopup && model.effects.effect == .none),
                     effect: model.effects.effect) { label }
            .overlay(alignment: .bottom) {
                if showsPopup {
                    Text(displayCharacter)
                        .font(palette.font(34))
                        .foregroundStyle(palette.popupText)
                        .shadow(color: palette.textGlow ?? .clear, radius: palette.textGlow == nil ? 0 : 3)
                        .frame(width: visualWidth * 1.35, height: height * 1.05)
                        .background(RoundedRectangle(cornerRadius: palette.radius + 3, style: .continuous).fill(palette.popup)
                            .overlay { RoundedRectangle(cornerRadius: palette.radius + 3, style: .continuous)
                                .strokeBorder(palette.border ?? .clear, lineWidth: palette.border == nil ? 0 : 1) }
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1))
                        .offset(y: -height * 0.92)
                        .allowsHitTesting(false)
                }
            }
    }

    private var displayCharacter: String {
        guard case .character(let c) = key.kind else { return "" }
        return model.layer == .letters && model.shift != .off ? c.uppercased() : c
    }

    @ViewBuilder
    private var label: some View {
        switch key.kind {
        case .character:
            Text(displayCharacter).font(palette.font(23))
        case .shift:
            Image(systemName: model.shift == .locked ? "capslock.fill" : (model.shift == .once ? "shift.fill" : "shift"))
                .font(.system(size: 18, weight: .medium))
        case .delete:
            Image(systemName: pressed ? "delete.left.fill" : "delete.left")
                .font(.system(size: 18, weight: .medium))
        case .layer(let l), .symbols(let l):
            Text(l).font(palette.font(16))
        case .space:
            Text("space").font(palette.font(16))
        case .returnKey:
            if let label = model.returnKeyLabel {
                Text(label).font(palette.font(16)).foregroundStyle(palette.accentText)
            } else {
                Image(systemName: "return").font(.system(size: 18))
            }
        case .globe:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        switch key.kind {
        case .character: return displayCharacter
        case .shift: return model.shift == .locked ? "Caps lock" : "Shift"
        case .delete: return "Delete"
        case .layer(let l), .symbols(let l): return l == "123" ? "Numbers" : (l == "ABC" ? "Letters" : "Symbols")
        case .globe: return "Next keyboard"
        case .space: return "Space"
        case .returnKey: return model.returnKeyLabel ?? "Return"
        }
    }

    // MARK: Behaviour

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyEffectsEngine.space))
            .onChanged { value in
                if !pressed {
                    pressed = true
                    lit = true
                    touchID = UUID()
                    model.effects.began(touchID, at: value.location, keySize: CGSize(width: visualWidth, height: height),
                                        isDelete: key.kind == .delete)
                    touchDown()
                } else {
                    model.effects.moved(touchID, to: value.location)
                }
                if key.kind == .space { trackpad(value.translation.width) }
            }
            .onEnded { _ in
                pressed = false
                withAnimation(.easeOut(duration: 0.5)) { lit = false }
                model.effects.ended(touchID)
                touchUp()
            }
    }

    private func touchDown() {
        model.keyDown()
        switch key.kind {
        case .shift:
            model.shiftTapped()
        case .delete:
            model.deleteBackward()
            repeats = 0
            repeatTimer?.invalidate()
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                Task { @MainActor in startRepeating() }
            }
        case .space:
            dragOrigin = nil
            movedCursor = false
        default:
            break
        }
    }

    private func startRepeating() {
        guard pressed else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
            Task { @MainActor in
                guard pressed else { repeatTimer?.invalidate(); return }
                repeats += 1
                // After about a second of holding, delete whole words.
                if repeats > 12 { model.deleteWordBackward() } else { model.deleteBackward() }
            }
        }
    }

    private func touchUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        switch key.kind {
        case .character(let c): model.type(c)
        case .space: if !movedCursor { model.space() }
        case .returnKey: model.newline()
        case .layer: model.toggleLayer()
        case .symbols: model.toggleSymbols()
        case .shift, .delete, .globe: break
        }
    }

    /// Drag on the space bar to move the cursor, like the system keyboard.
    private func trackpad(_ x: CGFloat) {
        let step: CGFloat = 9
        guard let origin = dragOrigin else {
            dragOrigin = x
            return
        }
        let delta = x - origin
        guard abs(delta) >= step else { return }
        let chars = Int(delta / step)
        model.moveCursor(by: chars)
        dragOrigin = origin + CGFloat(chars) * step
        movedCursor = true
    }
}
