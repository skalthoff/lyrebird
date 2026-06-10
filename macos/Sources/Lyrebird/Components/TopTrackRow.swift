import SwiftUI
@preconcurrency import LyrebirdCore

/// Compact list-item row for the Artist detail "Top Tracks" section (#229).
/// Shows the rank number, a small square artwork, the track title / album,
/// and the user's play count. Tapping plays the track — with the full Top
/// Tracks list passed in as `queue` so the core queue picks up the rest as
/// the user lets it play.
///
/// Intentionally denser than `TrackRow` (which is tuned for album detail
/// and trades per-row artwork for ordering by track number): Top Tracks
/// can span many albums, so showing a thumbnail gives the user a visual
/// anchor per row.
struct TopTrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Contrast-adaptive accent for the active-row rank / title and the
    // now-playing equalizer. Lifts to `accentHot` under Increase Contrast so
    // accent foregrounds clear 4.5:1 (#888).
    @Environment(\.accessibleTheme) private var a11yTheme

    let track: Track
    let rank: Int
    let queue: [Track]

    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }
    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    private var playCountLabel: String {
        let count = track.playCount
        switch count {
        case 0: return "—"
        default: return CountStrings.label(Int(count), .plays)
        }
    }

    var body: some View {
        Button(action: playFromHere) {
            HStack(spacing: 14) {
                // Rank / play-affordance. Hover swaps in a play glyph so the
                // row clearly reads as actionable; otherwise shows the rank.
                ZStack {
                    if isPlaying {
                        EqualizerIcon()
                            .foregroundStyle(a11yTheme.accent)
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    } else {
                        Text("\(rank)")
                            .font(Theme.font(14, weight: .heavy))
                            .foregroundStyle(isActive ? a11yTheme.accent : Theme.ink3)
                            .monospacedDigit()
                    }
                }
                .frame(width: 28)

                // Per-row artwork — the album art for this track. Gives the
                // user a visual anchor when rows span multiple albums.
                Artwork(
                    url: model.imageURL(
                        for: track.albumId ?? track.id,
                        tag: track.imageTag,
                        maxWidth: 120
                    ),
                    seed: track.name,
                    size: 40,
                    radius: 4
                )
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? a11yTheme.accent : Theme.ink)
                        .lineLimit(1)
                    Text(track.albumName ?? track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                Text(playCountLabel)
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(0.5)
                    .frame(minWidth: 72, alignment: .trailing)

                Text(track.durationFormatted)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Theme.surface2 : (isHovering ? Theme.nativeHover : .clear))
            )
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
        .contextMenu { TrackContextMenu(selection: [track]) }
        // `.focusable` lets the VoiceOver rotor Tab through the Top Tracks
        // list; `.combine` collapses rank/artwork/text so the element reads
        // as a single playable row. See #588.
        .focusable(true)
        .focusEffectDisabled(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name), \(playCountLabel), rank \(rank)")
        .accessibilityHint("Plays this track")
        .accessibilityAddTraits(.isButton)
    }

    /// Start playback at this row. Passing the full `queue` keeps the Top
    /// Tracks list as the auto-advance target, so hitting play on #1 lets
    /// #2-5 queue up naturally.
    private func playFromHere() {
        guard let idx = queue.firstIndex(where: { $0.id == track.id }) else {
            model.play(tracks: [track], startIndex: 0)
            return
        }
        model.play(tracks: queue, startIndex: idx)
    }
}
