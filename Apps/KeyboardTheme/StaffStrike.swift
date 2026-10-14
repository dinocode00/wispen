import QuartzCore
import UIKit

/// The 15× combo reward: a small glowing silhouette of Gandalf's arm reaches in, strikes his staff
/// down, and waves of lightning-and-fire power surge across the keyboard.
///
/// One Core Animation sequence of about 2½ seconds, drawn see-through over the keys (typing keeps
/// working underneath). Nothing exists before it starts, and it's all removed when it ends.
extension EffectsCanvasView {
    /// Animation time runs at 3/4 of real time, for weight; the timings below are in animation time.
    private static let pace = 0.75
    private enum T {
        static let reach = 0.28, wind = 0.46, hit = 0.53, hold = 0.9, gone = 1.2, end = 1.9
    }
    private static func real(_ t: Double) -> Double { t / pace }

    func staffStrike(fromRight: Bool = true) {
        guard bounds.width > 40, bounds.height > 80, layer.value(forKey: "staffStrike") == nil else { return }
        let W = bounds.width, H = bounds.height
        let ground = H - 12
        let L = min(80, max(58, H * 0.31)) // staff length: under a third of the keyboard's height
        let hitX = W * 0.24                // measured from the side the arm comes in from
        let impact = CGPoint(x: fromRight ? W - hitX : hitX, y: ground)

        let fx = CALayer()
        fx.frame = bounds
        fx.opacity = 0.78 // see-through, so the keys stay readable
        layer.addSublayer(fx)
        layer.setValue(true, forKey: "staffStrike")

        addArm(to: fx, L: L, ground: ground, hitX: hitX, fromRight: fromRight)
        after(Self.real(T.hit)) { [weak self] in
            guard let self else { return }
            self.addImpact(to: fx, at: impact, ground: ground)
            self.shakeKeyboard()
        }
        after(Self.real(T.end) + 1.2) { [weak self] in
            fx.removeFromSuperlayer()
            self?.layer.setValue(nil, forKey: "staffStrike")
        }
    }

    // MARK: The arm and staff

    private struct Pose { var x: CGFloat, y: CGFloat, ang: CGFloat }

