import AppKit
import SwiftUI
@preconcurrency import LyrebirdCore

/// Status-bar **Now Playing** panel — the content of the app's `MenuBarExtra`
/// (declared in `LyrebirdApp`). Mirrors Apple Music's menu-bar mini transport
/// and Spotify's status-bar widget: a compact card with artwork, the current
/// track's title/artist, and prev / play-pause / next transport, plus an
/// explicit "Open Lyrebird" affordance that focuses the main window.
///
/// Because a `MenuBarExtra` lives in the system menu bar, this surface stays
/// reachable even when every Lyrebird window is closed or the app is hidden.
/// When nothing is playing (or the user is signed out) it falls back to a
/// minimal idle state so the panel never renders an empty box.
///
/// All playback state + actions route through the same `AppModel` entry points
/// the `PlayerBar` and `MiniPlayerView` use (`togglePlayPause`, `skipNext`,
/// `skipPrevious`, `status.*`), so the menu-bar panel can never disagree with
/// the in-window transport — there is one writer.
struct MenuBarNowPlaying: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Self.showsNowPlaying(currentTrack: model.status.currentTrack),
                let track = model.status.currentTrack
            {
                nowPlaying(track: track)
            } else {
                idle
            }
            Divider()
            openButton
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Now playing

    @ViewBuilder
    private func nowPlaying(track: Track) -> some View {
        HStack(spacing: 12) {
            Artwork(
                url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 120),
                seed: track.name,
                size: 56,
                radius: 6
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(Theme.font(13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistName)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        transportRow
    }

    @ViewBuilder
    private var transportRow: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            iconBtn("backward.fill", label: "menu_bar.now_playing.previous", size: 14) {
                model.skipPrevious()
            }
            Button(action: model.togglePlayPause) {
                Image(systemName: Self.transportIcon(isPlaying: isPlaying))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isPlaying ? "menu_bar.now_playing.pause" : "menu_bar.now_playing.play"))
            iconBtn("forward.fill", label: "menu_bar.now_playing.next", size: 14) {
                model.skipNext()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Idle (nothing playing / signed out)

    @ViewBuilder
    private var idle: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(Theme.ink3)
            Text("player.nothing_playing")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Open the app

    /// Focus the main window. Routes through the same `returnToFullWindow`
    /// contract the mini player uses, which activates the app (raising the
    /// main `WindowGroup` window) so the click works even when every Lyrebird
    /// window is closed or the app is hidden.
    @ViewBuilder
    private var openButton: some View {
        Button {
            model.returnToFullWindow()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                Text("menu_bar.now_playing.open")
                    .font(Theme.font(12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("menu_bar.now_playing.open"))
    }

    // MARK: - Derived

    private var isPlaying: Bool { model.status.state == .playing }

    /// SF Symbol for the centre transport button given the play state. Pure so
    /// the play↔pause icon swap can be verified without realizing the view.
    static func transportIcon(isPlaying: Bool) -> String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    /// Whether the panel should show the rich now-playing card (`true`) or the
    /// minimal idle fallback (`false`) for a given current track. Pure so the
    /// idle-vs-playing branch is testable headlessly.
    static func showsNowPlaying(currentTrack: Track?) -> Bool {
        currentTrack != nil
    }

    @ViewBuilder
    private func iconBtn(
        _ name: String,
        label: LocalizedStringKey,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// The menu-bar item's label (the icon shown in the system status bar). A
/// small SF Symbol that reflects play state so the bar communicates whether
/// audio is running at a glance, without opening the panel.
struct MenuBarNowPlayingLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: Self.icon(for: model.status.state))
            .accessibilityLabel(Text("menu_bar.now_playing.label"))
    }

    /// SF Symbol for the status-bar label given the playback state: an animated
    /// `waveform` while audio is running, the resting `music.note` otherwise.
    /// Pure so the at-a-glance icon swap can be verified without a window
    /// server.
    static func icon(for state: PlaybackState) -> String {
        state == .playing ? "waveform" : "music.note"
    }
}
