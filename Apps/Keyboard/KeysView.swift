import SwiftUI
import UIKit
import WispenCore

/// One key on the QWERTY keyboard.
struct KeySpec: Identifiable, Equatable {
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

/// Which keys are held (and which are still fading out their touch effect). Drawn by `KeyCell`.
@MainActor
final class KeyPressState: ObservableObject {
    @Published var down: Set<String> = []
    @Published var lit: Set<String> = []
}

struct KeysView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        GeometryReader { geo in
            let rows = KeyboardLayout.rows(for: model.layer, globe: model.needsGlobeKey)
            let unit = geo.size.width / 10
            let rowHeight = geo.size.height / CGFloat(rows.count)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            // The middle letter row is inset by half a key; its outer keys' touch areas are widened instead.
                            let slack = Self.slack(row)
                            ForEach(Array(row.enumerated()), id: \.element.id) { i, key in
                                let extra = (i == 0 || i == row.count - 1) ? slack : 0
                                KeyCell(model: model, presses: model.presses, key: key,
                                        width: (key.width + extra) * unit, height: rowHeight,
                                        visualWidth: key.width * unit,
                                        alignment: i == 0 && extra > 0 ? .trailing : (i == row.count - 1 && extra > 0 ? .leading : .center))
                            }
                        }
                        .zIndex(Double(index))
                    }
                }
                // One touch handler for the whole keyboard, so fast, overlapping taps are never lost.
                KeyTouchSurface(model: model, keys: Self.cells(rows, unit: unit, rowHeight: rowHeight))
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    static func slack(_ row: [KeySpec]) -> CGFloat {
        max(0, 10 - row.reduce(0) { $0 + $1.width }) / 2
    }

    /// Every key's touch area (the full cell, so the gaps between keys count too).
    static func cells(_ rows: [[KeySpec]], unit: CGFloat, rowHeight: CGFloat) -> [(spec: KeySpec, frame: CGRect)] {
        var out: [(KeySpec, CGRect)] = []
        for (r, row) in rows.enumerated() {
            let slack = slack(row)
            var x: CGFloat = 0
            for (i, key) in row.enumerated() {
                let w = (key.width + ((i == 0 || i == row.count - 1) ? slack : 0)) * unit
                out.append((key, CGRect(x: x, y: CGFloat(r) * rowHeight, width: w, height: rowHeight)))
                x += w
            }
        }
        return out
    }
}

/// A key's visible cap. Touches are handled by `KeyTouchSurface`.
struct KeyCell: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var presses: KeyPressState
    let key: KeySpec
    let width: CGFloat
    let height: CGFloat
    let visualWidth: CGFloat
    let alignment: Alignment

    @Environment(\.keyPalette) private var palette

    private var pressed: Bool { presses.down.contains(key.id) }
    private var lit: Bool { presses.lit.contains(key.id) }

    var body: some View {
        cap
            .frame(width: visualWidth - 6, height: height - 10)
            .frame(width: width, height: height, alignment: alignment)
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
            Image(systemName: "globe").font(.system(size: 18))
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
}

// MARK: - Touch handling

struct KeyTouchSurface: UIViewRepresentable {
    let model: KeyboardModel
    let keys: [(spec: KeySpec, frame: CGRect)]

    func makeUIView(context: Context) -> KeyTouchView {
        let v = KeyTouchView()
        v.model = model
        v.keys = keys
        return v
    }

    func updateUIView(_ uiView: KeyTouchView, context: Context) {
        uiView.model = model
        uiView.keys = keys
    }
}

/// Handles every finger on the keyboard in one place, like the system keyboard:
/// - the key is chosen where the finger lands (gaps between keys go to the nearest key);
/// - a key is typed when its finger lifts, or as soon as the next finger lands (fast typists overlap taps);
/// - a touch iOS cancels is still typed.
final class KeyTouchView: UIView {
    weak var model: KeyboardModel?
    var keys: [(spec: KeySpec, frame: CGRect)] = []

    private struct Touch {
        let spec: KeySpec
        let effectID = UUID()
        let startX: CGFloat
        var cursorOrigin: CGFloat = 0
        var movedCursor = false
    }

