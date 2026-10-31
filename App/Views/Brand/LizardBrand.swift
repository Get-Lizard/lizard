import SwiftUI

/// Brand colors: ink background, moss → teal gradient, warm sand.
enum Brand {
    static let ink = Color(hex: 0x0E1210)
    static let moss = Color(hex: 0x3DDC84)
    static let teal = Color(hex: 0x14B8A6)
    static let sand = Color(hex: 0xF4F1EA)
    static let gradient = LinearGradient(colors: [moss, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The gecko, seen from above, on a 100×100 grid: a rounded head flowing into a sturdy body,
/// a tail that tapers and rolls into a spiral, four bent legs with round toe pads. Built from
/// centerlines that are stroked and merged into one silhouette, so the same numbers give the
/// filled logo, the draw-on animation and every icon size.
enum LizardGeometry {
    static let grid: CGFloat = 100

    struct Pose: Equatable {
        /// 0 = tail swept out, 1 = rolled into a spiral.
        var tailCurl: CGFloat = 1
        /// -1…1 sideways bend of the body (walk / wag).
        var sway: CGFloat = 0
        /// -1…1 leg swing.
        var legPhase: CGFloat = 0
        /// 0…1 eye openness (blink).
        var eyesOpen: CGFloat = 1
    }

    /// Aspect-fit transform from the grid into `rect`.
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / grid
        let dx = rect.midX - grid * scale / 2
        let dy = rect.midY - grid * scale / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Neck to hips.
    static func torso(sway: CGFloat) -> Path {
        let s = sway * 2.5
        var path = Path()
        path.move(to: CGPoint(x: 50, y: 22))
        path.addCurve(to: CGPoint(x: 50 + s * 0.4, y: 46), control1: CGPoint(x: 50, y: 31), control2: CGPoint(x: 47 - s, y: 38))
        path.addCurve(to: CGPoint(x: 52, y: 64), control1: CGPoint(x: 53 + s, y: 54), control2: CGPoint(x: 53 + s * 0.5, y: 59))
        return path
    }

    /// Hips to tail tip.
    static func tail(curl: CGFloat, sway: CGFloat) -> Path {
        let t = max(0, min(1, curl))
        let w = sway * 2
        var path = Path()
        path.move(to: CGPoint(x: 52, y: 64))
        path.addCurve(
            to: lerp(CGPoint(x: 40 + w, y: 86), CGPoint(x: 41, y: 84), t),
            control1: CGPoint(x: 51, y: 71), control2: lerp(CGPoint(x: 45 + w, y: 77), CGPoint(x: 42, y: 76), t))
        path.addCurve(
            to: lerp(CGPoint(x: 24 + w * 2, y: 93), CGPoint(x: 60, y: 86), t),
            control1: lerp(CGPoint(x: 36 + w, y: 92), CGPoint(x: 40, y: 94), t),
            control2: lerp(CGPoint(x: 30 + w * 2, y: 95), CGPoint(x: 55, y: 96), t))
        path.addCurve(
            to: lerp(CGPoint(x: 15 + w * 2, y: 91), CGPoint(x: 51, y: 81), t),
            control1: lerp(CGPoint(x: 20 + w * 2, y: 92), CGPoint(x: 63, y: 79), t),
            control2: lerp(CGPoint(x: 17 + w * 2, y: 91), CGPoint(x: 55, y: 76), t))
        return path
    }

    /// Hip, elbow and foot for each leg (foot positions also place the toe pads).
    static func legJoints(phase: CGFloat) -> [(hip: CGPoint, knee: CGPoint, foot: CGPoint)] {
        let p = phase * 3
        return [
            (CGPoint(x: 48, y: 33), CGPoint(x: 32, y: 36 + p), CGPoint(x: 31, y: 25 + p)),  // front left
            (CGPoint(x: 52, y: 33), CGPoint(x: 68, y: 36 - p), CGPoint(x: 69, y: 25 - p)),  // front right
            (CGPoint(x: 51, y: 57), CGPoint(x: 35, y: 57 - p), CGPoint(x: 34, y: 69 - p)),  // back left
            (CGPoint(x: 53, y: 57), CGPoint(x: 69, y: 56 + p), CGPoint(x: 70, y: 68 + p)),  // back right
        ]
    }

    static func legs(phase: CGFloat) -> Path {
        var path = Path()
        for leg in legJoints(phase: phase) {
            path.move(to: leg.hip)
            path.addQuadCurve(to: leg.foot, control: leg.knee)
        }
        return path
    }

    static func feet(phase: CGFloat) -> Path {
        var path = Path()
        for leg in legJoints(phase: phase) {
            path.addEllipse(in: CGRect(x: leg.foot.x - 3.6, y: leg.foot.y - 3.6, width: 7.2, height: 7.2))
        }
        return path
    }

    /// Rounded head, slightly pointed at the nose.
    static var head: Path {
        var path = Path()
        path.move(to: CGPoint(x: 50, y: 4))
        path.addCurve(to: CGPoint(x: 61, y: 17), control1: CGPoint(x: 57, y: 4), control2: CGPoint(x: 61, y: 10))
        path.addCurve(to: CGPoint(x: 50, y: 29), control1: CGPoint(x: 61, y: 24), control2: CGPoint(x: 56, y: 29))
        path.addCurve(to: CGPoint(x: 39, y: 17), control1: CGPoint(x: 44, y: 29), control2: CGPoint(x: 39, y: 24))
        path.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 39, y: 10), control2: CGPoint(x: 43, y: 4))
        path.closeSubpath()
        return path
    }

    static func eyes(open: CGFloat) -> Path {
        let h = max(0.3, 3.4 * open)
        var path = Path()
        path.addEllipse(in: CGRect(x: 42.6, y: 13 - h / 2, width: 4.2, height: h))
        path.addEllipse(in: CGRect(x: 53.2, y: 13 - h / 2, width: 4.2, height: h))
        return path
    }

    /// A forked tongue out of the nose; `length` 0…1.
    static func tongue(length: CGFloat) -> Path {
        var path = Path()
        guard length > 0.01 else { return path }
        let tip = 4 - 6 * length
        path.move(to: CGPoint(x: 50, y: 5))
        path.addLine(to: CGPoint(x: 50, y: tip))
        path.addLine(to: CGPoint(x: 47.8, y: tip - 2.4 * length))
        path.move(to: CGPoint(x: 50, y: tip))
        path.addLine(to: CGPoint(x: 52.2, y: tip - 2.4 * length))
        return path
    }

    /// Tail stroked in slices of shrinking width, so it tapers to a point.
    static func taperedTail(curl: CGFloat, sway: CGFloat) -> Path {
        let centerline = tail(curl: curl, sway: sway)
        var outline = Path()
        let slices = 36
        for index in 0..<slices {
            let from = CGFloat(index) / CGFloat(slices)
            let to = min(1, CGFloat(index + 1) / CGFloat(slices) + 0.01)
            let width = 12.5 - 10.3 * pow(from, 0.85)
            let slice = centerline.trimmedPath(from: from, to: to).strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
            outline = outline.isEmpty ? slice : outline.union(slice)
        }
        return outline
    }

    /// The whole animal as one fill-able outline, eyes cut out.
    static func silhouette(_ pose: Pose) -> Path {
        let pieces = [
            torso(sway: pose.sway).strokedPath(StrokeStyle(lineWidth: 13, lineCap: .round)),
            taperedTail(curl: pose.tailCurl, sway: pose.sway),
            legs(phase: pose.legPhase).strokedPath(StrokeStyle(lineWidth: 5.2, lineCap: .round)),
            feet(phase: pose.legPhase),
        ]
        let shape = pieces.reduce(head) { $0.union($1) }
        return shape.subtracting(eyes(open: pose.eyesOpen))
    }

    /// Centerlines (head outline, spine, tail, legs) for the draw-on animation.
    static func centerline(_ pose: Pose) -> Path {
        var path = head
        path.addPath(torso(sway: pose.sway))
        path.addPath(tail(curl: pose.tailCurl, sway: pose.sway))
        path.addPath(legs(phase: pose.legPhase))
        return path
    }
}

/// The filled gecko; all pose values animate.
struct LizardShape: Shape {
    var pose: LizardGeometry.Pose

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(pose.tailCurl, pose.sway), AnimatablePair(pose.legPhase, pose.eyesOpen)) }
        set {
            pose.tailCurl = newValue.first.first
            pose.sway = newValue.first.second
            pose.legPhase = newValue.second.first
            pose.eyesOpen = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        LizardGeometry.silhouette(pose).applying(LizardGeometry.transform(in: rect))
    }
}

