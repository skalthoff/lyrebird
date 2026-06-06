import SwiftUI

/// Queue section header shown while an Instant Mix / radio session is the
/// active source. Replaces the usual "PLAYING FROM {source}" label
/// with a "RADIO · SEED: {seed}" treatment fronted by a pulsing on-air dot,
/// so the queue reads as an endless station rather than a finite list — the
/// Apple Music / Spotify radio-state convention.
///
/// Shared by both queue surfaces (`QueueInspector`, `FullQueueView`) so the
/// on-air treatment is pixel-identical wherever the queue is shown. The dot
/// pulse honors Reduce Motion: when the user has it on, the dot renders
/// statically lit instead of breathing.
struct RadioQueueHeader: View {
    /// Human-readable seed label (album / artist / genre / track name).
    let seed: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            onAirDot
            Text("Radio")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.accentHot)
                .tracking(1.5)
                .textCase(.uppercase)
            Text("· Seed: \(seed)")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(1.5)
                .textCase(.uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radio. Seed: \(seed)")
        .accessibilityAddTraits(.isStaticText)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    /// Live "on air" indicator: an accent dot with a soft halo. Breathes
    /// between full and half opacity unless Reduce Motion is set, in which
    /// case it sits statically lit.
    private var onAirDot: some View {
        Circle()
            .fill(Theme.accentHot)
            .frame(width: 7, height: 7)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.45 : 1))
            .overlay(
                Circle()
                    .stroke(Theme.accentHot.opacity(0.35), lineWidth: 3)
                    .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.9 : 1))
                    .opacity(reduceMotion ? 0.5 : (pulsing ? 0 : 0.5))
            )
            .accessibilityHidden(true)
    }
}

#Preview("Radio queue header") {
    VStack(alignment: .leading, spacing: 16) {
        RadioQueueHeader(seed: "Daft Punk")
        RadioQueueHeader(seed: "A Very Long Genre Name That Should Truncate Gracefully")
    }
    .padding(24)
    .frame(width: 320, alignment: .leading)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
