import SwiftUI

/// The first page of Setup: the den wakes up. An aurora drifts, fireflies rise, and the gecko
/// walks in along a curve leaving glowing footprints. It settles in the middle (a pulse ripples
/// out), curls its tail, then turns to watch the pointer; click it and it flicks its tongue.
/// Everything is drawn in one Canvas from cached poses, so it stays smooth. Reduce Motion
/// shows the settled frame.
struct WelcomeScene: View {
    /// Fired once when the gecko has arrived (the page reveals its text then).
    var onArrive: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    @State private var pointer: CGPoint?
    @State private var poke: Date = .distantPast
    @State private var arrived = false

    static let walkDuration = 2.4
    private static let settleDuration = 0.7
    private static let geckoSize: CGFloat = 116

    /// Walk cycle and idle sway, computed once (a silhouette is dozens of path unions).
    private static let walkFrames: [Path] = (0..<16).map { index in
        let wave = CGFloat(sin(Double(index) / 16 * 2 * Double.pi))
        let pose = LizardGeometry.Pose(tailCurl: 0.3, sway: wave * 0.9, legPhase: wave, eyesOpen: 1)
        return LizardGeometry.silhouette(pose)
    }
    private static let settleFrames: [Path] = (0...8).map { index in
        let curl: CGFloat = 0.3 + 0.6 * CGFloat(index) / 8
        return LizardGeometry.silhouette(LizardGeometry.Pose(tailCurl: curl, sway: 0, legPhase: 0, eyesOpen: 1))
    }
    private static let idleFrames: [Path] = (0..<12).map { index in
        let wave = CGFloat(sin(Double(index) / 12 * 2 * Double.pi))
        let pose = LizardGeometry.Pose(tailCurl: 0.9 + wave * 0.06, sway: wave * 0.3, legPhase: 0, eyesOpen: 1)
        return LizardGeometry.silhouette(pose)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? 100 : context.date.timeIntervalSince(start)
            let sincePoke = context.date.timeIntervalSince(poke)
            Canvas { canvas, size in
                drawAurora(&canvas, size: size, time: elapsed)
                drawFireflies(&canvas, size: size, time: elapsed)
                drawFootprints(&canvas, size: size, time: elapsed)
                drawRipples(&canvas, size: size, time: elapsed)
                drawGecko(&canvas, size: size, time: elapsed, sincePoke: sincePoke)
                drawSparks(&canvas, size: size, sincePoke: sincePoke)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer = location } else { pointer = nil }
        }
        .onTapGesture { location in
            guard arrived else { return }
            poke = .now
        }
        .task {
            start = .now
            if reduceMotion {
                arrive()
                return
            }
            try? await Task.sleep(for: .seconds(Self.walkDuration))
            arrive()
        }
        .accessibilityLabel("Lizard's gecko walks in and settles")
    }

    private func arrive() {
        guard !arrived else { return }
        arrived = true
        onArrive()
    }

    // MARK: Path of the walk

    /// Cubic curve from below the bottom-left edge to the centre.
    private func walkPoint(_ t: Double, size: CGSize) -> CGPoint {
        let p0 = CGPoint(x: size.width * 0.12, y: size.height + 90)
        let p1 = CGPoint(x: size.width * 0.05, y: size.height * 0.45)
        let p2 = CGPoint(x: size.width * 0.72, y: size.height * 0.85)
        let p3 = CGPoint(x: size.width / 2, y: size.height * 0.5)
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// Ease-out walk: brisk entrance, gentle stop.
    private func progress(_ time: Double) -> Double {
        let t = min(1, max(0, time / Self.walkDuration))
        return 1 - pow(1 - t, 2.2)
    }

    /// Heading as a rotation for a mark whose head points up.
    private func heading(_ time: Double, size: CGSize) -> Double {
        let t = progress(time)
        let a = walkPoint(max(0, t - 0.01), size: size)
        let b = walkPoint(min(1, t + 0.01), size: size)
        return atan2(b.y - a.y, b.x - a.x) + .pi / 2
    }

    private func geckoTransform(at point: CGPoint, rotation: Double, scale: CGFloat = 1) -> CGAffineTransform {
        let side = Self.geckoSize * scale
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        return LizardGeometry.transform(in: rect)
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    // MARK: Layers

    private func drawAurora(_ canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let blobs: [(Color, Double, Double, CGFloat)] = [(Brand.moss, 0.11, 0, 0.62), (Brand.teal, 0.08, 2.1, 0.55), (Brand.moss, 0.06, 4.2, 0.4)]
        canvas.drawLayer { layer in
            layer.addFilter(.blur(radius: 40))
            for (color, speed, offset, radius) in blobs {
                let center = CGPoint(
                    x: size.width * (0.5 + 0.32 * CGFloat(sin(time * speed + offset))),
                    y: size.height * (0.5 + 0.22 * CGFloat(cos(time * speed * 1.3 + offset))))
                let r = min(size.width, size.height) * radius
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                layer.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0)]), center: center, startRadius: 0, endRadius: r))
            }
        }
    }

    private func drawFireflies(_ canvas: inout GraphicsContext, size: CGSize, time: Double) {
        for index in 0..<36 {
            let seed = Double(index) * 12.9898
            let x = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let speed = 6 + abs((sin(seed * 1.7) * 9631.17).truncatingRemainder(dividingBy: 1)) * 14
            let rise = (time * speed + abs(x) * 900).truncatingRemainder(dividingBy: size.height + 40)
            let point = CGPoint(x: size.width * abs(x) + CGFloat(sin(time * 0.7 + seed)) * 10, y: size.height + 20 - rise)
            let twinkle = 0.25 + 0.75 * (0.5 + 0.5 * sin(time * 2.4 + seed))
            let r: CGFloat = index % 5 == 0 ? 2.2 : 1.3
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - r * 3, y: point.y - r * 3, width: r * 6, height: r * 6)),
                        with: .radialGradient(Gradient(colors: [Brand.moss.opacity(0.35 * twinkle), .clear]), center: point, startRadius: 0, endRadius: r * 3))
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - r / 2, y: point.y - r / 2, width: r, height: r)), with: .color(Brand.sand.opacity(0.8 * twinkle)))
        }
    }

    /// Paw prints stamped along the walk, glowing then fading.
    private func drawFootprints(_ canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let step = 0.16
        var stamp = 0.0
        var index = 0
        while stamp < min(time, Self.walkDuration) {
            let age = time - stamp
            let alpha = max(0, 1 - age / 2.6)
            if alpha > 0 {
                let frame = (index * 4) % Self.walkFrames.count
                let transform = geckoTransform(at: walkPoint(progress(stamp), size: size), rotation: heading(stamp, size: size))
                let phase = CGFloat(sin(Double(frame) / 16 * 2 * .pi))
                let feet = LizardGeometry.legJoints(phase: phase)
                // Alternate pairs, like a real trot: front-left + back-right, then the other two.
                for foot in index % 2 == 0 ? [feet[0], feet[3]] : [feet[1], feet[2]] {
                    let point = foot.foot.applying(transform)
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(Brand.moss.opacity(0.55 * alpha)))
                }
            }
            stamp += step
            index += 1
        }
    }

    private func drawRipples(_ canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for delay in [0.0, 0.35] {
            let age = time - Self.walkDuration - delay
            guard age > 0, age < 1.6 else { continue }
            let t = age / 1.6
            let radius = 40 + CGFloat(t) * 170
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            canvas.stroke(ring, with: .color(Brand.moss.opacity(0.5 * (1 - t))), lineWidth: 1.5)
        }
    }

    private func drawGecko(_ canvas: inout GraphicsContext, size: CGSize, time: Double, sincePoke: Double) {
        let walking = time < Self.walkDuration
        let settle = (time - Self.walkDuration) / Self.settleDuration
        var point = walkPoint(progress(time), size: size)
        var rotation = walking ? heading(time, size: size) : heading(Self.walkDuration, size: size)
        let path: Path
        if walking {
            let frame = Int(time * 9) % Self.walkFrames.count
            path = Self.walkFrames[frame]
        } else if settle < 1 {
            path = Self.settleFrames[min(8, Int(settle * 9))]
            rotation *= max(0, 1 - settle)  // turn to face up
        } else {
            let wiggle = sincePoke < 0.8 ? 5.0 : 1.0
            path = Self.idleFrames[Int(time * 6 * wiggle) % Self.idleFrames.count]
            rotation = gaze(from: point)
            point.y += CGFloat(sin(time * 1.6)) * 2  // breathing
        }
        let transform = geckoTransform(at: point, rotation: rotation)
        let body = path.applying(transform)

        // Glow, then the body in the brand gradient.
        canvas.drawLayer { glow in
            glow.addFilter(.blur(radius: 18))
            glow.fill(body, with: .color(Brand.moss.opacity(0.55)))
        }
        let bounds = body.boundingRect
        canvas.fill(body, with: .linearGradient(Gradient(colors: [Brand.moss, Brand.teal]), startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))

        if sincePoke < 0.45 {
            let length = CGFloat(sin(sincePoke / 0.45 * .pi))
            canvas.stroke(LizardGeometry.tongue(length: length).applying(transform), with: .color(Color(hex: 0xFF6B8B)),
                          style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }

    /// After settling, the head turns toward the pointer (limited, so it never looks broken).
    private func gaze(from point: CGPoint) -> Double {
        guard let pointer else { return 0 }
        let angle = atan2(pointer.y - point.y, pointer.x - point.x) + .pi / 2
        let wrapped = atan2(sin(angle), cos(angle))
        return max(-0.6, min(0.6, wrapped)) * 0.8
    }

    private func drawSparks(_ canvas: inout GraphicsContext, size: CGSize, sincePoke: Double) {
        guard sincePoke < 0.9 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 30)
        let t = sincePoke / 0.9
        for index in 0..<14 {
            let angle = Double(index) / 14 * 2 * .pi + 0.3
            let distance = 30 + CGFloat(t) * 70
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * distance, y: center.y + CGFloat(sin(angle)) * distance * 0.8)
            let r = 2.4 * CGFloat(1 - t)
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                        with: .color((index % 2 == 0 ? Brand.moss : Brand.sand).opacity(1 - t)))
        }
    }
}

/// "lizard", one letter at a time, each springing up out of a blur.
struct WelcomeWordmark: View {
    var visible: Bool
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: -size * 0.03) {
            ForEach(Array("lizard".enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.gradient)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : size * 0.5)
                    .blur(radius: visible ? 0 : 8)
                    .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(Double(index) * 0.06), value: visible)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lizard")
    }
}

#Preview("Welcome scene") {
    WelcomeScene()
        .frame(width: 600, height: 280)
        .background(Brand.ink)
}
