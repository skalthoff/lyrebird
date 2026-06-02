import SwiftUI

/// Spin-state math for the vinyl disc, factored out of the view so the
/// freeze-on-pause behaviour is unit-testable without a running scene graph.
///
/// The disc animates a monotonically growing `angle` so it can stop in place
/// rather than unwinding to 0°. The subtlety: when SwiftUI is mid-ramp, the
/// model's `angle` already holds the *target* of the in-flight animation, not
/// the value currently on screen. Truncating that target by 360 lands on an
/// arbitrary multiple-of-360 remainder, so the disc visibly snaps. To freeze
/// at the *interpolated* position we reconstruct it from the ramp's start
/// time and duration.
enum VinylSpin {
    /// One rotation per this many seconds, linear.
    static let secondsPerRotation: Double = 8

    /// Degrees swept since a ramp began, given how long it has been running.
    /// Linear at `360 / secondsPerRotation` deg/s, clamped to non-negative
    /// elapsed so a clock skew can't rewind the disc.
    static func sweep(elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        return elapsed * (360 / secondsPerRotation)
    }

    /// The angle the disc is actually showing when paused mid-ramp: the angle
    /// it started the current rotation from, advanced by the interpolated
    /// sweep, then normalised to `[0, 360)`. This is the value to commit on
    /// pause — using the model's already-advanced target instead would snap
    /// the disc to an unrelated remainder.
    static func frozenAngle(base: Double, elapsed: Double) -> Double {
        normalize(base + sweep(elapsed: elapsed))
    }

    /// Map any accumulated angle into `[0, 360)` without the sign quirk of
    /// `truncatingRemainder` on negatives.
    static func normalize(_ angle: Double) -> Double {
        let r = angle.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

/// A stylized vinyl record that peeks out the right edge of the Now Playing
/// hero artwork and spins while audio is playing.
///
/// Mirrors the prototype recipe in `design/project/src/panels.jsx`:
/// a 400pt conic-gradient disc offset `-80pt` to the right and `+10pt` up,
/// sitting *behind* the 420pt artwork, with a primary→accent label and a
/// black center hole. One rotation per 8s, linear, only while `playing`.
/// Pausing freezes the disc at its on-screen position; Reduce Motion holds it
/// still.
///
/// The disc scales to whatever side length the hero art is rendered at
/// (the hero is responsive, not a hard 420pt), preserving the prototype's
/// 400:420 disc-to-art ratio and the `-80`/`+10` offsets at every size.
struct VinylDisc: View {
    /// Side length of the hero artwork this disc sits behind.
    let artSide: CGFloat
    /// Whether playback is currently active. Drives the spin animation.
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Accumulated rotation in degrees, normalised to `[0, 360)` whenever the
    /// disc is at rest. Animating a growing value lets the disc freeze in
    /// place on pause and resume from the same angle.
    @State private var angle: Double = 0
    /// The angle the current ramp started from, captured when the spin begins.
    @State private var rampBaseAngle: Double = 0
    /// When the current ramp began, used to reconstruct the interpolated angle
    /// on pause. `nil` while the disc is at rest.
    @State private var rampStart: Date?

    private var scale: CGFloat { artSide / 420 }
    private var discSize: CGFloat { 400 * scale }
    private var offsetX: CGFloat { 80 * scale }
    private var offsetY: CGFloat { -10 * scale }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(white: 0.07), location: 0.0),
                            .init(color: Color(white: 0.13), location: 0.15),
                            .init(color: Color(white: 0.07), location: 0.30),
                            .init(color: Color(white: 0.13), location: 0.45),
                            .init(color: Color(white: 0.07), location: 0.60),
                            .init(color: Color(white: 0.13), location: 0.75),
                            .init(color: Color(white: 0.07), location: 0.90),
                            .init(color: Color(white: 0.07), location: 1.0),
                        ]),
                        center: .center
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.8), lineWidth: discSize * 0.04)
                        .blur(radius: discSize * 0.05)
                        .padding(discSize * 0.02)
                )

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.primary, Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: discSize * 0.2, height: discSize * 0.2)

            Circle()
                .fill(Color.black)
                .frame(width: discSize * 0.06, height: discSize * 0.06)
        }
        .frame(width: discSize, height: discSize)
        .shadow(color: .black.opacity(0.5), radius: 20 * scale, x: 0, y: 20 * scale)
        .rotationEffect(.degrees(angle))
        .offset(x: offsetX, y: offsetY)
        .zIndex(-1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isPlaying) { _, playing in
            updateSpin(playing: playing)
        }
        .onChange(of: reduceMotion) { _, _ in
            updateSpin(playing: isPlaying)
        }
        .onAppear { updateSpin(playing: isPlaying) }
    }

    /// Start or stop the rotation. While playing (and motion is allowed) we
    /// drive `angle` forward by 360° on a repeating 8s linear ramp, recording
    /// the base angle and start time so a later pause can recover the
    /// on-screen position. On pause we commit that interpolated position with
    /// no animation, halting the ramp where the disc actually is.
    private func updateSpin(playing: Bool) {
        if playing && !reduceMotion {
            guard rampStart == nil else { return }
            rampBaseAngle = angle
            rampStart = Date()
            withAnimation(.linear(duration: VinylSpin.secondsPerRotation).repeatForever(autoreverses: false)) {
                angle += 360
            }
        } else {
            let elapsed = rampStart.map { Date().timeIntervalSince($0) } ?? 0
            rampStart = nil
            withAnimation(.linear(duration: 0)) {
                angle = VinylSpin.frozenAngle(base: rampBaseAngle, elapsed: elapsed)
            }
        }
    }
}
