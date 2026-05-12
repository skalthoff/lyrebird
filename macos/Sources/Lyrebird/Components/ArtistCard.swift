import SwiftUI
@preconcurrency import LyrebirdCore

/// Square grid tile used in the Library Artists tab. Mirrors the shape and
/// visual language of `AlbumCard`: square artwork, name below, hover reveals
/// a play overlay. Tapping the card pushes the artist detail screen onto
/// `model.navPath` via `Route.artist(artist.id)`.
///
/// Issue: #213 (Library → Artists grid). The overlay play button calls
/// `AppModel.playAll(artist:)`, which is a logging stub today pending
/// `artist_tracks` FFI (#156 / #465). The visual affordance matches the
/// album card so users have a consistent hover model across the grid.
///
/// Hover state is lifted to the parent (`LibraryView`) through the
/// `.libraryHoverID` environment, so a 5k-artist grid doesn't accumulate
/// per-cell `@State`. When the env isn't active (stand-alone embedding),
/// cells fall back to local state so hover keeps working. See #428.
struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.libraryHoverID) private var hoverTracker
    let artist: Artist
    /// Fallback hover flag; inert on the library path.
    @State private var localHovering = false

    /// True when the shared hover tracker reports this cell as hovered —
    /// or when we're on the fallback path and the cursor is over the cell.
    private var isHovering: Bool {
        if hoverTracker.isActive {
            return hoverTracker.id.wrappedValue == artist.id
        }
        return localHovering
    }

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.artist(artist.id))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 400),
                        seed: artist.name,
                        size: 180,
                        radius: 8,
                        // 180pt square at 2x = 360px, 3x = 540px. 540 gives
                        // us Retina-5K headroom without decoding the full
                        // server image. See #427.
                        targetPixelSize: CGSize(width: 540, height: 540)
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                    if model.supportsArtistPlayShuffle {
                        Button { model.playAll(artist: artist) } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 16))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Theme.primary))
                                .shadow(color: Theme.primary.opacity(0.5), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .opacity(isHovering ? 1 : 0)
                        .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                        // Hover overlay doesn't show for a non-mouse user, so
                        // make sure VoiceOver can find the play affordance by
                        // name. See #331.
                        .accessibilityLabel("Play all tracks by \(artist.name)")
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(albumCountLabel)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Theme.surface : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hoverTracker.isActive {
                if hovering {
                    hoverTracker.id.wrappedValue = artist.id
                } else if hoverTracker.id.wrappedValue == artist.id {
                    hoverTracker.id.wrappedValue = nil
                }
            } else {
                localHovering = hovering
            }
        }
        .contextMenu { ArtistContextMenu(artist: artist) }
        // Outer tap target reads as an artist navigation control; the
        // inner hover Play button owns its own label. VoiceOver sees
        // "Artist <name>, <album count>. Opens artist detail." `.focusable`
        // ensures the VoiceOver rotor can Tab into this card from a grid.
        // See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), \(albumCountLabel)")
        .accessibilityHint("Opens artist detail")
        .accessibilityAddTraits(.isButton)
    }

    /// Subline shown under the artist name. Uses `album_count` when known;
    /// falls back to song count so the tile always reads as "something by
    /// this artist" rather than an orphaned label.
    private var albumCountLabel: String {
        if artist.albumCount > 0 {
            return artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums"
        }
        if artist.songCount > 0 {
            return artist.songCount == 1 ? "1 song" : "\(artist.songCount) songs"
        }
        return "Artist"
    }
}
