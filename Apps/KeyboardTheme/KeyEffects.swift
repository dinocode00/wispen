import QuartzCore
import SwiftUI
import UIKit
import WispenCore

/// Runs the touch effects. Everything is Core Animation (drawn by the GPU), and only exists while a
/// key is touched or Wispen is listening: when you stop typing, nothing animates.
@MainActor
final class KeyEffectsEngine: ObservableObject {
    static let space = "wispenKeyboard"

    /// Advances while you type; mesh-gradient backgrounds drift with it.
    @Published private(set) var drift: Double = 0
    @Published private(set) var streak = 0
    @Published private(set) var comboShown = false
    @Published private(set) var bump = false

    weak var canvas: EffectsCanvasView? {
        didSet { canvas?.configure(theme) }
    }
    private(set) var theme = KeyboardTheme()
    private var presses: [UUID: EffectPress] = [:]
    private var ambient: EffectPress?
    private var lastKeyAt = Date.distantPast
    private var lastDrift = Date.distantPast
    private var comboGeneration = 0

    func apply(_ theme: KeyboardTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        canvas?.configure(theme)
    }

    /// Effects stay off in Low Power Mode and with Reduce Motion.
    var effectsAllowed: Bool { !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled }
    var effect: KeyboardTheme.Effect { effectsAllowed ? theme.effect : .none }

    func began(_ id: UUID, at point: CGPoint, keySize: CGSize, isDelete: Bool = false) {
        let intensity = noteKey()
        guard effect != .none, let canvas else { return }
        presses[id]?.end()
        presses[id] = canvas.press(effect, at: point, keySize: keySize, intensity: intensity, isDelete: isDelete)
    }

    func moved(_ id: UUID, to point: CGPoint) { presses[id]?.move(to: point) }

    func ended(_ id: UUID) { presses.removeValue(forKey: id)?.end() }

    /// The listening screen's version of the effect.
    func startAmbient() {
        guard ambient == nil, effect != .none, let canvas else { return }
        ambient = canvas.ambient(effect)
    }

    func stopAmbient() {
        ambient?.end()
        ambient = nil
    }

    private func noteKey() -> Double {
        let now = Date()
        streak = now.timeIntervalSince(lastKeyAt) < 0.48 ? streak + 1 : 1
        lastKeyAt = now
        if effectsAllowed, case .mesh = KeyPalette.make(theme).background, now.timeIntervalSince(lastDrift) > 1.2 {
            lastDrift = now
            withAnimation(.easeInOut(duration: 2.4)) { drift += 1 }
        }
        if theme.combo, effect != .none, streak >= 5 {
            withAnimation(.easeOut(duration: 0.1)) { comboShown = true }
            bump = true
            comboGeneration += 1
            let generation = comboGeneration
            after(0.12) { [weak self] in self?.bump = false }
            after(0.9) { [weak self] in
                guard let self, self.comboGeneration == generation else { return }
                withAnimation(.easeOut(duration: 0.25)) { self.comboShown = false }
            }
        }
        return KeyboardTheme.intensity(streak: streak, combo: theme.combo)
    }
}

/// Run `work` on the main actor after `seconds`.
@MainActor
func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        work()
    }
}

/// One touch's live effect (or the listening screen's).
@MainActor
protocol EffectPress: AnyObject {
    func move(to point: CGPoint)
    func end()
}

