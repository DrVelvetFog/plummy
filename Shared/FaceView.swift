import SwiftUI

/// A tiny damped spring, so every part of the face moves with a little life.
private struct Spring {
    var value: Double
    var velocity = 0.0
    let stiffness: Double
    let damping: Double  // 1 = no overshoot, lower = bouncier

    init(_ value: Double, stiffness: Double = 200, damping: Double = 0.7) {
        self.value = value
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func step(to target: Double, dt: Double) {
        let c = 2 * sqrt(stiffness) * damping
        velocity += (stiffness * (target - value) - c * velocity) * dt
        value += velocity * dt
    }
}

/// Smooths what the Mac asks for into lifelike motion: darting eyes, brows, blinks, leaning, hops.
public final class FaceAnimator {
    public init() {}

    struct Frame {
        var gaze: CGPoint
        var mood: Mood
        var talk: Double
        var closed: Double      // 0 open … 1 shut (blink)
        var breathe: Double
        var time: Double
        var pupil: Double       // pupil size multiplier
        var browLift: Double    // + raises the brows (in design px)
        var browTilt: Double    // + worried/curious, - focused (radians)
        var lean: Double        // head tilt toward where she's looking (radians)
        var hop: Double         // little idle hop (design px, up is +)
        var blush: Double       // 0…1
        var squint: Double      // 0…1 happy squint from below
    }

    private var target = FaceState()
    private var lastPacket = -100.0
    private var gazeX = Spring(0, stiffness: 260, damping: 0.82)
    private var gazeY = Spring(0, stiffness: 260, damping: 0.82)
    private var pupil = Spring(1, stiffness: 160, damping: 0.5)
    private var browLift = Spring(0, stiffness: 180, damping: 0.55)
    private var browTilt = Spring(0, stiffness: 150, damping: 0.6)
    private var lean = Spring(0, stiffness: 60, damping: 0.8)
    private var hop = Spring(0, stiffness: 260, damping: 0.35)
    private var blush = Spring(0.25, stiffness: 40, damping: 1)
    private var squint = Spring(0, stiffness: 150, damping: 0.7)
    private var talk = 0.0
    private var mood: Mood = .listening
    private var moodChanged = 0.0
    private var blinkStart = -1.0
    private var doubleBlink = false
    private var nextBlink = 2.0
    private var lastTime: Double?
    private var nextSaccade = 0.0
    private var wanderTarget = CGPoint(x: 0, y: -0.3)
    private var jitter = CGPoint.zero
    private var nextJitter = 0.0
    private var nextHop = 6.0

    /// Set while a finger is on the screen (or the Mac pointer is near her), in -1…1 gaze units.
    public var touchGaze: CGPoint?
    /// Mood set on this device itself (waking up, talking, a boop).
    public var localMood: Mood?
    /// Loudness of the voice playing on this device, 0…1.
    public var localTalk: () -> Double = { 0 }
    /// True while she's awake and talking with you. In follow mode her eyes stay locked on your mouse.
    public var awake = false

    public func receive(_ face: FaceState, at time: Double) {
        target = face
        lastPacket = time
    }

