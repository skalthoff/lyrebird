import SwiftUI
@preconcurrency import LyrebirdCore

/// Circular artist tile used on the Home screen to launch an Instant Mix
/// ("artist radio") seeded by that artist. Art-forward: a round artwork
/// thumbnail with a "<Artist> Radio" label beneath it. Tapping the tile
/// calls `AppModel.startArtistRadio(artist:)`, which is fully wired: it
/// routes through `playInstantMix(seedId:)` → `core.instantMix(itemId:limit:)`
/// off the main actor, plays the returned tracks, and surfaces failures via
/// `errorMessage`.
///
/// Issue: #254.
struct ArtistRadioTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: Artist
    var size: CGFloat = 140

    @State private var isHovering = false

    var body: some View {
        Button {
            model.startArtistRadio(artist: artist)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Artwork(
                        url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 400),
                        seed: artist.name,
                        size: size,
                        radius: size / 2
                    )
                    .frame(width: size, height: size)

                    // Radio glyph overlay — surfaces the radio affordance on
                    // hover so the circular tile doesn't read as "just an
                    // artist photo". Mirrors the play-button reveal pattern
                    // used on `AlbumCard`.
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.white)
                        .font(.system(size: size * 0.28, weight: .bold))
                        .frame(width: size, height: size)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .opacity(isHovering ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                }
                .overlay(
                    Circle()
                        .stroke(
                            isHovering ? Theme.accent : Theme.border,
                            lineWidth: isHovering ? 2 : 1
                        )
                )
                .shadow(
                    color: isHovering ? Theme.accent.opacity(0.35) : .clear,
                    radius: 12
                )

                VStack(spacing: 2) {
                    Text(artist.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("Radio")
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(0.5)
                }
                .frame(width: size)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Start \(artist.name) Radio")
        .accessibilityLabel("\(artist.name) Radio")
        .accessibilityHint("Starts an artist radio seeded by \(artist.name)")
        .contextMenu { ArtistContextMenu(artist: artist) }
    }
}
