import SwiftUI
@preconcurrency import LyrebirdCore

/// Compact horizontal track row used in the Home screen's "Recently
/// Played" carousel (#52). Unlike `TrackRow` (which is tuned for album /
/// playlist detail surfaces and starts with a row number), this variant
/// leads with a 48pt artwork thumbnail and drops the numbering so it
/// reads as a "tap to replay" suggestion, not a queue index.
///
/// Sized to fit a ~320pt card so 6 rows fit comfortably in the standard
/// Home window width. Clicking plays the track; right-click opens a
/// track-scoped context menu with Play / Go to Album / Go to Artist.
struct RecentlyPlayedTrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track

    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }

    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    var body: some View {
        Button {
            model.play(tracks: [track], startIndex: 0)
        } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.durationFormatted)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Theme.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play.fill") {
                model.play(tracks: [track], startIndex: 0)
            }
            if let albumId = track.albumId, !albumId.isEmpty {
                Button("Go to Album", systemImage: "square.stack") {
                    model.navPath.append(AppModel.Route.album(albumId))
                }
            }
            if let artistId = track.artistId, !artistId.isEmpty {
                Button("Go to Artist", systemImage: "person") {
                    model.navPath.append(AppModel.Route.artist(artistId))
                }
            }
        }
        // `.focusable` lets the VoiceOver rotor Tab through the Home
        // Recently Played list; `.combine` presents thumbnail + title +
        // duration as a single playable element. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityHint("Plays this track")
        .accessibilityAddTraits(.isButton)
    }

    private var thumbnail: some View {
        ZStack {
            Artwork(
                url: model.imageURL(
                    for: track.albumId ?? track.id,
                    tag: track.imageTag,
                    maxWidth: 120
                ),
                seed: track.albumName ?? track.name,
                size: 48,
                radius: 4
            )
            .frame(width: 48, height: 48)

            if isPlaying {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.45))
                    .frame(width: 48, height: 48)
                EqualizerIcon()
                    .foregroundStyle(.white)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.35))
                    .frame(width: 48, height: 48)
                Image(systemName: "play.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .bold))
            }
        }
    }
}
