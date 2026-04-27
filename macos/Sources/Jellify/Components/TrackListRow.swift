import SwiftUI
@preconcurrency import JellifyCore

/// Container formats that AVFoundation / CoreAudio can decode natively on
/// macOS without requiring server-side transcoding.
///
/// The list intentionally errs on the side of caution — only the codecs
/// that ship in every macOS installation and are reliably passthrough-able
/// are included. Less common formats (Opus in an Ogg container, WMA, etc.)
/// are treated as "needs transcoding" even if a particular machine happens
/// to have a plugin that can decode them, because the Jellyfin server can't
/// know that.
let directPlayContainers: Set<String> = [
    "aac", "mp3", "mp4", "m4a", "alac", "flac", "wav", "aiff", "aif",
]

/// Compact single-line row used by the Library Tracks tab. Mirrors the
/// density of `LibraryListRow` (small square artwork, primary + secondary
/// text, trailing metadata) but surfaces track-specific fields: artist on the
/// secondary line and right-aligned duration.
///
/// Clicking / double-clicking plays the track as a one-track queue via
/// `AppModel.play(tracks:startIndex:)`. Hover reveals an inline play button
/// for parity with the album row affordance. Right-click opens a context
/// menu with the standard track actions (play / play next / queue / share).
///
/// Keyboard navigation (#105): rows are `.focusable()` so Tab / arrow keys
/// move focus between siblings. `model.focusedTrackId` is the shared focus
/// cursor — on focus the row writes its id; on change the matching sibling
/// pulls focus to itself via its local `@FocusState`. Up / Down arrows
/// rewrite `focusedTrackId` to the previous / next row's id, Return plays
/// the focused track, and Space toggles global play/pause. Type-ahead
/// (letter keys matching a title prefix) is tracked as a follow-up — see
/// the TODO below.
struct TrackListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    /// Full track list the row was rendered from, so tap-to-play can hand
    /// the entire ordered list to `AppModel.play` and index into it. This
    /// matches the `AlbumDetailView.trackList` contract.
    let tracks: [Track]
    let index: Int
    @AppStorage("audio.transcodingPreference") private var transcodingRaw: String = TranscodingPreference.directPlay.rawValue
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }

    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    /// Returns `true` when the user has Direct Play enabled and the track's
    /// container format is not in the native macOS direct-play set, meaning
    /// the server will have to transcode this file before streaming it.
    private var willTranscode: Bool {
        let preference = TranscodingPreference(rawValue: transcodingRaw) ?? .directPlay
        guard preference == .directPlay else { return false }
        guard let container = track.container?.lowercased().trimmingCharacters(in: .whitespaces),
              !container.isEmpty else { return false }
        return !directPlayContainers.contains(container)
    }

    var body: some View {
        Button {
            model.play(tracks: tracks, startIndex: index)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(
                        url: model.imageURL(
                            for: track.albumId ?? track.id,
                            tag: track.imageTag,
                            maxWidth: 120
                        ),
                        seed: track.albumName ?? track.name,
                        size: 40,
                        radius: 4
                    )
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 40, height: 40)
                        EqualizerIcon()
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 40, height: 40)
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 13))
                            .transition(.opacity)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(track.name)
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                            .lineLimit(1)
                        if willTranscode {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.warning)
                                .help("Transcoding required. Enable in Preferences → Playback.")
                        }
                    }
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if let album = track.albumName {
                    Text(album)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .frame(maxWidth: 240, alignment: .trailing)
                }

                Text(track.durationFormatted)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
            .overlay(
                // Subtle outline so focus-via-keyboard is visible even when
                // the row is also hovered or active. See #105.
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
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
        // A single row should read as one VoiceOver element — the wrapping
        // Button already carries a label, but we override it here to pull
        // in the active state so playing rows announce "Now playing" and
        // non-playing rows announce "Plays this track". `.combine` collapses
        // the artwork and text sub-views so the rotor sees one button per
        // row rather than several unlabelled children. See #588.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityHint(isPlaying ? "Now playing" : "Plays this track")
        .accessibilityAddTraits(isPlaying ? [.isButton, .isSelected] : .isButton)
        // MARK: Keyboard navigation (#105)
        .focusable()
        .focused($isFocused)
        .onChange(of: isFocused) { _, nowFocused in
            if nowFocused {
                model.focusedTrackId = track.id
            }
        }
        .onChange(of: model.focusedTrackId) { _, newId in
            // Sibling rows observe the shared focus cursor; the one that
            // matches pulls focus to itself. Without this the arrow keys
            // would write the new id but no row would actually focus.
            if newId == track.id && !isFocused {
                isFocused = true
            }
        }
        .onKeyPress(.upArrow) {
            moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            model.play(tracks: tracks, startIndex: index)
            return .handled
        }
        .onKeyPress(.space) {
            // Space toggles global play/pause regardless of focus target so
            // "pause while scrolling" works from anywhere in the list.
            model.togglePlayPause()
            return .handled
        }
        // TODO(#105): type-ahead search — buffer letter key presses for
        // ~500ms and move focus to the first row whose title starts with
        // the buffer. Needs either a shared FocusState container above the
        // ForEach (so rows can delegate) or a focus-system state on
        // AppModel that remembers both the list scope and the last key
        // timestamp. Out of scope for the first cut of keyboard nav.
    }

    private var rowBackground: Color {
        if isActive { return Theme.surface2 }
        if isFocused { return Theme.rowHover }
        if isHovering { return Theme.rowHover }
        return .clear
    }

    /// Advance the focused row by `delta` (+1 for down, -1 for up) inside
    /// the ordered `tracks` array. Because each row owns its own
    /// `@FocusState`, we hand focus off via `model.focusedTrackId` — the
    /// sibling row whose id matches observes the change above and pulls
    /// focus to itself.
    private func moveFocus(by delta: Int) {
        let target = index + delta
        guard target >= 0, target < tracks.count else { return }
        model.focusedTrackId = tracks[target].id
    }
}