    func step(_ now: Double) -> Frame {
        let dt = min(now - (lastTime ?? now), 1.0 / 20)
        lastTime = now

        let live = now - lastPacket < 2.5
        let wantedMood = localMood ?? (live ? target.mood : .listening)
        if wantedMood != mood {
            mood = wantedMood
            moodChanged = now
            blinkStart = now          // blink through every mood change
            if mood != .sleepy && mood != .resting {
                hop.velocity += 260   // and a little bounce of surprise
                pupil.velocity += 3
            }
        }

        // Where to look, plus tiny darting movements so the eyes never sit dead still.
        var want: CGPoint
        if let touchGaze {
            want = touchGaze
        } else if live {
            want = CGPoint(x: target.gazeX, y: target.gazeY)
        } else {
            if now > nextSaccade {
                wanderTarget = CGPoint(x: .random(in: -0.9...0.9), y: .random(in: -0.9...0.4))
                nextSaccade = now + .random(in: 0.6...2.2)
            }
            want = wanderTarget
        }
        if mood == .thinking { want = CGPoint(x: 0.6 + 0.08 * sin(now * 1.3), y: -0.85) }
        if now > nextJitter {
            // While she's listening her eyes stay on your mouse; the livelier darting is for replying.
            let amount = !awake ? 0.015 : (mood == .talking ? 0.07 : mood == .thinking ? 0.05 : 0.02)
            jitter = CGPoint(x: .random(in: -amount...amount), y: .random(in: -amount...amount))
            nextJitter = now + .random(in: 0.5...1.4)
        }
        gazeX.step(to: want.x + jitter.x, dt: dt)
        gazeY.step(to: want.y + jitter.y, dt: dt)

        var wantTalk = live ? target.talk : (localMood == .talking ? 0.5 + 0.5 * sin(now * 19) * sin(now * 7.3) : 0)
        wantTalk = max(wantTalk, localTalk())
        talk += (wantTalk - talk) * min(1, dt * 25)

        // Expression targets per mood.
        var wantPupil = 1.0, wantLift = 0.0, wantTilt = 0.0, wantBlush = 0.25, wantSquint = 0.0
        switch mood {
        case .listening:
            wantPupil = 1.12; wantLift = 10
        case .talking:
            wantPupil = 1.05; wantLift = 6 + talk * 18; wantTilt = 0.05 * sin(now * 2.3)
        case .pointing:
            wantPupil = 0.95; wantLift = -4; wantTilt = -0.14
        case .thinking:
            wantPupil = 0.9; wantLift = 4; wantTilt = 0.22
        case .happy:
            wantPupil = 1.2; wantLift = 16; wantBlush = 0.85; wantSquint = 1
        case .resting:
            wantPupil = 0.9; wantLift = -8; wantBlush = 0.15
        case .sleepy:
            wantPupil = 0.88; wantLift = -10; wantTilt = 0.12; wantBlush = 0.15
        }
        pupil.step(to: wantPupil, dt: dt)
        browLift.step(to: wantLift, dt: dt)
        browTilt.step(to: wantTilt, dt: dt)
        blush.step(to: wantBlush, dt: dt)
        squint.step(to: wantSquint, dt: dt)
        lean.step(to: -gazeX.value * 0.045, dt: dt)

        // An occasional happy little hop when nothing much is going on.
        if now > nextHop {
            if talk < 0.05, mood != .sleepy, mood != .resting { hop.velocity += .random(in: 180...320) }
            nextHop = now + .random(in: 7...14)
        }
        hop.step(to: 0, dt: dt)

        // Blinks, sometimes doubled.
        // Blinks, sometimes doubled. When she's drowsy they're slow and heavy.
        let drowsy = mood == .sleepy
        if now > nextBlink {
            blinkStart = now
            doubleBlink = !drowsy && Double.random(in: 0...1) < 0.25
            nextBlink = now + (drowsy ? .random(in: 1.6...3.0) : .random(in: 2.0...5.0))
        }
        let p = (now - blinkStart) / (drowsy ? 0.7 : 0.15)
        var closed = (0...1).contains(p) ? sin(.pi * p) : 0
        if doubleBlink, (1.3...2.3).contains(p) { closed = sin(.pi * (p - 1.3)) }

        let breathe = sin(now * (mood == .resting ? 1.1 : 1.8))
        return Frame(gaze: CGPoint(x: gazeX.value, y: gazeY.value), mood: mood, talk: talk, closed: closed,
                     breathe: breathe, time: now, pupil: pupil.value, browLift: browLift.value,
                     browTilt: browTilt.value, lean: lean.value, hop: hop.value, blush: blush.value,
                     squint: max(0, min(1, squint.value)))
    }
}

/// The landscape face, video-style: the whole screen is her. A deep plum field with two huge
/// googly eyes, thin brows and a little smile — the same face as the icon and the teaser.
public struct FaceView: View {
    let animator: FaceAnimator

    public init(animator: FaceAnimator) { self.animator = animator }

