import AppKit
import SwiftUI
@preconcurrency import LyrebirdCore

/// Container formats that AVFoundation / CoreAudio can decode natively on
/// macOS without requiring server-side transcoding.
///
/// The list intentionally errs on the side of caution — only the codecs
/// that ship in every macOS installation and are reliably passthrough-able
/// are included. Less common formats (Opus in an Ogg container, WMA, etc.)
/// are treated as "needs transcoding" even if a particular machine happens
/// to have a plugin that can decode them, because the Jellyfin server can't
/// know that.
///
/// Strings are compared case-insensitively after `.lowercased()` at the
/// call site. Jellyfin reports `Container` as `"MPEG"` for MP3 files and
/// `"MPEG-4"` for AAC-in-MP4 / M4A, so those normalised forms must be
/// present alongside the file-extension aliases that other Jellyfin
/// transcoders / clients sometimes emit (`mp3`, `m4a`, etc.).
let directPlayContainers: Set<String> = [
    "aac", "mp3", "mpeg", "mp4", "mpeg-4", "m4a", "alac", "flac", "wav", "aiff", "aif",
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
    // Contrast-adaptive accent for foreground text/icons (active-track title,
    // now-playing equalizer, favorite heart). Lifts to `accentHot` under
    // Increase Contrast so accent foregrounds clear 4.5:1 (#888). The
    // decorative selection rail / focus-ring stroke / selection background
    // tint keep the base token.
    @Environment(\.accessibleTheme) private var a11yTheme
    let track: Track
    /// Full track list the row was rendered from, so tap-to-play can hand
    /// the entire ordered list to `AppModel.play` and index into it. This
    /// matches the `AlbumDetailView.trackList` contract.
    let tracks: [Track]
    let index: Int
    /// Whether this row is part of the caller's multi-selection. When `true`
    /// the row paints a selection rail + tint regardless of hover / active
    /// state. Callers that don't support multi-select leave this `false`.
    var isSelected: Bool = false
    /// Optional click router for multi-select hosts (#217). When non-nil the
    /// row hands every click (with its modifier flags) to the caller instead
    /// of playing immediately, so the host can resolve Cmd-toggle /
    /// Shift-range / bare-click-plays. When nil the row plays on click exactly
    /// as before — every existing single-select call site is unaffected.
    var onSelect: ((NSEvent.ModifierFlags) -> Void)? = nil
    /// Row density (#217). Bound by the Library Tracks tab to the user's
    /// `appearance.density` preference; defaults to roomy so other call sites
    /// keep their current look.
    var density: AppearanceDensity = .roomy
    @AppStorage("audio.transcodingPreference") private var transcodingRaw: String = TranscodingPreference.directPlay.rawValue
    // Reveal a track's play count on hover when the user opts in. The
    // Tracks tab has no number column, so the track-numbers toggle doesn't
    // apply here — only play-count-on-hover does.
    @AppStorage(LibraryDefaults.showPlayCountOnHoverKey) private var showPlayCountOnHover = false
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

    private var artworkSize: CGFloat { density.trackArtworkSize }

    var body: some View {
        rowContent
            // When a selection host is wired up, route clicks (with modifier
            // flags) to it; otherwise the inner Button handles the plain play
            // tap as before. Gestures only attach on the multi-select path so
            // the single-select path keeps the Button's full accessibility +
            // hover behaviour untouched.
            .modifier(SelectionClickModifier(onSelect: onSelect))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
            .overlay(alignment: .leading) {
                // Selection rail — 2pt accent bar on the leading edge so a
                // multi-selected row reads at a glance even when it's also
                // hovered. See #217.
                if isSelected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
                }
            }
            .contextMenu { TrackContextMenu(selection: [track]) }
            // Drag to Finder: materialises a `.m3u` file when the user drops
            // the row onto Finder or any M3U-accepting app (#14). Mirrors the
            // same modifier on `TrackRow`.
            .draggable(TrackM3UDrag(
                tracks: [track],
                serverURL: model.serverURL,
                core: model.core
            ))
            // A single row should read as one VoiceOver element — the wrapping
            // Button already carries a label, but we override it here to pull
            // in the active state so playing rows announce "Now playing" and
            // non-playing rows announce "Plays this track". `.combine` collapses
            // the artwork and text sub-views so the rotor sees one button per
            // row rather than several unlabelled children. See #588.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.name) by \(track.artistName)")
            .accessibilityHint(isPlaying ? "Now playing" : "Plays this track")
            .accessibilityAddTraits(accessibilityTraits)
            // MARK: Keyboard navigation (#105)
            .focusable()
            .focusEffectDisabled(false)
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

    private var accessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isPlaying || isSelected { traits.formUnion(.isSelected) }
        return traits
    }

    /// The row's visual content. When `onSelect` is nil this is wrapped in a
    /// play-on-tap `Button`; otherwise the host's gesture handler drives
    /// playback / selection so the same markup serves both paths.
    @ViewBuilder
    private var rowContent: some View {
        if onSelect == nil {
            Button {
                model.play(tracks: tracks, startIndex: index)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            ZStack {
                Artwork(
                    url: model.imageURL(
                        for: track.albumId ?? track.id,
                        tag: track.imageTag,
                        maxWidth: 120
                    ),
                    seed: track.albumName ?? track.name,
                    size: artworkSize,
                    radius: 4
                )
                if isPlaying {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.55))
                        .frame(width: artworkSize, height: artworkSize)
                    EqualizerIcon()
                        .foregroundStyle(a11yTheme.accent)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: artworkSize, height: artworkSize)
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: density == .compact ? 11 : 13))
                        .transition(.opacity)
                }
            }
            .frame(width: artworkSize, height: artworkSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? a11yTheme.accent : Theme.ink)
                        .lineLimit(1)
                    FormatBadge(track: track)
                    if willTranscode {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                            .help("Transcoding required. Enable in Preferences → Playback.")
                    }
                }
                // Compact density drops the artist subline so the row can
                // hit the 36pt target; the artist is still on the context
                // menu / Track Info and stays on the roomy default.
                if density != .compact {
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let album = track.albumName {
                Text(album)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .trailing)
            }

            let isFav = model.isFavorite(track: track)
            if isFav || isHovering {
                Button {
                    model.toggleFavorite(track: track)
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isFav ? a11yTheme.accent : Theme.ink2)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFav ? "Unfavorite" : "Favorite")
                // On the multi-select path the row carries a low-priority
                // bare-tap `.gesture` that routes to `onSelect`. A bare tap on
                // the heart must toggle the favorite *without* also triggering
                // selection/playback, so we shadow it with a high-priority tap
                // that wins the gesture arbitration and swallows the event
                // before it reaches the row's selection gesture. On the
                // single-select path (`onSelect == nil`) the row has no
                // competing gesture, so the plain Button action is left to
                // handle the tap on its own. See #217.
                .modifier(FavoriteTapShield(onSelect: onSelect) {
                    model.toggleFavorite(track: track)
                })
            }

            if showPlayCountOnHover, isHovering, track.playCount > 0 {
                Text(playCountLabel)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            Text(track.durationFormatted)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density == .compact ? 4 : 6)
        .frame(minHeight: density.trackRowHeight)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(0.18) }
        if isActive { return Theme.surface2 }
        if isFocused { return Theme.nativeHover }
        if isHovering { return Theme.nativeHover }
        return .clear
    }

    /// "1 play" / "12 plays" readout shown on hover when the user enables
    /// "Show play counts on hover".
    private var playCountLabel: String {
        CountStrings.label(Int(track.playCount), .plays)
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

// `SelectionClickModifier` and `FavoriteTapShield` — the gesture plumbing
// this row's multi-select path is built on — moved to
// `Components/TrackSelectionGestures.swift` when `TrackRow` adopted the same
// selection API for the playlist screen (#985).
