import SwiftUI

/// A gradient station tile used by the Genre / Decade / Mood radio rows on
/// the Radio / Home screen (#256). Unlike `ArtistRadioTile` (a circular
/// artwork thumb), these stations have no single seed image — they're
/// abstract "play me this slice of the library" presets — so the tile leans
/// on a per-tile gradient + a huge italic label, matching the screen-spec
/// treatment ("default artwork gradient + huge italic text"). A radio glyph
/// reveals on hover so the tile reads as an action, not a static label.
///
/// Tapping invokes `action`, which the caller wires to the corresponding
/// `AppModel` radio starter (`startGenreRadio` / `startDecadeRadio` /
/// `startMoodRadio`).
struct RadioStationTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Large italic label, e.g. "Jazz", "'80s", "Chill".
    let label: String
    /// Small uppercase eyebrow, e.g. "GENRE", "DECADE", "MOOD".
    let eyebrow: String
    /// Stable seed used to derive the gradient hue so a given station always
    /// renders the same color (e.g. the genre name / decade string).
    let seed: String
    let action: () -> Void

    var size: CGFloat = 150

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                gradient
                // Radio glyph, top-trailing, revealed on hover.
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(isHovering ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)

                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow)
                        .font(Theme.font(10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(label)
                        .font(Theme.font(26, weight: .black, italic: true))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(14)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isHovering ? Theme.accent : Theme.border, lineWidth: isHovering ? 2 : 1)
            )
            .shadow(color: isHovering ? Theme.accent.opacity(0.3) : .clear, radius: 12)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Start \(label) Radio")
        .accessibilityLabel("\(label) Radio")
        .accessibilityHint("Starts a radio station seeded by \(label)")
    }

    /// Deterministic two-stop gradient derived from `seed` so each station
    /// gets a distinct but stable hue. Saturation/brightness are pinned so
    /// every tile stays in the same "deep, music-forward" register as the
    /// rest of the UI rather than going neon.
    private var gradient: some View {
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        let top = Color(hue: hue, saturation: 0.55, brightness: 0.42)
        let bottom = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0),
                           saturation: 0.7, brightness: 0.24)
        return LinearGradient(
            colors: [top, bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