    // The design is drawn on an 844 × 390 landscape phone.
    static let design = CGSize(width: 844, height: 390)

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let frame = animator.step(timeline.date.timeIntervalSinceReferenceDate)
                FaceView.draw(frame, in: &ctx, size: size)
            }
        }
        .background(Color(hex: Palette.berry4))
        .ignoresSafeArea()
    }

    /// Her skin is the screen now; lids are drawn in the same plum so they read as skin.
    private static func fillSkin(_ path: Path, in ctx: inout GraphicsContext) {
        ctx.fill(path, with: .color(Color(hex: Palette.berry3)))
    }

    static func draw(_ f: FaceAnimator.Frame, in ctx: inout GraphicsContext, size: CGSize) {
        // The field: soft radial plum, darker toward the edges — the app icon's gradient, alive.
        let full = CGRect(origin: .zero, size: size)
        ctx.fill(Path(full), with: .color(Color(hex: Palette.berry4)))
        ctx.fill(Path(full), with: .radialGradient(
            Gradient(colors: [Color(hex: Palette.berry3), Color(hex: Palette.berry4)]),
            center: CGPoint(x: size.width * 0.5, y: size.height * 0.42),
            startRadius: 0, endRadius: max(size.width, size.height) * 0.72))

        let scale = max(size.width / design.width, size.height / design.height)
        ctx.translateBy(x: (size.width - design.width * scale) / 2,
                        y: (size.height - design.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)

        // Faint drifting specks, like the teaser's fireflies — barely there.
        for i in 0..<7 {
            let ph = f.time * 0.07 + Double(i) * 0.61
            let x = (ph * 97 + Double(i) * 131).truncatingRemainder(dividingBy: 844)
            let y = 390 - (ph * 23 + Double(i) * 67).truncatingRemainder(dividingBy: 390)
            let tw = 0.05 + 0.05 * sin(f.time * 1.3 + Double(i) * 2)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 5, height: 5)),
                     with: .color(.white.opacity(tw)))
        }

        // Whole-face motion: breathing, talking bounce, idle hops, and leaning — pivot at the bottom.
        let bounce = -f.talk * 14 + f.breathe * 3 - f.hop
        let pivot = CGPoint(x: design.width / 2, y: design.height)
        ctx.translateBy(x: pivot.x, y: pivot.y + bounce)
        ctx.rotate(by: .radians(f.lean))
        let stretch = 1 + min(0.03, max(-0.03, f.hop / 900))
        ctx.scaleBy(x: 2 - stretch, y: stretch)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)

        let navy = Color(hex: Palette.nose)
        let ink = Color(hex: Palette.ink)

        let eyeY: CGFloat = 186
        let eyes = [CGPoint(x: 292, y: eyeY), CGPoint(x: 552, y: eyeY)]
        let squash = 1 - f.talk * 0.12

        // Blushy cheeks below the eyes, rosier when she's happy.
        for (i, c) in eyes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1
            let cheek = CGRect(x: c.x - 52 + side * 70, y: c.y + 114, width: 104, height: 46)
            var soft = ctx
            soft.addFilter(.blur(radius: 12))
            soft.fill(Path(ellipseIn: cheek), with: .color(Color(hex: 0xF3A6D8, opacity: 0.16 + 0.4 * f.blush)))
        }

        for (i, c) in eyes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1

            // Thin arched brows above the big eyes — they do most of the acting.
            var brow = ctx
            let browY = c.y - 136 - min(18, max(-10, f.browLift)) * 0.7
            brow.translateBy(x: c.x + side * 6, y: browY)
            brow.rotate(by: .radians(f.browTilt * Double(side) * -1 + (f.mood == .thinking && i == 1 ? -0.25 : 0)))
            var arch = Path()
            arch.move(to: CGPoint(x: -44, y: 6))
            arch.addQuadCurve(to: CGPoint(x: 44, y: 6), control: CGPoint(x: 0, y: -14))
            brow.stroke(arch, with: .color(ink), style: StrokeStyle(lineWidth: 13, lineCap: .round))

            switch f.mood {
            case .resting:
                // Peacefully closed: a soft downward curve.
                var shut = Path()
                shut.move(to: CGPoint(x: c.x - 70, y: c.y + 6))
                shut.addQuadCurve(to: CGPoint(x: c.x + 70, y: c.y + 6), control: CGPoint(x: c.x, y: c.y + 58))
                ctx.stroke(shut, with: .color(ink), style: StrokeStyle(lineWidth: 18, lineCap: .round))

            case .happy where f.squint > 0.6:
                var arc = Path()
                arc.move(to: CGPoint(x: c.x - 68, y: c.y + 38))
                arc.addQuadCurve(to: CGPoint(x: c.x + 68, y: c.y + 38), control: CGPoint(x: c.x, y: c.y - 60))
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 24, lineCap: .round))

            default:
                let open = max(0.06, 1 - f.closed) * squash
                let white = CGRect(x: c.x - 108, y: c.y - 108 * open, width: 216, height: 216 * open)
                let whitePath = Path(ellipseIn: white)
                // A hint of depth so the googly eyes sit ON the screen like the video's.
                var shadow = ctx
                shadow.addFilter(.shadow(color: Color(hex: Palette.berry4, opacity: 0.55), radius: 14, x: 0, y: 8))
                shadow.fill(whitePath, with: .color(.white))
                ctx.fill(whitePath, with: .color(.white))
                guard open > 0.2 else { continue }

                var g = f.gaze
                let len = hypot(g.x, g.y)
                if len > 1 { g = CGPoint(x: g.x / len, y: g.y / len) }
                let reach: CGFloat = 56
                let r = 54 * f.pupil
                var pupil = CGPoint(x: c.x + g.x * reach - side * 3, y: c.y + g.y * reach * open)
                if f.mood == .sleepy { pupil.y = max(pupil.y, c.y) + 30 }  // eyes sink under heavy lids
                var inside = ctx
                inside.clip(to: whitePath)
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r, y: pupil.y - r, width: r * 2, height: r * 2)), with: .color(ink))
                // Two catchlights make them shine.
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r * 0.58, y: pupil.y - r * 0.72, width: r * 0.56, height: r * 0.56)),
                            with: .color(.white))
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x + r * 0.28, y: pupil.y + r * 0.22, width: r * 0.24, height: r * 0.24)),
                            with: .color(.white.opacity(0.85)))
                // Happy cheeks push up from below as she smiles.
                if f.squint > 0.02 {
                    let lid = CGRect(x: c.x - 124, y: c.y + 108 * open - 76 * f.squint, width: 248, height: 172)
                    fillSkin(Path(ellipseIn: lid), in: &inside)
                }
                // Heavy, droopy lids when she's getting sleepy.
                if f.mood == .sleepy {
                    let droop = 0.5 + 0.06 * sin(f.time * 1.3)
                    fillSkin(Path(CGRect(x: c.x - 112, y: white.minY - 10, width: 224, height: white.height * droop + 10)),
                             in: &inside)
                    inside.stroke(Path { p in
                        p.move(to: CGPoint(x: c.x - 102, y: white.minY + white.height * droop))
                        p.addLine(to: CGPoint(x: c.x + 102, y: white.minY + white.height * droop))
                    }, with: .color(navy.opacity(0.7)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                }
                // A soft upper lid when she's focused on pointing.
                if f.mood == .pointing {
                    fillSkin(Path(CGRect(x: c.x - 112, y: white.minY - 20, width: 224, height: 42)), in: &inside)
                }
            }
        }

        if f.mood == .resting {
            // Little z's floating up while she naps.
            for i in 0..<3 {
                let phase = (f.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let zSize = 26 + CGFloat(i) * 8
                let point = CGPoint(x: 690 + CGFloat(phase) * 70 + CGFloat(sin(phase * 6)) * 8,
                                    y: 120 - CGFloat(phase) * 100)
                ctx.draw(Text("z").font(.fredoka(zSize)).foregroundColor(.white.opacity(0.9 * sin(.pi * phase))), at: point)
            }
        }

        if f.mood == .thinking {
            for i in 0..<3 {
                let wobble = sin(f.time * 3 + Double(i)) * 4
                let dot = CGRect(x: 680 + CGFloat(i) * 26, y: 70 - CGFloat(i) * 12 + wobble, width: 16, height: 16)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(1 - Double(i) * 0.3)))
            }
        }

        // Her little mouth, centered between the eyes: a resting smile that opens as she talks.
        let mouth = CGPoint(x: 422, y: 322)
        if f.talk > 0.12 {
            let w: CGFloat = 60 - f.talk * 8
            let h: CGFloat = 38 + f.talk * 34
            let open = CGRect(x: mouth.x - w / 2, y: mouth.y - 14 - f.talk * 6, width: w, height: h)
            ctx.fill(Path(ellipseIn: open), with: .color(navy))
            if f.talk > 0.25 {
                let tongue = CGRect(x: open.midX - w * 0.28, y: open.maxY - h * 0.38, width: w * 0.56, height: h * 0.3)
                ctx.fill(Path(ellipseIn: tongue), with: .color(Color(hex: 0xE58BC4, opacity: 0.9)))
            }
        } else if f.mood == .happy {
            var smile = Path()
            smile.move(to: CGPoint(x: mouth.x - 52, y: mouth.y - 10))
            smile.addQuadCurve(to: CGPoint(x: mouth.x + 52, y: mouth.y - 10), control: CGPoint(x: mouth.x, y: mouth.y + 52))
            smile.closeSubpath()
            ctx.fill(smile, with: .color(navy))
        } else {
            // The video's gentle default smile — smaller when she's resting or sleepy.
            let calm = f.mood == .resting || f.mood == .sleepy
            let half: CGFloat = calm ? 26 : 36
            let depth: CGFloat = calm ? 14 : 26
            var smile = Path()
            smile.move(to: CGPoint(x: mouth.x - half, y: mouth.y - depth * 0.3))
            smile.addQuadCurve(to: CGPoint(x: mouth.x + half, y: mouth.y - depth * 0.3),
                               control: CGPoint(x: mouth.x, y: mouth.y + depth))
            ctx.stroke(smile, with: .color(navy), style: StrokeStyle(lineWidth: 13, lineCap: .round))
        }
    }
}
