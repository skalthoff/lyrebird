import AppKit
import SwiftUI
@preconcurrency import LyrebirdCore

/// Generic numbered track row used by `AlbumDetailView`, `PlaylistView`,
/// and `SearchView`'s Tracks section. The caller supplies the ordinal number
/// and an `onPlay` closure so the row stays ignorant of whether it's part
/// of a disc-grouped album or a flat playlist.
///
/// Keyboard navigation (#105): rows are `.focusable()`, expose their id via
/// `model.focusedTrackId`, and handle Up / Down / Return / Space exactly like
/// `TrackListRow`. Callers thread the full ordered `tracks` array plus this
/// row's `index` so Up / Down can move the shared focus cursor to the
/// previous / next row; when a move isn't possible (list bounds, or a
/// caller that left `tracks` empty) the arrow key is declined so the OS
/// default focus-ring traversal still works. See also the TODO on
/// type-ahead in `TrackListRow`.
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    // Contrast-adaptive accent for foreground text/icons (active-track title,
    // now-playing equalizer, favorite heart). Lifts to `accentHot` under
    // Increase Contrast so accent foregrounds clear 4.5:1 (#888). The
    // decorative focus-ring stroke keeps the base token.
    @Environment(\.accessibleTheme) private var a11yTheme

    let track: Track
    let number: Int
    var onPlay: (() -> Void)? = nil
    /// Ordered list of tracks this row belongs to, used to compute the
    /// previous / next focus target on arrow keys. Mirrors
    /// `TrackListRow.tracks`. Empty means "no siblings for nav" — the row
    /// stays focusable and still handles Return / Space, but Up / Down are
    /// declined (`.ignored`) so default focus traversal takes over.
    var tracks: [Track] = []
    /// Position of this row inside `tracks`. When `tracks` is empty this is
    /// ignored. Kept as an explicit argument so callers that already have
    /// `idx` from a `ForEach(enumerated)` don't pay for a linear scan.
    var index: Int = 0
    /// When non-nil, the row is being rendered inside a playlist detail
    /// view; forwarded to `TrackContextMenu` so the right-click menu can
    /// surface a "Remove from Playlist" entry (#789).
    var playlistScope: Playlist? = nil
    /// Whether this row is part of the caller's multi-selection. When `true`
    /// the row paints a selection rail + tint regardless of hover / active
    /// state. Callers that don't support multi-select leave this `false`.
    /// Mirrors `TrackListRow.isSelected` (#217 / #985).
    var isSelected: Bool = false
    /// Optional click router for multi-select hosts (#217 / #985). When
    /// non-nil the row hands every click (with its modifier flags) to the
    /// caller instead of playing immediately, so the host can resolve
    /// Cmd-toggle / Shift-range / bare-click-plays. When nil the row plays on
    /// click exactly as before — every existing single-select call site is
    /// unaffected. Mirrors `TrackListRow.onSelect`.
    var onSelect: ((NSEvent.ModifierFlags) -> Void)? = nil

    @AppStorage("audio.transcodingPreference") private var transcodingRaw: String = TranscodingPreference.directPlay.rawValue
    // Library preferences. Track numbers default on; play-count-on-hover
    // defaults off so the row stays clean until the user opts in.
    @AppStorage(LibraryDefaults.showTrackNumbersKey) private var showTrackNumbers = true
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

    var body: some View {
        HStack(spacing: 12) {
            // Number / play button / equalizer. When the user hides track
            // numbers the static ordinal disappears but the play /
            // equalizer affordances stay — and the column keeps its width so
            // every row's title still aligns.
            ZStack {
                if isPlaying {
                    EqualizerIcon()
                        .foregroundStyle(a11yTheme.accent)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink)
                } else if showTrackNumbers {
                    Text("\(number)")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(isActive ? a11yTheme.accent : Theme.ink3)
                }
            }
            .frame(width: 32)

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
                    // Offline-download status (#819). Reads the cached snapshot
                    // (`model.downloadState`), never the core synchronously, so
                    // this stays cheap per row. Renders nothing while the
                    // downloads feature is dormant (state is always nil).
                    downloadBadge
                }
                Text(track.artistName)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }

            Spacer()

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
                // On the multi-select path the row carries a bare-tap
                // `.gesture` that routes to `onSelect`; the shield lets the
                // heart claim taps that land on it so toggling a favorite
                // never also clears the selection. No-op when `onSelect` is
                // nil. See #217 / #985.
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            // Selection rail — 2pt accent bar on the leading edge so a
            // multi-selected row reads at a glance even when it's also
            // hovered. Mirrors `TrackListRow` (#217 / #985).
            if isSelected {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
        .onHover { isHovering = $0 }
        // When a selection host is wired up, route clicks (with modifier
        // flags) to it through the shared gesture stack; otherwise keep the
        // plain play-on-tap exactly as before. See #217 / #985.
        .modifier(SelectionClickModifier(onSelect: onSelect))
        .modifier(PlayTapWhenUnselectableModifier(onSelect: onSelect, onPlay: onPlay))
        .contextMenu { TrackContextMenu(selection: [track], playlistScope: playlistScope) }
        // Drag to Finder: materialises a `.m3u` file referencing the Jellyfin
        // stream URL so the user can drop the row onto VLC/Finder and play it
        // outside the app (#14). `TrackM3UDrag` is a `Transferable` whose
        // `FileRepresentation` exporter resolves the api_key and writes the
        // temp file asynchronously once the user completes the drop — the drag
        // gesture itself is instantaneous.
        .draggable(TrackM3UDrag(
            tracks: [track],
            serverURL: model.serverURL,
            core: model.core
        ))
        // VoiceOver reads the row as a single "<title> by <artist>" line
        // with the button trait + hint so the double-tap play action is
        // discoverable without sighted hover affordances. See #331.
        .accessibilityElement(children: .ignore)
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
            if newId == track.id && !isFocused {
                isFocused = true
            }
        }
        .onKeyPress(.upArrow) {
            // Only claim the key if we actually moved focus; otherwise
            // decline so SwiftUI's default focus-ring traversal runs.
            moveFocus(by: -1) ? .handled : .ignored
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            onPlay?()
            return .handled
        }
        .onKeyPress(.space) {
            // Space toggles global transport, but only from the row that is
            // the current player target. From any other row we decline so
            // the event isn't trapped and default Space behaviour (e.g.
            // scrolling, button activation) still works.
            guard TrackRowKeyboard.spaceTogglesTransport(isActive: isActive) else {
                return .ignored
            }
            model.togglePlayPause()
            return .handled
        }
        // TODO(#105): Type-ahead (letter keys → first row whose title
        // starts with the buffer) is still outstanding. See the matching
        // TODO in `TrackListRow`.
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(0.18) }
        if isActive { return Theme.surface2 }
        if isFocused { return Theme.nativeHover }
        if isHovering { return Theme.nativeHover }
        return .clear
    }

    /// Mirrors `TrackListRow.accessibilityTraits`: a multi-selected row
    /// announces as selected even when it isn't the playing one (#985).
    private var accessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isPlaying || isSelected { traits.formUnion(.isSelected) }
        return traits
    }

    /// Inline download-status glyph (#819). `.done` shows a solid offline
    /// check; an in-progress state shows a small spinner. Absent state renders
    /// nothing, which is the case for every row while the feature is dormant.
    @ViewBuilder
    private var downloadBadge: some View {
        switch model.downloadState(forTrackId: track.id) {
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(a11yTheme.accent)
                .help("Available offline")
                .accessibilityLabel("Downloaded")
        case .queued, .downloading:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .help("Downloading…")
                .accessibilityLabel("Downloading")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warning)
                .help("Download failed")
                .accessibilityLabel("Download failed")
        case .none:
            EmptyView()
        }
    }

    /// "1 play" / "12 plays" readout shown on hover when the user enables
    /// "Show play counts on hover". Matches `TopTrackRow`'s wording.
    private var playCountLabel: String {
        CountStrings.label(Int(track.playCount), .plays)
    }

    /// Move the shared focus cursor by `delta` within `tracks`. Returns
    /// `true` when focus actually moved (the caller marks the key handled),
    /// `false` when there's nowhere to go — no siblings, or already at a
    /// list edge — so the caller can decline the key and let the OS take
    /// over default focus traversal.
    private func moveFocus(by delta: Int) -> Bool {
        guard let targetId = TrackRowKeyboard.focusTarget(tracks: tracks, index: index, delta: delta) else {
            return false
        }
        model.focusedTrackId = targetId
        return true
    }
}