/// Transparent view over the keyboard where effects are drawn. It never receives touches.
final class EffectsCanvasView: UIView {
    private(set) var pixel = false
    private(set) var rippleColor = UIColor.white

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ theme: KeyboardTheme) {
        pixel = theme.isPixel
        rippleColor = UIColor(KeyPalette.make(theme).ripple)
    }

    func press(_ effect: KeyboardTheme.Effect, at p: CGPoint, keySize: CGSize, intensity: Double, isDelete: Bool) -> EffectPress? {
        switch effect {
        case .none: return nil
        case .fire: return FirePress(canvas: self, at: p, keySize: keySize, intensity: intensity)
        case .ice: return IcePress(canvas: self, at: p, keySize: keySize, intensity: intensity)
        case .arcane: return ArcanePress(canvas: self, at: p, intensity: intensity)
        case .storm: return StormPress(canvas: self, at: p, intensity: intensity, isDelete: isDelete)
        case .ripple: return RipplePress(canvas: self, at: p, intensity: intensity)
        }
    }

    /// The listening screen: centred on the big mic button.
    func ambient(_ effect: KeyboardTheme.Effect) -> EffectPress? {
        let area = CGRect(x: 0, y: 44, width: bounds.width, height: max(0, bounds.height - 44))
        let center = CGPoint(x: area.midX, y: area.midY + 12)
        switch effect {
        case .none: return nil
        case .arcane: return ArcanePress(canvas: self, at: center, intensity: 1, ambientRadius: 58)
        default: return AmbientPress(canvas: self, effect: effect, area: area, center: center)
        }
    }

    // MARK: Building blocks

    /// Soft white dot (or a square in pixel looks); emitter cells tint it with `color`.
    var particleImage: CGImage? { pixel ? Self.square : Self.dot }

    static let dot: CGImage? = {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.55).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.3, 1]) else { return }
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                                             endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
        }.cgImage
    }()

    static let square: CGImage? = {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.cgImage
    }()

    static let shard: CGImage? = {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 15, y: 8))
            p.addLine(to: CGPoint(x: 2, y: 15))
            p.addLine(to: CGPoint(x: 4, y: 1))
            p.close()
            UIColor.white.withAlphaComponent(0.85).setFill()
            p.fill()
            UIColor.white.setStroke()
            p.lineWidth = 1
            p.stroke()
        }.cgImage
    }()

    func cell(_ color: UIColor, birthRate: Float, lifetime: Float, velocity: CGFloat, velocityRange: CGFloat = 0,
              longitude: CGFloat = 0, range: CGFloat = 0, scale: CGFloat, scaleRange: CGFloat = 0, scaleSpeed: CGFloat = 0,
              alphaSpeed: Float, yAcceleration: CGFloat = 0, spin: CGFloat = 0, spinRange: CGFloat = 0,
              image: CGImage? = nil) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image ?? particleImage
        c.color = color.cgColor
        c.birthRate = birthRate
        c.lifetime = lifetime
        c.lifetimeRange = lifetime * 0.3
        c.velocity = velocity
        c.velocityRange = velocityRange
        c.emissionLongitude = longitude
        c.emissionRange = range
        c.scale = pixel && image == nil ? scale * 0.6 : scale
        c.scaleRange = scaleRange
        c.scaleSpeed = scaleSpeed
        c.alphaSpeed = alphaSpeed
        c.yAcceleration = yAcceleration
        c.spin = spin
        c.spinRange = spinRange
        if pixel { c.magnificationFilter = CALayerContentsFilter.nearest.rawValue }
        return c
    }

    func emitter(at p: CGPoint, shape: CAEmitterLayerEmitterShape = .point, mode: CAEmitterLayerEmitterMode = .volume,
                 size: CGSize = .zero, cells: [CAEmitterCell], additive: Bool = true) -> CAEmitterLayer {
        let e = CAEmitterLayer()
        e.frame = bounds
        e.emitterPosition = p
        e.emitterShape = shape
        e.emitterMode = mode
        e.emitterSize = size
        e.renderMode = additive ? .additive : .unordered
        e.beginTime = CACurrentMediaTime()
        e.emitterCells = cells
        layer.addSublayer(e)
        return e
    }

    /// Emit for a moment, then let the particles finish and remove the layer.
    func burst(_ e: CAEmitterLayer, for seconds: Double = 0.06, cleanupAfter: Double = 1.2) {
        after(seconds) { e.birthRate = 0 }
        after(cleanupAfter) { e.removeFromSuperlayer() }
    }

    /// Stop emitting, then remove once the last particles have faded.
    func retire(_ e: CAEmitterLayer?, after seconds: Double = 1.2) {
        guard let e else { return }
        e.birthRate = 0
        after(seconds) { e.removeFromSuperlayer() }
    }

    func fadeOut(_ l: CALayer?, duration: Double = 0.25, grow: CGFloat = 1) {
        guard let l else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = l.presentation()?.opacity ?? l.opacity
        fade.toValue = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = grow
        let group = CAAnimationGroup()
        group.animations = grow == 1 ? [fade] : [fade, scale]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.opacity = 0
        l.add(group, forKey: "out")
        after(duration + 0.05) { l.removeFromSuperlayer() }
    }

    /// A glowing dot as a plain layer (for orbiting sparks).
    func glowDot(size: CGFloat, color: UIColor) -> CALayer {
        let d = CALayer()
        d.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        d.cornerRadius = pixel ? 0 : size / 2
        d.backgroundColor = color.cgColor
        d.shadowColor = color.cgColor
        d.shadowOpacity = 1
        d.shadowRadius = pixel ? 0 : size * 0.9
        d.shadowOffset = .zero
        d.shadowPath = pixel ? UIBezierPath(rect: d.bounds).cgPath : UIBezierPath(ovalIn: d.bounds).cgPath
        return d
    }

    /// A short-lived flash of glow at a point.
    func flare(at p: CGPoint, size: CGFloat, color: UIColor, opacity: Float = 0.7, duration: Double = 0.35) {
        let l = glowDot(size: size, color: color.withAlphaComponent(0.5))
        l.position = p
        l.shadowRadius = size * 0.6
        l.opacity = opacity
        layer.addSublayer(l)
        fadeOut(l, duration: duration, grow: 1.3)
    }

    // MARK: Shapes

    static func boltPoints(from a: CGPoint, to b: CGPoint, roughness: CGFloat) -> [CGPoint] {
        var pts = [a, b]
        var off = roughness
        for _ in 0..<5 {
            var next = [pts[0]]
            for i in 0..<(pts.count - 1) {
                let p = pts[i], q = pts[i + 1]
                let dx = q.x - p.x, dy = q.y - p.y
                let len = max(1, hypot(dx, dy))
                let o = CGFloat.random(in: -off...off)
                next.append(CGPoint(x: (p.x + q.x) / 2 - dy / len * o, y: (p.y + q.y) / 2 + dx / len * o))
                next.append(q)
            }
            pts = next
            off /= 2
        }
        return pts
    }

    func bolt(from a: CGPoint, to b: CGPoint, width: CGFloat = 1, roughness: CGFloat = 16, branch: Bool = true) {
        let pts = Self.boltPoints(from: a, to: b, roughness: roughness)
        let path = UIBezierPath()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.addLine(to: $0) }

        let container = CALayer()
        container.frame = bounds
        for (color, w, alpha) in [(UIColor(red: 0.48, green: 0.38, blue: 1, alpha: 1), 7 * width, Float(0.25)),
                                  (UIColor(red: 0.72, green: 0.66, blue: 1, alpha: 1), 3 * width, Float(0.6)),
                                  (UIColor.white, 1.3 * width, Float(1))] {
            let s = CAShapeLayer()
            s.path = path.cgPath
            s.strokeColor = color.cgColor
            s.fillColor = nil
            s.lineWidth = w
            s.lineCap = .round
            s.lineJoin = .round
            s.opacity = alpha
            container.addSublayer(s)
        }
        layer.addSublayer(container)
        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        flicker.values = [1, 0.35, 1, 0.6, 0]
        flicker.duration = 0.2
        container.opacity = 0
        container.add(flicker, forKey: "flicker")
        after(0.22) { container.removeFromSuperlayer() }

        if branch, Bool.random() || width > 1.2 {
            let m = pts[Int(Double(pts.count) * Double.random(in: 0.3...0.6))]
            let angle = atan2(b.y - a.y, b.x - a.x) + CGFloat.random(in: -0.9...0.9)
            let d = hypot(b.x - a.x, b.y - a.y) * CGFloat.random(in: 0.3...0.5)
            bolt(from: m, to: CGPoint(x: m.x + cos(angle) * d, y: m.y + sin(angle) * d), width: width * 0.55,
                 roughness: roughness * 0.5, branch: false)
        }
    }

    func ring(at p: CGPoint, radius: CGFloat, color: UIColor, delay: Double = 0, duration: Double = 0.55) {
        let s = CAShapeLayer()
        s.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        s.position = p
        s.path = UIBezierPath(ovalIn: s.bounds).cgPath
        s.strokeColor = color.cgColor
        s.fillColor = nil
        s.lineWidth = 2
        s.opacity = 0
        layer.addSublayer(s)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.05
        scale.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0.6, 0]
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = 2.6
        width.toValue = 0.4
        let g = CAAnimationGroup()
        g.animations = [scale, fade, width]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.fillMode = .backwards
        s.add(g, forKey: "ring")
        after(delay + duration + 0.05) { s.removeFromSuperlayer() }
    }

    /// A rune: a stave with two branches, floating up and fading.
    func rune(near p: CGPoint, size: CGFloat = 7) {
        let branches: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, -1, 0.6, -0.4), (0, -0.3, 0.6, 0.3), (0, -1, -0.6, -0.4), (0, 0.3, 0.6, -0.2),
            (0, -0.5, -0.6, 0), (0, 0.2, -0.6, 0.7), (0.6, -0.4, 0, 0.2), (0, -1, 0.6, -1.3),
        ]
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -size))
        path.addLine(to: CGPoint(x: 0, y: size))
        for b in [branches.randomElement()!, branches.randomElement()!] {
            path.move(to: CGPoint(x: b.0 * size, y: b.1 * size))
            path.addLine(to: CGPoint(x: b.2 * size, y: b.3 * size))
        }
        let s = CAShapeLayer()
        s.path = path.cgPath
        s.strokeColor = UIColor(red: 0.7, green: 0.85, blue: 1, alpha: 1).cgColor
        s.fillColor = nil
        s.lineWidth = 1.3
        s.lineCap = .round
        s.shadowColor = UIColor(red: 0.24, green: 0.42, blue: 1, alpha: 1).cgColor
        s.shadowOpacity = 1
        s.shadowRadius = 4
        s.shadowOffset = .zero
        let start = CGPoint(x: p.x + .random(in: -22...22), y: p.y - .random(in: 8...24))
        s.position = start
        s.opacity = 0
        layer.addSublayer(s)
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = start.y
        rise.toValue = start.y - 30
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.6, 1]
        let g = CAAnimationGroup()
        g.animations = [rise, fade]
        g.duration = 0.9
        s.add(g, forKey: "rune")
        after(0.95) { s.removeFromSuperlayer() }
    }

    static func snowflake(length L: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let dx = cos(a), dy = sin(a)
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: dx * L, y: dy * L))
            for b in [0.38, 0.66] as [CGFloat] {
                let bx = dx * L * b, by = dy * L * b, bl = L * 0.3 * (1 - b * 0.4)
                for side in [-1, 1] as [CGFloat] {
                    let a2 = a + side * .pi / 3.2
                    path.move(to: CGPoint(x: bx, y: by))
                    path.addLine(to: CGPoint(x: bx + cos(a2) * bl, y: by + sin(a2) * bl))
                }
            }
        }
        return path
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let c = HexColor.components(hex) ?? (1, 1, 1)
        self.init(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

// MARK: - Arcane: blue sparks orbit your fingertip inside a turning magic circle; runes rise.

@MainActor
private final class ArcanePress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private let circle = CALayer()
    private var sparks: CAEmitterLayer?
    private var point: CGPoint
    private var alive = true
    private let intensity: Double
    private let isAmbient: Bool

    init(canvas: EffectsCanvasView, at p: CGPoint, intensity: Double, ambientRadius: CGFloat? = nil) {
        self.canvas = canvas
        self.point = p
        self.intensity = intensity
        self.isAmbient = ambientRadius != nil
        let base = ambientRadius ?? 20 * CGFloat(0.85 + 0.15 * intensity)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.position = p
        canvas.layer.addSublayer(circle)

        // The faint dashed magic circle, turning slowly.
        let guide = CAShapeLayer()
        let gr = base * 1.25
        guide.path = UIBezierPath(ovalIn: CGRect(x: -gr, y: -gr, width: gr * 2, height: gr * 2)).cgPath
        guide.strokeColor = UIColor(hex: "#6FB6FF").withAlphaComponent(0.45).cgColor
        guide.fillColor = nil
        guide.lineWidth = 0.8
        guide.lineDashPattern = [2, 5]
        circle.addSublayer(guide)
        spin(guide, duration: 6, clockwise: false)

        circle.addSublayer(orbit(canvas, radius: base, count: 10, dot: 3.4, color: UIColor(hex: "#9CCBFF"), duration: 0.9, clockwise: true))
        circle.addSublayer(orbit(canvas, radius: base * 1.5, count: 14, dot: 2.4, color: UIColor(hex: "#3D7BFF"), duration: 1.4, clockwise: false))
        CATransaction.commit()

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.3
        pop.toValue = 1
        pop.damping = 12
        pop.initialVelocity = 8
        pop.duration = pop.settlingDuration
        circle.add(pop, forKey: "pop")

        let twinkle = canvas.cell(UIColor(hex: "#BFE0FF"), birthRate: Float(isAmbient ? 40 : 22 * intensity), lifetime: 0.5,
                                  velocity: 14, velocityRange: 8, range: .pi * 2, scale: 0.13, scaleSpeed: -0.15, alphaSpeed: -2)
        sparks = canvas.emitter(at: p, shape: .circle, mode: .outline, size: CGSize(width: base * 2.6, height: base * 2.6), cells: [twinkle])

        canvas.rune(near: p)
        runeLoop()
    }

    private func orbit(_ canvas: EffectsCanvasView, radius r: CGFloat, count: Int, dot: CGFloat, color: UIColor,
                       duration: Double, clockwise: Bool) -> CALayer {
        let rep = CAReplicatorLayer()
        rep.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        rep.position = .zero
        rep.instanceCount = count
        rep.instanceTransform = CATransform3DMakeRotation(2 * .pi / CGFloat(count), 0, 0, 1)
        // Each copy a little dimmer, so the ring reads as sparks with trails.
        rep.instanceAlphaOffset = -0.7 / Float(count)
        let d = canvas.glowDot(size: dot, color: color)
        d.position = CGPoint(x: r, y: 0)
        rep.addSublayer(d)
        spin(rep, duration: duration, clockwise: clockwise)
        return rep
    }

    private func spin(_ l: CALayer, duration: Double, clockwise: Bool) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = clockwise ? Double.pi * 2 : -Double.pi * 2
        a.duration = duration
        a.repeatCount = .infinity
        l.add(a, forKey: "spin")
    }

    private func runeLoop() {
        after(isAmbient ? 0.45 : 0.32) { [weak self] in
            guard let self, self.alive, let canvas = self.canvas else { return }
            canvas.rune(near: self.point)
            self.runeLoop()
        }
    }

    func move(to p: CGPoint) {
        point = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.position = p
        sparks?.emitterPosition = p
        CATransaction.commit()
    }

    func end() {
        guard alive, let canvas else { return }
        alive = false
        canvas.fadeOut(circle, duration: 0.3, grow: 1.7)
        canvas.retire(sparks, after: 0.6)
        guard !isAmbient else { return }
        let burst = canvas.cell(UIColor(hex: "#9CC8FF"), birthRate: Float(260 * intensity), lifetime: 0.55, velocity: 120,
                                velocityRange: 50, range: .pi * 2, scale: 0.16, scaleSpeed: -0.2, alphaSpeed: -1.8)
        canvas.burst(canvas.emitter(at: point, cells: [burst]))
        canvas.rune(near: point)
    }
}