    private func addArm(to fx: CALayer, L: CGFloat, ground: CGFloat, hitX: CGFloat, fromRight: Bool) {
        // Drawn as if coming from the left; mirrored for the right.
        let root = CALayer()
        root.frame = fx.bounds
        if fromRight { root.transform = CATransform3DMakeScale(-1, 1, 1) }
        fx.addSublayer(root)

        // One dark silhouette with a wide blue glow and a thin bright rim.
        let arm = CALayer()
        arm.shadowColor = UIColor(red: 0.35, green: 0.59, blue: 1, alpha: 1).cgColor
        arm.shadowOpacity = 0.95
        arm.shadowRadius = 11
        arm.shadowOffset = .zero
        root.addSublayer(arm)

        let dark = UIColor(red: 0.01, green: 0.012, blue: 0.024, alpha: 1).cgColor
        let rim = UIColor(red: 0.8, green: 0.89, blue: 1, alpha: 0.9).cgColor
        func silhouette(_ path: CGPath) -> CAShapeLayer {
            let s = CAShapeLayer()
            s.path = path
            s.fillColor = dark
            s.strokeColor = rim
            s.lineWidth = 0.9
            return s
        }
        let sleeve = silhouette(Self.sleevePath(L: L))
        let staff = silhouette(Self.staffPath(L: L))
        arm.addSublayer(sleeve)
        arm.addSublayer(staff)

        // Light gathering in the hollow of the staff's crown.
        let z = L / 77
        let orb = CAGradientLayer()
        orb.type = .radial
        orb.colors = [UIColor(white: 1, alpha: 0.8).cgColor,
                      UIColor(red: 0.67, green: 0.8, blue: 1, alpha: 0.45).cgColor,
                      UIColor(red: 0.31, green: 0.51, blue: 1, alpha: 0).cgColor]
        orb.locations = [0, 0.35, 1]
        orb.startPoint = CGPoint(x: 0.5, y: 0.5)
        orb.endPoint = CGPoint(x: 1, y: 1)
        orb.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        orb.position = CGPoint(x: 0.4 * z, y: -L * 0.37)
        orb.opacity = 0
        staff.addSublayer(orb)

        // Hand position and staff angle (from vertical; negative tips the head back).
        let off = Pose(x: -L * 0.9, y: ground - L * 0.95, ang: -0.9)
        let enter = Pose(x: hitX - L * 0.22, y: ground - L * 0.88, ang: -0.35)
        let raised = Pose(x: hitX - L * 0.16, y: ground - L * 1.08, ang: -0.85)
        let down = Pose(x: hitX, y: ground - L * 0.7, ang: 0.02)
        let poses = [off, enter, raised, down, down, off, off]
        let times = [0, T.reach, T.wind, T.hit, T.hold, T.gone, T.end].map { NSNumber(value: $0 / T.end) }
        let curves: [CAMediaTimingFunction] = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(controlPoints: 0.55, 0, 1, 0.45),
                                               .init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
        let duration = Self.real(T.end)

        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = poses.map { NSValue(cgPoint: CGPoint(x: $0.x, y: $0.y)) }
        move.keyTimes = times
        move.timingFunctions = curves
        move.duration = duration
        arm.position = CGPoint(x: off.x, y: off.y)
        arm.add(move, forKey: "move")

        // The staff turns about the hand. (A layer's rotation turns "up" the opposite way to the angle.)
        let swing = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        swing.values = poses.map { -$0.ang }
        swing.keyTimes = times
        swing.timingFunctions = curves
        swing.duration = duration
        staff.transform = CATransform3DMakeRotation(-off.ang, 0, 0, 1)
        staff.add(swing, forKey: "swing")

        // The crown brightens as he winds up, and fades as he withdraws.
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 0, 1, 1, 0, 0]
        glow.keyTimes = [0, 0.12, T.hit, T.hold, T.hold + 0.3, T.end].map { NSNumber(value: $0 / T.end) }
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [0.3, 0.3, 1, 1, 0.5, 0.5]
        grow.keyTimes = glow.keyTimes
        let orbAnim = CAAnimationGroup()
        orbAnim.animations = [glow, grow]
        orbAnim.duration = duration
        orb.add(orbAnim, forKey: "orb")
    }

    /// Gandalf the Grey's staff, as in the films: an upturned, twisted sapling whose top swells into
    /// a knobbly bulb and splays into a crown of short, snapped-off roots. The hand is at (0, 0) and
    /// the staff points up; the fist is part of the shape.
    private static func staffPath(L: CGFloat) -> CGPath {
        let z = L / 77
        func P(_ u: CGFloat, _ side: CGFloat) -> CGPoint { CGPoint(x: side, y: -L * u) }
        let out = CGMutablePath()
        func stroke(_ p: CGPath, width: CGFloat, cap: CGLineCap = .round) {
            out.addPath(p.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 4))
        }
        func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ angle: CGFloat) {
            out.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2),
                           transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
        }

        // The shaft, slightly crooked.
        let shaft = CGMutablePath()
        shaft.move(to: P(-0.7, 0))
        for (u, w) in [(-0.5, 0.7), (-0.28, -0.6), (-0.05, 0.5), (0.16, -0.4), (0.26, 0.0)] as [(CGFloat, CGFloat)] {
            shaft.addLine(to: P(u, w * z))
        }
        stroke(shaft, width: max(2.2, 2.9 * z))
        // Weathered twists spiralling round it.
        for (u, w) in [(-0.58, 1.5), (-0.42, -1.5), (-0.24, 1.4), (-0.08, -1.4), (0.08, 1.4), (0.19, -1.5)] as [(CGFloat, CGFloat)] {
            ellipse(P(u, w * z), 1.3 * z, 2.4 * z, 0.6 * (w > 0 ? 1 : -1))
        }
        // The bulb, and the crown of snapped roots splaying up and out (blunt where they broke).
        ellipse(P(0.28, 0.3 * z), 3.6 * z, 3.4 * z, 0)
        for (side, u, w) in [(-7.5, 0.35, 2.0), (-4.2, 0.41, 2.2), (0.6, 0.44, 2.3), (4.6, 0.415, 2.2), (7.8, 0.355, 1.9)] as [(CGFloat, CGFloat, CGFloat)] {
            let root = CGMutablePath()
            root.move(to: P(0.3, side * 0.25 * z))
            root.addQuadCurve(to: P(u, side * z), control: P(u - 0.02, side * 0.55 * z))
            stroke(root, width: w * z, cap: .butt)
        }
        for (u0, s0, u1, s1) in [(0.33, -5.2, 0.37, -9.5), (0.34, 5.6, 0.39, 9.8)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let twig = CGMutablePath()
            twig.move(to: P(u0, s0 * z))
            twig.addLine(to: P(u1, s1 * z))
            stroke(twig, width: 1.2 * z, cap: .butt)
        }
        // The fist round the staff: palm, and a row of knuckles at the front.
        let f = L / 230 * 1.15
        out.addRoundedRect(in: CGRect(x: -12 * f, y: -11 * f, width: 23 * f, height: 24 * f), cornerWidth: 8 * f, cornerHeight: 8 * f)
        for i in 0..<4 { ellipse(CGPoint(x: 7 * f, y: (-7 + CGFloat(i) * 5.6) * f), 4.6 * f, 3.2 * f, 0) }
        return out.normalized()
    }

    /// The grey robe sleeve, from off-screen to the wrist, with a bell drape hanging below.
    /// Relative to the hand at (0, 0); it doesn't turn with the staff.
    private static func sleevePath(L: CGFloat) -> CGPath {
        let f = L / 230
        let wrist = CGPoint(x: -12 * f, y: f), sh = CGPoint(x: -230 * f, y: -30 * f)
        let dx = wrist.x - sh.x, dy = wrist.y - sh.y, len = max(1, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len
        func at(_ u: CGFloat, _ o: CGFloat) -> CGPoint { CGPoint(x: sh.x + dx * u + nx * o * f, y: sh.y + dy * u + ny * o * f) }
        let p = CGMutablePath()
        p.move(to: at(-0.6, -34))
        p.addQuadCurve(to: at(0.98, -13), control: at(0.5, -26))
        p.addLine(to: at(1, 14))
        p.addCurve(to: at(0.45, 76), control1: at(0.92, 50), control2: at(0.62, 84))
        p.addQuadCurve(to: at(-0.6, 60), control: at(0.1, 70))
        p.closeSubpath()
        return p
    }

    // MARK: The surge of magic

    private func addImpact(to fx: CALayer, at c: CGPoint, ground: CGFloat) {
        let W = bounds.width, H = bounds.height
        let now = CACurrentMediaTime()

        // A soft flash.
        let flash = CALayer()
        flash.frame = fx.bounds
        flash.backgroundColor = UIColor(red: 0.9, green: 0.92, blue: 1, alpha: 1).cgColor
        flash.opacity = 0
        fx.addSublayer(flash)
        let flashAnim = CABasicAnimation(keyPath: "opacity")
        flashAnim.fromValue = 0.38
        flashAnim.toValue = 0
        flashAnim.duration = Self.real(0.3)
        flashAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
        flash.add(flashAnim, forKey: "flash")

        // The glow at the heart, throbbing in time with the surges.
        let heartR = 40 + max(W, H) * 0.55
        let heart = radial(radius: heartR, colors: [
            (0, UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 0.8)),
            (0.25, UIColor(red: 0.51, green: 0.69, blue: 1, alpha: 0.45)),
            (0.6, UIColor(red: 1, green: 0.47, blue: 0.16, alpha: 0.18)),
            (1, UIColor(red: 0.78, green: 0.16, blue: 0.04, alpha: 0)),
        ])
        heart.position = c
        heart.opacity = 0
        fx.addSublayer(heart)
        let throb = CAKeyframeAnimation(keyPath: "opacity")
        let steps = 40
        throb.values = (0...steps).map { i -> Float in
            let e = 1.25 * Double(i) / Double(steps)
            return Float((1 - e / 1.25) * (0.75 + 0.25 * sin(e * 26)))
        }
        let heartGrow = CABasicAnimation(keyPath: "transform.scale")
        heartGrow.fromValue = 40 / heartR
        heartGrow.toValue = 1
        heartGrow.duration = Self.real(0.4)
        heartGrow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let heartAnim = CAAnimationGroup()
        heartAnim.animations = [throb, heartGrow]
        throb.duration = Self.real(1.25)
        heartAnim.duration = Self.real(1.25)
        heart.add(heartAnim, forKey: "heart")

        // A pillar of light.
        let pillar = CAGradientLayer()
        pillar.colors = [UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 0.2).cgColor, UIColor.white.cgColor]
        pillar.frame = CGRect(x: c.x - 19, y: 0, width: 38, height: ground)
        pillar.opacity = 0
        fx.addSublayer(pillar)
        let pillarFade = CABasicAnimation(keyPath: "opacity")
        pillarFade.fromValue = 1
        pillarFade.toValue = 0
        let pillarThin = CABasicAnimation(keyPath: "transform.scale.x")
        pillarThin.fromValue = 1
        pillarThin.toValue = 0.15
        let pillarAnim = CAAnimationGroup()
        pillarAnim.animations = [pillarFade, pillarThin]
        pillarAnim.duration = Self.real(0.5)
        pillar.add(pillarAnim, forKey: "pillar")

        // Five waves of power, each weaker than the last.
        let reach = hypot(max(c.x, W - c.x), c.y) + 40
        for (n, (start, strength)) in [(0.0, 1.0), (0.13, 0.85), (0.28, 0.75), (0.46, 0.6), (0.68, 0.45)].enumerated() {
            addWave(to: fx, at: c, reach: reach, index: n, strength: strength, begin: now + Self.real(start))
        }

        // Fire licking up from the strike, fed by a blue lick at its base; then embers and motes.
        let flame = cell(UIColor(red: 1, green: 0.8, blue: 0.5, alpha: 1), birthRate: 260, lifetime: 0.85, velocity: 170,
                         velocityRange: 90, longitude: -.pi / 2, range: .pi / 6, scale: 0.55, scaleRange: 0.2,
                         scaleSpeed: -0.45, alphaSpeed: -1.1, yAcceleration: -60)
        flame.greenSpeed = -0.75
        flame.blueSpeed = -0.6
        let base = cell(UIColor(red: 0.55, green: 0.7, blue: 1, alpha: 1), birthRate: 90, lifetime: 0.3, velocity: 40,
                        velocityRange: 20, longitude: -.pi / 2, range: .pi / 4, scale: 0.4, scaleSpeed: -0.6, alphaSpeed: -3)
        let fire = emitter(at: c, shape: .line, mode: .outline, size: CGSize(width: 70, height: 0), cells: [flame, base])
        fx.addSublayer(fire)
        burst(fire, for: Self.real(0.5), cleanupAfter: 2.4)

        let white = cell(UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1), birthRate: 1100, lifetime: 0.95, velocity: 420,
                         velocityRange: 260, longitude: -.pi / 2, range: 1.5, scale: 0.09, scaleRange: 0.04,
                         alphaSpeed: -1.1, yAcceleration: 600)
        let ember = cell(UIColor(red: 1, green: 0.59, blue: 0.24, alpha: 1), birthRate: 1100, lifetime: 0.95, velocity: 380,
                         velocityRange: 240, longitude: -.pi / 2, range: 1.5, scale: 0.09, scaleRange: 0.04,
                         alphaSpeed: -1.1, yAcceleration: 600)
        let sparks = emitter(at: c, cells: [white, ember])
        fx.addSublayer(sparks)
        burst(sparks, for: 0.06, cleanupAfter: 1.6)

        let mote = cell(UIColor(red: 0.67, green: 0.8, blue: 1, alpha: 1), birthRate: 30, lifetime: 1.6, velocity: 45,
                        velocityRange: 25, longitude: -.pi / 2, range: .pi / 3, scale: 0.06, alphaSpeed: -0.6)
        let motes = emitter(at: c, shape: .line, mode: .outline, size: CGSize(width: W * 0.8, height: 0), cells: [mote])
        fx.addSublayer(motes)
        burst(motes, for: 1.2, cleanupAfter: 3)
    }

    /// One wave: a rippling wavefront with a glowing band behind it, lightning crackling on its
    /// edge, and a ripple rolling along the ground. Drawn at full size and scaled up as it travels.
    private func addWave(to fx: CALayer, at c: CGPoint, reach: CGFloat, index n: Int, strength: Double, begin: CFTimeInterval) {
        let wave = CALayer()
        wave.position = c
        wave.opacity = 0
        fx.addSublayer(wave)
        let duration = Self.real(0.85)

        // Size over time, sampled so line widths can stay steady while the wave grows.
        let samples = 14
        let ks = (0...samples).map { Double($0) / Double(samples) }
        let scales = ks.map { k -> CGFloat in (12 + CGFloat(1 - pow(1 - k, 3)) * reach) / reach }
        let keyTimes = ks.map { NSNumber(value: $0) }

        // The band of energy just behind the front.
        let band = radial(radius: reach * 1.03, colors: [
            (0.78, UIColor(red: 1, green: 0.43, blue: 0.14, alpha: 0)),
            (0.88, UIColor(red: 1, green: 0.47, blue: 0.16, alpha: 0.14)),
            (0.95, UIColor(red: 0.47, green: 0.65, blue: 1, alpha: 0.3)),
            (0.985, UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 0.35)),
            (1, UIColor(red: 0.47, green: 0.65, blue: 1, alpha: 0)),
        ])
        wave.addSublayer(band)

        // The wavefront itself ripples: a few shapes of the same front, morphing into each other.
        let fronts = (0..<6).map { Self.front(reach: reach, phase: CGFloat($0) * 0.9 + CGFloat(n)) }
        for (width, color, alpha) in [(18.0, UIColor(red: 1, green: 0.43, blue: 0.14, alpha: 1), 0.16),
                                      (7.5, UIColor(red: 0.43, green: 0.59, blue: 1, alpha: 1), 0.4),
                                      (1.8, UIColor(red: 1, green: 0.98, blue: 0.92, alpha: 1), 0.9)] {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = color.withAlphaComponent(alpha).cgColor
            s.lineJoin = .round
            s.path = fronts[0]
            let ripple = CAKeyframeAnimation(keyPath: "path")
            ripple.values = fronts + [fronts[0]]
            ripple.duration = duration / 2
            ripple.repeatCount = 2
            let widthAnim = CAKeyframeAnimation(keyPath: "lineWidth")
            widthAnim.values = zip(ks, scales).map { k, sc in (CGFloat(width) * CGFloat(1 - k) + CGFloat(width) * 0.3) / sc }
            widthAnim.keyTimes = keyTimes
            widthAnim.duration = duration
            let g = CAAnimationGroup()
            g.animations = [ripple, widthAnim]
            g.duration = duration
            s.add(g, forKey: "front")
            wave.addSublayer(s)
        }

        // Lightning crackling along the front, re-forked every 50 ms.
        let crackleFrames = (0..<10).map { _ in Self.crackle(reach: reach) }
        for (width, color) in [(3.6, UIColor(red: 0.43, green: 0.63, blue: 1, alpha: 0.5)), (1.1, UIColor.white)] {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = color.cgColor
            s.lineCap = .round
            s.lineJoin = .round
            s.path = crackleFrames[0]
            let flicker = CAKeyframeAnimation(keyPath: "path")
            flicker.values = crackleFrames
            flicker.calculationMode = .discrete
            flicker.duration = 0.5
            flicker.repeatCount = 2
            let widthAnim = CAKeyframeAnimation(keyPath: "lineWidth")
            widthAnim.values = scales.map { CGFloat(width) / $0 }
            widthAnim.keyTimes = keyTimes
            widthAnim.duration = duration
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0, 0]
            fade.keyTimes = [0, 0.35, 0.7, 1]
            fade.duration = duration
            let g = CAAnimationGroup()
            g.animations = [flicker, widthAnim, fade]
            g.duration = duration
            s.add(g, forKey: "crackle")
            wave.addSublayer(s)
        }

        // A ripple rolling out along the ground, alternating blue and fire.
        let groundRipple = CAShapeLayer()
        groundRipple.fillColor = nil
        groundRipple.strokeColor = (n % 2 == 1 ? UIColor(red: 1, green: 0.59, blue: 0.24, alpha: 0.8)
                                               : UIColor(red: 0.67, green: 0.8, blue: 1, alpha: 0.8)).cgColor
        let rolls = (0..<5).map { Self.groundRipple(reach: reach, phase: CGFloat($0) * 1.2) }
        groundRipple.path = rolls[0]
        let roll = CAKeyframeAnimation(keyPath: "path")
        roll.values = rolls + [rolls[0]]
        roll.duration = duration / 3
        roll.repeatCount = 3
        let rollWidth = CAKeyframeAnimation(keyPath: "lineWidth")
        rollWidth.values = zip(ks, scales).map { k, sc in (3 * CGFloat(1 - k) + 0.6) / sc }
        rollWidth.keyTimes = keyTimes
        rollWidth.duration = duration
        let rollGroup = CAAnimationGroup()
        rollGroup.animations = [roll, rollWidth]
        rollGroup.duration = duration
        groundRipple.add(rollGroup, forKey: "roll")
        wave.addSublayer(groundRipple)

        // Grow outward and fade, starting at its moment.
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = scales
        grow.keyTimes = keyTimes
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = ks.map { Float(strength * pow(1 - $0, 1.3)) }
        fade.keyTimes = keyTimes
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = duration
        g.beginTime = begin
        g.fillMode = .backwards
        wave.add(g, forKey: "wave")
        after(begin - CACurrentMediaTime() + duration + 0.1) { wave.removeFromSuperlayer() }
    }

    /// The upper half of a rippled circle around (0, 0).
    private static func front(reach: CGFloat, phase: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0...72 {
            let th = CGFloat.pi + CGFloat(i) / 72 * .pi
            let r = reach * (1 + 0.035 * sin(5 * th + phase) + 0.015 * sin(11 * th - phase * 1.4))
            let pt = CGPoint(x: cos(th) * r, y: sin(th) * r * 0.92)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    /// A few short forks of lightning on the wavefront.
    private static func crackle(reach: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for _ in 0..<8 {
            let th = CGFloat.pi + CGFloat.random(in: 0...1) * .pi
            let a = CGPoint(x: cos(th) * reach, y: sin(th) * reach * 0.92)
            let len = reach * CGFloat.random(in: 0.05...0.12)
            let dir = th + .pi / 2 * (Bool.random() ? 1 : -1)
            let b = CGPoint(x: a.x + cos(dir) * len, y: a.y + sin(dir) * len)
            let pts = boltPoints(from: a, to: b, roughness: len * 0.5)
            p.move(to: pts[0])
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
        return p
    }

    /// A sine ripple along the ground, strongest near the strike.
    private static func groundRipple(reach: CGFloat, phase: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0...60 {
            let u = CGFloat(i) / 60 * 2 - 1
            let off = abs(u)
            let pt = CGPoint(x: u * reach * 1.3, y: -sin(off * 9 - phase) * 5 * (1 - off * 0.5))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    /// A round soft glow of `radius`, from color stops (location 0…1 from the center).
    private func radial(radius: CGFloat, colors: [(CGFloat, UIColor)]) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = colors.map { $0.1.cgColor }
        g.locations = colors.map { NSNumber(value: Double($0.0)) }
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        return g
    }

    /// A short, fading shake of the whole keyboard. Only how it looks moves; the keys' touch areas don't.
    private func shakeKeyboard() {
        // In the keyboard, the whole keyboard shakes; in the app's preview, just the preview.
        let inKeyboard = Bundle.main.bundlePath.hasSuffix(".appex")
        guard let target = inKeyboard ? (window?.rootViewController?.view.layer ?? superview?.layer) : superview?.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation")
        let n = 12
        shake.values = (0...n).map { i -> NSValue in
            let a = 4 * pow(1 - CGFloat(i) / CGFloat(n), 1.5)
            return NSValue(cgSize: CGSize(width: i == n ? 0 : .random(in: -a...a), height: i == n ? 0 : .random(in: -a...a)))
        }
        shake.duration = Self.real(0.45)
        shake.isAdditive = true
        target.add(shake, forKey: "staffStrikeShake")
    }
}