/// Pure decision logic for `TrackRow`'s keyboard handling, extracted so the
/// focus-traversal bounds and the Space-transport scoping can be unit-tested
/// without realizing a SwiftUI view or a live window server. Mirrors the
/// extract-the-decision pattern used by `MenuBarNowPlaying`.
enum TrackRowKeyboard {
    /// The id of the track `delta` positions away from `index` inside
    /// `tracks`, or `nil` when that lands outside the list (or `tracks` is
    /// empty). A `nil` result means the arrow key should be declined.
    static func focusTarget(tracks: [Track], index: Int, delta: Int) -> String? {
        guard !tracks.isEmpty else { return nil }
        let target = index + delta
        guard target >= 0, target < tracks.count else { return nil }
        return tracks[target].id
    }

    /// Whether a Space press on this row should toggle global transport.
    /// Only the active (currently-playing-target) row claims Space; every
    /// other row declines it so the event isn't trapped.
    static func spaceTogglesTransport(isActive: Bool) -> Bool {
        isActive
    }
}

/// Tiny three-bar equalizer visual for the "now playing" row.
/// Respects Reduce Motion: swaps to a static three-bar glyph when on.
struct EqualizerIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Static heights used when Reduce Motion is enabled — chosen to read as
    /// a recognizable EQ glyph without implying motion.
    private let staticHeights: [CGFloat] = [9, 12, 7]

    var body: some View {
        if reduceMotion {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Rectangle()
                        .frame(width: 3, height: staticHeights[i])
                }
            }
            .frame(height: 14)
            .accessibilityLabel("Now playing")
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        let height = 4 + CGFloat(abs(sin(t * 3 + Double(i) * 0.7))) * 10
                        Rectangle()
                            .frame(width: 3, height: height)
                            .animation(.linear(duration: 0.1), value: height)
                    }
                }
                .frame(height: 14)
            }
            .accessibilityLabel("Now playing")
        }
    }
}
