import SwiftUI
@preconcurrency import JellifyCore

/// Generic numbered track row used by `AlbumDetailView`, `PlaylistView`,
/// and `SearchView`'s Tracks section. The caller supplies the ordinal number
/// and an `onPlay` closure so the row stays ignorant of whether it's part
/// of a disc-grouped album or a flat playlist.
///
/// Keyboard navigation (#105): rows are `.focusable()`, expose their id via
/// `model.focusedTrackId`, and handle Up / Down / Return / Space exactly like
/// `TrackListRow`. Callers that want arrow navigation between siblings must
/// pass a `siblings` array so the row can compute the previous / next id;
/// callers that don't (e.g. a one-off row) can leave it empty and only
/// Return / Space will work. See also the TODO on type-ahead in
/// `TrackListRow`.
struct TrackRow: View {
    @Environment(AppModel.self) private var model

    let track: Track
    let number: Int
    var onPlay: (() -> Void)? = nil
    /// Ordered list of sibling tracks this row belongs to, used to compute
    /// the previous / next focus target on arrow keys. Empty means "no
    /// siblings for nav" — the row will still be focusable and will still
    /// handle Return / Space, but Up / Down become no-ops.
    var siblings: [Track] = []
    /// Position of this row inside `siblings`. When `siblings` is empty
    /// this is ignored. Kept as an explicit argument so callers that
    /// already have `idx` from a `ForEach(enumerated)` don't have to pay
    /// for a linear scan through `siblings`.
    var siblingIndex: Int = 0
    /// When non-nil, the row is being rendered inside a playlist detail
    /// view; forwarded to `TrackContextMenu` so the right-click menu can
    /// surface a "Remove from Playlist" entry (#789).
    var playlistScope: Playlist? = nil

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
        HStack(spacing: 12) {
            // Number / play button / equalizer
            ZStack {
                if isPlaying {
                    EqualizerIcon()
                        .foregroundStyle(Theme.accent)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink)
                } else {
                    Text("\(number)")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink3)
                }
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                        .lineLimit(1)
                    FormatBadge(track: track)
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

            let isFav = model.isFavorite(track: track)
            if isFav || isHovering {
                Button {
                    model.toggleFavorite(track: track)
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isFav ? Theme.accent : Theme.ink2)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFav ? "Unfavorite" : "Favorite")
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
        // Native macOS focus ring. `.focusEffect()` (macOS 14+) lets the
        // system draw the ring rather than us approximating it with a
        // stroked overlay; combined with the inner .fill for `isActive` it
        // keeps the row legible both via pointer and keyboard nav.
        .focusEffectDisabled(false)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onPlay?() }
        .onTapGesture(count: 1) { onPlay?() }
        .contextMenu { TrackContextMenu(selection: [track], playlistScope: playlistScope) }
        // VoiceOver reads the row as a single "<title> by <artist>" line
        // with the button trait + hint so the double-tap play action is
        // discoverable without sighted hover affordances. See #331.
        .accessibilityElement(children: .ignore)
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
            onPlay?()
            return .handled
        }
        .onKeyPress(.space) {
            model.togglePlayPause()
            return .handled
        }
        // TODO(#105): Type-ahead (letter keys → first row whose title
        // starts with the buffer) is still outstanding. See the matching
        // TODO in `TrackListRow`.
    }

    private var rowBackground: Color {
        if isActive { return Theme.surface2 }
        if isFocused { return Theme.rowHover }
        if isHovering { return Theme.rowHover }
        return .clear
    }

    /// Move focus by `delta` within `siblings`. No-op when siblings wasn't
    /// provided — the row just stops responding to arrow keys, which is
    /// the same behaviour as any non-list focusable control.
    private func moveFocus(by delta: Int) {
        guard !siblings.isEmpty else { return }
        let target = siblingIndex + delta
        guard target >= 0, target < siblings.count else { return }
        model.focusedTrackId = siblings[target].id
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