/// The centerlines, for drawing the mark on with `.trim`.
struct LizardCenterlineShape: Shape {
    var pose: LizardGeometry.Pose
    func path(in rect: CGRect) -> Path {
        LizardGeometry.centerline(pose).applying(LizardGeometry.transform(in: rect))
    }
}

struct LizardTongueShape: Shape {
    var length: CGFloat
    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in rect: CGRect) -> Path {
        LizardGeometry.tongue(length: length).applying(LizardGeometry.transform(in: rect))
    }
}

/// The mark with explicit pose parameters (static uses, icons, the splash script).
struct LizardMark<Style: ShapeStyle>: View {
    var style: Style
    var tailCurl: CGFloat = 1
    var sway: CGFloat = 0
    var legPhase: CGFloat = 0
    var eyesOpen: CGFloat = 1
    var tongue: CGFloat = 0
    /// 0…1 draw-on progress of the outline; the fill shows at `fill`.
    var drawn: CGFloat = 1
    var fill: Double = 1

    private var pose: LizardGeometry.Pose {
        LizardGeometry.Pose(tailCurl: tailCurl, sway: sway, legPhase: legPhase, eyesOpen: eyesOpen)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let unit = side / LizardGeometry.grid
            ZStack {
                LizardTongueShape(length: tongue)
                    .stroke(Color(hex: 0xFF6B8B), style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round))
                if drawn < 1 || fill < 1 {
                    LizardCenterlineShape(pose: pose)
                        .trim(from: 0, to: drawn)
                        .stroke(style, style: StrokeStyle(lineWidth: 2.4 * unit, lineCap: .round, lineJoin: .round))
                        .opacity(1 - fill)
                }
                LizardShape(pose: pose)
                    .fill(style)
                    .opacity(fill)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The living mark: sways its tail, blinks every few seconds, flicks its tongue when
/// `summon` changes, and wags while `thinking`. Still under Reduce Motion.
struct LizardMarkView: View {
    var size: CGFloat
    var summon: Bool = false
    var thinking: Bool = false
    var style: AnyShapeStyle = AnyShapeStyle(Brand.gradient)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyes: CGFloat = 1
    @State private var tongue: CGFloat = 0
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !onScreen)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let speed = thinking ? 7.0 : 1.3
            let sway = reduceMotion ? 0 : CGFloat(sin(time * speed)) * (thinking ? 1 : 0.35)
            let curl = reduceMotion ? 1 : 0.85 + CGFloat(sin(time * speed * 0.6)) * (thinking ? 0.15 : 0.08)
            LizardMark(style: style, tailCurl: curl, sway: sway, legPhase: thinking ? sway : 0, eyesOpen: eyes, tongue: tongue)
        }
        .frame(width: size, height: size)
        .onWindowVisibility { onScreen = $0 }
        .task(id: reduceMotion || !onScreen) { await blinkLoop() }
        .onChange(of: summon) { flick() }
        .onAppear { if summon { flick() } }
    }

    private func flick() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { tongue = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeIn(duration: 0.14)) { tongue = 0 }
        }
    }

    private func blinkLoop() async {
        guard !reduceMotion, onScreen else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3.5...6)))
            withAnimation(.easeIn(duration: 0.07)) { eyes = 0.05 }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.1)) { eyes = 1 }
        }
    }
}

