import SwiftUI
@preconcurrency import LyrebirdCore

/// Square-artwork track tile used in horizontal carousels on Home (Recently
/// Played, #206) and Discover (For You, #249). Tapping plays the track; the
/// floating play-on-hover button lifts in from the bottom to surface the
/// primary action without competing with the artwork.
///
/// Intentionally content-agnostic — any "play this track" carousel that wants
/// the same 160pt tile language should reuse this rather than rolling its own.
struct RecentlyPlayedTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    @State private var isHovering = false

    var body: some View {
        Button {
            model.play(tracks: [track], startIndex: 0)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(
                            for: track.albumId ?? track.id,
                            tag: track.imageTag,
                            maxWidth: 400
                        ),
                        seed: track.albumName ?? track.name,
                        size: 160,
                        radius: 8
                    )
                    .frame(width: 160, height: 160)

                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 14))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.primary))
                        .shadow(color: Theme.primary.opacity(0.5), radius: 8, y: 3)
                        .padding(8)
                        .opacity(isHovering ? 1 : 0)
                        .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 8))
        // `.focusable` lets the VoiceOver rotor Tab through the Recently
        // Played / For You carousels; `.combine` collapses artwork + metadata
        // into one button element. See #588.
        .focusable(true)
        .focusEffectDisabled(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityHint("Plays this track")
        .accessibilityAddTraits(.isButton)
    }
}
