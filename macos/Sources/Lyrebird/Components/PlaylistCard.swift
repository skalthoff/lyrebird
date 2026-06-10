import SwiftUI
@preconcurrency import LyrebirdCore

/// Grid card for a Jellyfin playlist. Mirrors `AlbumCard` in shape so the
/// Library grid reads consistently when the user switches chips; the only
/// visible differences are the subtitle ("N tracks") and the tap target
/// (playlist detail rather than album detail).
///
/// Context menu routes through `PlaylistContextMenu` so the grid, list rows,
/// and any future surfaces share one set of actions.
///
/// Spec: #212 (Library chips). Detail screen pushed via `AppModel.Route.playlist`.
struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playlist: Playlist
    @State private var isHovering = false

    var body: some View {
        Button {
            model.navPath.append(AppModel.Route.playlist(playlist.id))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: playlist.id, tag: playlist.imageTag, maxWidth: 400),
                        seed: playlist.name,
                        size: 180,
                        radius: 8
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                    Button { model.play(playlist: playlist) } label: {
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
                    .accessibilityLabel("Play \(playlist.name)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Theme.nativeHover : .clear)
            )
            .scaleEffect(reduceMotion ? 1.0 : (isHovering ? 1.02 : 1.0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 12))
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        // `.focusable` lets the VoiceOver rotor Tab into this card; `.combine`
        // collapses the artwork, title, and play-button children so the card
        // reads as a single "Opens playlist detail" button. See #588.
        .focusable(true)
        .focusEffectDisabled(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name), \(subtitle)")
        .accessibilityHint("Opens playlist detail")
        .accessibilityAddTraits(.isButton)
    }

    /// "42 tracks" / "1 track" — singular vs plural. Jellyfin reports
    /// `trackCount` as 0 for freshly-created empty playlists; render that as
    /// "Empty" rather than a confusing "0 tracks".
    private var subtitle: String {
        switch playlist.trackCount {
        case 0: return "Empty"
        default: return CountStrings.label(Int(playlist.trackCount), .tracks)
        }
    }
}