/// Small mark that wags its tail while the AI is working.
struct LizardThinkingIndicator: View {
    var isThinking: Bool

    var body: some View {
        GeometryReader { proxy in
            LizardMarkView(size: min(proxy.size.width, proxy.size.height), thinking: isThinking)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct LizardWordmark: View {
    var size: CGFloat
    var body: some View {
        Text("lizard")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(-size * 0.03)
    }
}

struct LizardLockup: View {
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: size * 0.3) {
            LizardMarkView(size: size * 1.3)
            LizardWordmark(size: size)
        }
    }
}

/// The app icon: dark squircle, soft green glow, gradient mark.
struct LizardAppIcon: View {
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            shape.fill(Brand.ink)
            shape.fill(RadialGradient(colors: [Brand.moss.opacity(0.32), .clear], center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: size * 0.62))
            LizardMark(style: Brand.gradient)
                .padding(size * 0.15)
                .shadow(color: Brand.moss.opacity(0.45), radius: size * 0.03)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center), lineWidth: size * 0.008)
        }
        .frame(width: size, height: size)
    }
}

/// Faint field of tiny lizards drifting upward (splash background).
struct LizardPattern: View {
    /// A few precomputed poses (building silhouettes per frame would be wasteful).
    static let silhouettes: [Path] = [-1, -0.4, 0.4, 1].map { LizardGeometry.silhouette(.init(tailCurl: 0.8, sway: $0, legPhase: $0)) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || activeState == .inactive || !onScreen)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let spacing: CGFloat = 64
                let columns = Int(size.width / spacing) + 2
                let rows = Int(size.height / spacing) + 2
                let drift = CGFloat(time * 6).truncatingRemainder(dividingBy: spacing)
                for row in 0..<rows {
                    for column in 0..<columns {
                        let offset: CGFloat = row % 2 == 0 ? 0 : spacing / 2
                        let origin = CGPoint(x: CGFloat(column) * spacing + offset - spacing / 2, y: CGFloat(row) * spacing - drift)
                        let wiggle = CGFloat(sin(time * 1.5 + Double(row * 7 + column)))
                        let rect = CGRect(origin: origin, size: CGSize(width: 22, height: 22))
                        let shape = LizardPattern.silhouettes[(row * 3 + column) % LizardPattern.silhouettes.count]
                        let bob = CGAffineTransform(translationX: wiggle * 2, y: 0)
                        canvas.fill(shape.applying(LizardGeometry.transform(in: rect).concatenating(bob)), with: .color(Brand.moss.opacity(0.07)))
                    }
                }
            }
        }
        .onWindowVisibility { onScreen = $0 }
    }
}

#Preview("Marks") {
    HStack(spacing: 30) {
        LizardAppIcon(size: 180)
        LizardMarkView(size: 120, thinking: true)
        LizardLockup()
    }
    .padding(40)
}
