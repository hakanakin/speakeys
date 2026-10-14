import AppKit
import QuartzCore

/// The floating wireframe orb: rests calmly, and comes alive with the voice while dictating.
///
/// Edges are stroked by `CAShapeLayer`s, so rasterizing and the glow happen in the window
/// server on the GPU. The app only computes ~640 projected points per frame.
final class OrbView: NSView {
    var isDictating = false
    var motion: Motion = .balanced
    /// The orb's resting color. While dictating it brightens toward white.
    var tint = OrbColor.pink.nsColor {
        didSet { activeTint = tint.blended(withFraction: 0.65, of: .white) ?? tint }
    }
    private var activeTint = OrbColor.pink.nsColor.blended(withFraction: 0.65, of: .white) ?? .white
    /// Current microphone loudness, 0…1.
    var voiceLevel: () -> Float = { 0 }

    private let mesh = Icosphere(subdivisions: 3)
    private let glowLayer = CALayer()
    /// Back-to-front groups of edges, so the far side of the orb can be drawn fainter.
    private let depthLayers: [CAShapeLayer]
    private var points: [CGPoint]
    private var depths: [Double]

    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var skipNextFrame = false

    // Animation state
    private var time = 0.0    // seconds; drives breathing and tilt
    private var spin = 0.0    // rotation angle
    private var phase = 0.0   // surface flow
    private var voice = 0.0   // smoothed loudness
    private var focus = 0.0   // 0 resting … 1 dictating, eased

    private static let depthBuckets = 5

    override init(frame: NSRect) {
        depthLayers = (0..<Self.depthBuckets).map { _ in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            return layer
        }
        points = Array(repeating: .zero, count: mesh.vertices.count)
        depths = Array(repeating: 0, count: mesh.vertices.count)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = .clear
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)
        // Farthest bucket first so nearer edges are drawn on top
        for depthLayer in depthLayers.reversed() { glowLayer.addSublayer(depthLayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds
        for depthLayer in depthLayers { depthLayer.frame = bounds }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for depthLayer in depthLayers { depthLayer.contentsScale = scale }
    }

    // MARK: Animation loop

    func startAnimating() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        advance(by: dt)

        // At rest the orb moves slowly, so 30 fps is plenty
        let resting = !isDictating && focus < 0.01 && voice < 0.01
        if resting {
            skipNextFrame.toggle()
            if skipNextFrame { return }
        }
        // Don't draw while covered by a full-screen app or on a sleeping display
        guard window?.occlusionState.contains(.visible) == true else { return }
        render()
    }

    private func advance(by dt: Double) {
        let m = motion.profile
        let target = Double(voiceLevel())
        // Follow the voice's envelope rather than every syllable
        ease(&voice, to: target, rate: target > voice ? m.attack : m.release, dt: dt)
        ease(&focus, to: isDictating ? 1 : 0, rate: m.wake, dt: dt)
        time += dt
        spin += dt * (0.10 + m.spin * focus)
        phase += dt * (0.22 + m.flowFocus * focus + m.flowVoice * voice)
    }

    /// Frame-rate independent exponential easing; `rate` is the fraction covered per 1/60 s.
    private func ease(_ value: inout Double, to target: Double, rate: Double, dt: Double) {
        value += (target - value) * (1 - pow(1 - rate, dt * 60))
    }

    // MARK: Rendering

    private func render() {
        let m = motion.profile
        let size = Double(min(bounds.width, bounds.height))
        let breath = sin(time * 0.9) * 0.012 * (1 - focus)
        let radius = (0.21 + breath + 0.04 * focus + m.swell * voice) * size
        let amplitude = 0.06 + m.wobbleFocus * focus + m.wobbleVoice * voice
        let center = (x: Double(bounds.midX), y: Double(bounds.midY))

        let tilt = 0.35 + sin(time * 0.15) * 0.15
        let (sinY, cosY) = (sin(spin), cos(spin))
        let (sinX, cosX) = (sin(tilt), cos(tilt))

        for (i, v) in mesh.vertices.enumerated() {
            let r = 1 + amplitude * orbWobble(v, phase: phase)
            var (x, y, z) = (v.x * r, v.y * r, v.z * r)
            (x, z) = (x * cosY + z * sinY, -x * sinY + z * cosY)
            (y, z) = (y * cosX - z * sinX, y * sinX + z * cosX)
            let perspective = 3.2 / (3.2 + z)
            points[i] = CGPoint(x: center.x + x * radius * perspective, y: center.y + y * radius * perspective)
            depths[i] = z
        }

        let paths = (0..<Self.depthBuckets).map { _ in CGMutablePath() }
        for (a, b) in mesh.edges {
            let z = (depths[a] + depths[b]) / 2   // about -1.5 (near) … 1.5 (far)
            let bucket = min(max(Int((z + 1.5) / 3 * Double(Self.depthBuckets)), 0), Self.depthBuckets - 1)
            paths[bucket].move(to: points[a])
            paths[bucket].addLine(to: points[b])
        }

        let color = tint.blended(withFraction: focus * 0.6, of: activeTint) ?? tint
        let brightness = 0.55 + 0.45 * focus

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bucket, layer) in depthLayers.enumerated() {
            let alpha = (0.95 - Double(bucket) / Double(Self.depthBuckets - 1) * 0.75) * brightness
            layer.path = paths[bucket]
            layer.strokeColor = color.withAlphaComponent(alpha).cgColor
            layer.lineWidth = 0.8 + 0.6 * focus
        }
        glowLayer.shadowColor = color.cgColor
        glowLayer.shadowOpacity = Float(0.35 + 0.5 * focus)
        glowLayer.shadowRadius = 1.5 + 5 * focus + m.glow * voice
        CATransaction.commit()
    }
}
