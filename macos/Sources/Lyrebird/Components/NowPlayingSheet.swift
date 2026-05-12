import SwiftUI
@preconcurrency import LyrebirdCore

/// A minimal expanded Now Playing panel presented when the user taps the
/// track title in the `PlayerBar`. Hosts the artwork, track meta, and the
/// Credits info block (#279).
///
/// This is a compact sheet rather than the full-screen player sketched in
/// `design/project/src/panels.jsx` — the full player, right panel, and
/// "About this track" block are tracked separately (#79, #82, and the
/// right-panel re-skin issues). Landing the sheet first unblocks the
/// Credits block while the rest of the Now Playing surface comes online.
struct NowPlayingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    NowPlayingCredits(credits: Credit.rows(from: model.currentTrackPeople))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 420, height: 560)
        .background(Theme.bg)
        .task(id: model.status.currentTrack?.id) {
            await model.fetchCurrentTrackDetails()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Now Playing")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(2)
                .textCase(.uppercase)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Now Playing")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let track = model.status.currentTrack {
            HStack(alignment: .top, spacing: 14) {
                Artwork(
                    url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 240),
                    seed: track.name,
                    size: 96,
                    radius: 8
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name)
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(Theme.font(13, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    if let album = track.albumName, !album.isEmpty {
                        Text(album)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            Text("Nothing playing")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        }
    }
}