// MARK: - Fire: the key burns and embers rise.

@MainActor
private final class FirePress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private var embers: CAEmitterLayer?
    private var point: CGPoint
    private let intensity: Double

    init(canvas: EffectsCanvasView, at p: CGPoint, keySize: CGSize, intensity: Double) {
        self.canvas = canvas
        self.point = p
        self.intensity = intensity
        let i = CGFloat(intensity)
        let ember = canvas.cell(UIColor(red: 1, green: 0.55, blue: 0.15, alpha: 1), birthRate: Float(60 * intensity), lifetime: 0.75,
                                velocity: 70 * (0.8 + 0.3 * i), velocityRange: 30, longitude: -.pi / 2, range: .pi / 7,
                                scale: 0.28 * (0.8 + 0.2 * i), scaleRange: 0.1, scaleSpeed: -0.3, alphaSpeed: -1.3, yAcceleration: -30)
        ember.greenRange = 0.25
        let core = canvas.cell(UIColor(red: 1, green: 0.93, blue: 0.6, alpha: 1), birthRate: Float(25 * intensity), lifetime: 0.35,
                               velocity: 40, velocityRange: 15, longitude: -.pi / 2, range: .pi / 9, scale: 0.18, scaleSpeed: -0.3, alphaSpeed: -2.6)
        embers = canvas.emitter(at: p, shape: .line, size: CGSize(width: keySize.width * 0.7, height: 1), cells: [ember, core])
        embers?.birthRate = 2.5
        after(0.08) { [weak self] in self?.embers?.birthRate = 1 }
        canvas.flare(at: p, size: keySize.width * 1.2, color: UIColor(red: 1, green: 0.48, blue: 0.12, alpha: 1))
    }

    func move(to p: CGPoint) {
        point = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        embers?.emitterPosition = p
        CATransaction.commit()
    }

    func end() {
        canvas?.retire(embers, after: 1.1)
        embers = nil
    }
}