    private var tracker = KeyTouchTracker<ObjectIdentifier, KeySpec>()
    private var touches: [ObjectIdentifier: Touch] = [:]
    private var globeTouches: Set<ObjectIdentifier> = []
    private var repeatTimer: Timer?
    private var repeatTouch: ObjectIdentifier?
    private var repeats = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let model else { return }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            guard let index = KeyHitTest.index(of: point, in: keys.map(\.frame)) else { continue }
            let spec = keys[index].spec

            if spec.kind == .globe {
                globeTouches.insert(id)
                model.handleInputModeList(from: self, with: event)
                continue
            }

            // Type any key still held from the previous tap before handling this one.
            let rollsOver: Bool
            switch spec.kind {
            case .character, .space: rollsOver = true
            default: rollsOver = false
            }
            for earlier in tracker.begin(id, key: spec, rollsOver: rollsOver) { commit(earlier) }

            self.touches[id] = Touch(spec: spec, startX: point.x)
            model.presses.down.insert(spec.id)
            model.presses.lit.insert(spec.id)
            let canvasPoint = model.effects.canvas.map { touch.location(in: $0) } ?? point
            model.effects.began(self.touches[id]!.effectID, at: canvasPoint, keySize: keys[index].frame.size,
                                isDelete: spec.kind == .delete)
            pressed(spec, touch: id)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let model else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if globeTouches.contains(id) {
                model.handleInputModeList(from: self, with: event)
                continue
            }
            guard var t = self.touches[id] else { continue }
            if let canvas = model.effects.canvas { model.effects.moved(t.effectID, to: touch.location(in: canvas)) }
            if t.spec.kind == .space {
                // Drag on the space bar to move the cursor, like the system keyboard.
                let step: CGFloat = 9
                let delta = touch.location(in: self).x - t.startX - t.cursorOrigin
                if abs(delta) >= step {
                    let chars = Int(delta / step)
                    model.moveCursor(by: chars)
                    t.cursorOrigin += CGFloat(chars) * step
                    if !t.movedCursor {
                        t.movedCursor = true
                        tracker.suppress(id)
                    }
                }
                self.touches[id] = t
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Still typed: iOS cancels touches for its own reasons, not because you didn't mean the key.
        finish(touches, event: event)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let model else { return }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = ObjectIdentifier(touch)
            if globeTouches.remove(id) != nil {
                model.handleInputModeList(from: self, with: event)
                continue
            }
            guard let t = self.touches.removeValue(forKey: id) else { continue }
            if let key = tracker.end(id) { commit(key) }
            if repeatTouch == id { stopRepeating() }
            if !self.touches.values.contains(where: { $0.spec.id == t.spec.id }) {
                model.presses.down.remove(t.spec.id)
                withAnimation(.easeOut(duration: 0.5)) { _ = model.presses.lit.remove(t.spec.id) }
            }
            model.effects.ended(t.effectID)
        }
    }

    /// What happens the moment a key goes down.
    private func pressed(_ spec: KeySpec, touch: ObjectIdentifier) {
        guard let model else { return }
        model.keyDown()
        switch spec.kind {
        case .shift:
            model.shiftTapped()
        case .delete:
            model.deleteBackward()
            stopRepeating()
            repeatTouch = touch
            repeats = 0
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.startRepeating() }
            }
        default:
            break
        }
    }

    private func startRepeating() {
        guard repeatTouch != nil else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.repeatTouch != nil, let model = self.model else { return }
                self.repeats += 1
                // After about a second of holding, delete whole words.
                if self.repeats > 12 { model.deleteWordBackward() } else { model.deleteBackward() }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatTouch = nil
    }

    /// What a key types (on release, or early on rollover).
    private func commit(_ spec: KeySpec) {
        guard let model else { return }
        switch spec.kind {
        case .character(let c): model.type(c)
        case .space: model.space()
        case .returnKey: model.newline()
        case .layer: model.toggleLayer()
        case .symbols: model.toggleSymbols()
        case .shift, .delete, .globe: break
        }
    }
}
