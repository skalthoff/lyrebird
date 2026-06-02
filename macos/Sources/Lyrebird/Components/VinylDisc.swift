import SwiftUI

/// A stylized vinyl record that peeks out the right edge of the Now Playing
/// hero artwork and spins while audio is playing (#270).
///
/// Mirrors the prototype recipe in `design/project/src/panels.jsx`:
/// a 400pt conic-gradient disc offset `-80pt` to the right and `+10pt` up,
/// sitting *behind* the 420pt artwork, with a primary→accent label and a
/// black center hole. One rotation per 8s, linear, only while `playing`.
/// Pausing freezes the disc in place (the angle is interpolated, so it
/// stops where it was rather than snapping back to 0°).
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

    /// Accumulated rotation in degrees. Animating a monotonically growing
    /// value (rather than toggling 0↔360) lets the disc freeze in place on
    /// pause instead of unwinding, and resume from the same angle.
    @State private var angle: Double = 0

    /// Prototype reference dimensions, scaled by the live art side so the
    /// disc keeps its proportions on a 13" MBP and on an ultrawide alike.
    private var scale: CGFloat { artSide / 420 }
    private var discSize: CGFloat { 400 * scale }
    private var offsetX: CGFloat { 80 * scale }
    private var offsetY: CGFloat { -10 * scale }

    var body: some View {
        ZStack {
            // Grooved body — repeating conic gradient reads as concentric
            // pressing lines once it spins.
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

            // Label — primary→accent wash.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.primary, Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: discSize * 0.2, height: discSize * 0.2)

            // Center spindle hole.
            Circle()
                .fill(Color.black)
                .frame(width: discSize * 0.06, height: discSize * 0.06)
        }
        .frame(width: discSize, height: discSize)
        .shadow(color: .black.opacity(0.5), radius: 20 * scale, x: 0, y: 20 * scale)
        .rotationEffect(.degrees(angle))
        // Behind the artwork, peeking out its right edge.
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
    /// drive `angle` forward by 360° on a repeating 8s linear ramp. On pause
    /// we re-assign the current angle with no animation, which halts the
    /// in-flight ramp at its present position.
    private func updateSpin(playing: Bool) {
        if playing && !reduceMotion {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                angle += 360
            }
        } else {
            // Freeze in place: cancel the repeating animation by writing the
            // value without an animation transaction.
            withAnimation(.linear(duration: 0)) {
                angle = angle.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}