// MARK: - Ice: frost grows under your finger, then shatters.

@MainActor
private final class IcePress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private let frost = CAShapeLayer()
    private var point: CGPoint
    private let intensity: Double

    init(canvas: EffectsCanvasView, at p: CGPoint, keySize: CGSize, intensity: Double) {
        self.canvas = canvas
        self.point = p
        self.intensity = intensity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.path = EffectsCanvasView.snowflake(length: max(keySize.width, keySize.height) * CGFloat(0.75 + 0.25 * intensity)).cgPath
        frost.position = p
        frost.strokeColor = UIColor(red: 0.96, green: 0.99, blue: 1, alpha: 1).cgColor
        frost.fillColor = nil
        frost.lineWidth = 1.1
        frost.lineCap = .round
        frost.shadowColor = UIColor(red: 0.55, green: 0.8, blue: 1, alpha: 1).cgColor
        frost.shadowOpacity = 1
        frost.shadowRadius = 3
        frost.shadowOffset = .zero
        canvas.layer.addSublayer(frost)
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.fromValue = 0
        grow.toValue = 1
        grow.duration = 0.16
        frost.add(grow, forKey: "grow")
        canvas.flare(at: p, size: keySize.width, color: UIColor(red: 0.75, green: 0.9, blue: 1, alpha: 1), opacity: 0.5)
    }

    func move(to p: CGPoint) {
        point = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.position = p
        CATransaction.commit()
    }

    func end() {
        guard let canvas else { return }
        canvas.fadeOut(frost, duration: 0.2, grow: 1.15)
        let shards = canvas.cell(UIColor(red: 0.85, green: 0.94, blue: 1, alpha: 1), birthRate: Float(350 * intensity), lifetime: 0.7,
                                 velocity: 150, velocityRange: 60, range: .pi * 2, scale: 0.5, scaleRange: 0.25,
                                 alphaSpeed: -1.3, yAcceleration: 450, spin: 4, spinRange: 8,
                                 image: canvas.pixel ? EffectsCanvasView.square : EffectsCanvasView.shard)
        let mist = canvas.cell(UIColor(red: 0.75, green: 0.9, blue: 1, alpha: 0.35), birthRate: 60, lifetime: 0.8, velocity: 20,
                               velocityRange: 10, range: .pi * 2, scale: 0.6, scaleSpeed: 0.5, alphaSpeed: -0.5)
        canvas.burst(canvas.emitter(at: point, cells: [shards, mist], additive: false))
    }
}

// MARK: - Storm: lightning arcs from your finger; the delete key throws a big one.

@MainActor
private final class StormPress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private var point: CGPoint
    private var alive = true
    private let intensity: Double

    init(canvas: EffectsCanvasView, at p: CGPoint, intensity: Double, isDelete: Bool) {
        self.canvas = canvas
        self.point = p
        self.intensity = intensity
        if isDelete {
            canvas.bolt(from: p, to: CGPoint(x: 4, y: p.y + .random(in: -30...10)), width: 1.7, roughness: 30)
            canvas.bolt(from: p, to: CGPoint(x: .random(in: canvas.bounds.width * 0.2...canvas.bounds.width * 0.5), y: 0), width: 1.1, roughness: 24)
            let flash = CALayer()
            flash.frame = canvas.bounds
            flash.backgroundColor = UIColor(red: 0.73, green: 0.68, blue: 1, alpha: 0.28).cgColor
            flash.opacity = 0
            canvas.layer.addSublayer(flash)
            let f = CAKeyframeAnimation(keyPath: "opacity")
            f.values = [1, 0.4, 0.8, 0]
            f.duration = 0.18
            flash.add(f, forKey: "flash")
            after(0.2) { flash.removeFromSuperlayer() }
        } else {
            zap()
        }
        canvas.flare(at: p, size: 18, color: UIColor(red: 0.85, green: 0.82, blue: 1, alpha: 1), opacity: 0.8, duration: 0.2)
        loop()
    }

    private func zap() {
        guard let canvas else { return }
        let a = CGFloat.random(in: -.pi * 0.95 ... -.pi * 0.05)
        let d = CGFloat.random(in: 40...90) * CGFloat(0.8 + 0.25 * intensity)
        canvas.bolt(from: point, to: CGPoint(x: point.x + cos(a) * d, y: point.y + sin(a) * d))
    }

    private func loop() {
        after(0.13) { [weak self] in
            guard let self, self.alive else { return }
            self.zap()
            self.loop()
        }
    }

    func move(to p: CGPoint) { point = p }
    func end() { alive = false }
}

// MARK: - Ripple: rings spread from your touch.

@MainActor
private final class RipplePress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private var point: CGPoint
    private var alive = true
    private let radius: CGFloat

    init(canvas: EffectsCanvasView, at p: CGPoint, intensity: Double) {
        self.canvas = canvas
        self.point = p
        radius = 55 * CGFloat(0.8 + 0.25 * intensity)
        canvas.ring(at: p, radius: radius, color: canvas.rippleColor)
        canvas.ring(at: p, radius: radius * 0.8, color: canvas.rippleColor, delay: 0.12)
        loop()
    }

    private func loop() {
        after(0.37) { [weak self] in
            guard let self, self.alive, let canvas = self.canvas else { return }
            canvas.ring(at: self.point, radius: self.radius * 0.8, color: canvas.rippleColor)
            self.loop()
        }
    }

    func move(to p: CGPoint) { point = p }
    func end() { alive = false }
}

// MARK: - Listening screen for Fire, Ice, Storm and Ripple.

@MainActor
private final class AmbientPress: EffectPress {
    private weak var canvas: EffectsCanvasView?
    private var emitter: CAEmitterLayer?
    private var alive = true
    private let effect: KeyboardTheme.Effect
    private let area: CGRect
    private let center: CGPoint

    init(canvas: EffectsCanvasView, effect: KeyboardTheme.Effect, area: CGRect, center: CGPoint) {
        self.canvas = canvas
        self.effect = effect
        self.area = area
        self.center = center
        switch effect {
        case .fire:
            let ember = canvas.cell(UIColor(red: 1, green: 0.55, blue: 0.15, alpha: 1), birthRate: 30, lifetime: 1.3, velocity: 80,
                                    velocityRange: 35, longitude: -.pi / 2, range: .pi / 10, scale: 0.3, scaleRange: 0.12,
                                    scaleSpeed: -0.2, alphaSpeed: -0.75, yAcceleration: -20)
            ember.greenRange = 0.3
            emitter = canvas.emitter(at: CGPoint(x: area.midX, y: area.maxY), shape: .line,
                                     size: CGSize(width: area.width, height: 1), cells: [ember])
        case .ice:
            let snow = canvas.cell(UIColor(red: 0.92, green: 0.97, blue: 1, alpha: 1), birthRate: 14, lifetime: 4, velocity: 18,
                                   velocityRange: 8, longitude: .pi / 2, range: .pi / 8, scale: 0.14, scaleRange: 0.08,
                                   alphaSpeed: -0.2, yAcceleration: 6, spin: 1, spinRange: 2)
            emitter = canvas.emitter(at: CGPoint(x: area.midX, y: area.minY), shape: .line,
                                     size: CGSize(width: area.width, height: 1), cells: [snow])
        default:
            break
        }
        loop()
    }

    private func loop() {
        let interval: Double
        switch effect {
        case .storm: interval = .random(in: 0.5...1.1)
        case .ripple: interval = 0.55
        case .ice: interval = 0.9
        default: return
        }
        after(interval) { [weak self] in
            guard let self, self.alive, let canvas = self.canvas else { return }
            switch self.effect {
            case .storm:
                let y = CGFloat.random(in: self.area.minY + 10...self.area.maxY - 10)
                canvas.bolt(from: CGPoint(x: .random(in: 0...self.area.width * 0.3), y: y),
                            to: CGPoint(x: .random(in: self.area.width * 0.7...self.area.width), y: y + .random(in: -30...30)),
                            width: 0.9, roughness: 20)
            case .ripple:
                canvas.ring(at: self.center, radius: 90, color: canvas.rippleColor, duration: 1.1)
            case .ice:
                canvas.flare(at: CGPoint(x: .random(in: 20...self.area.width - 20), y: .random(in: self.area.minY...self.area.maxY)),
                             size: 8, color: .white, opacity: 0.9, duration: 0.6)
            default:
                break
            }
            self.loop()
        }
    }

    func move(to p: CGPoint) {}

    func end() {
        alive = false
        canvas?.retire(emitter, after: 4)
        emitter = nil
    }
}
