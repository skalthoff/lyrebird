import SwiftUI
@preconcurrency import LyrebirdCore

/// Full-page Play Queue view (⌘U, #81). A larger-format counterpart to the
/// 320pt `QueueInspector` drawer, suited to bulk review of what's coming and
/// what just played. Pushed onto `navPath` as `Route.fullQueue` and rendered
/// by `MainShell`; ⌘U toggles it via `AppModel.toggleFullQueue`.
///
/// Layout (top → bottom):
///   1. **Header** — title + "Save Queue as Playlist" action.
///   2. **Recently in this session** — up to 50 tracks played earlier in
///      *this app session* (newest first), drawn from `sessionPlayHistory`.
///      Matches Spotify's "history above the now-playing line" affordance so
///      the user can re-queue something they just heard.
///   3. **Now Playing** — the currently-playing track.
///   4. **Up Next** — the user-added queue (`upNextUserAdded`).
///   5. **Playing From {source}** — the auto-queue tail (`upNextAutoQueue`).
///
/// Reorder / drag affordances stay in the inspector (#80); this page is a
/// read-and-bulk-act surface, so rows are click-to-play with a context menu
/// rather than draggable. "Save Queue as Playlist" reuses the same
/// `AppModel.saveQueueAsPlaylist(name:)` path the inspector's Save uses, so
/// error surfacing + the older-server top-up behaviour come for free.
struct FullQueueView: View {
    @Environment(AppModel.self) private var model

    @State private var showSaveSheet = false
    @State private var saveDraftName = ""

    /// The currently-playing track id, read once here so each row can be told
    /// whether *it* is active via a plain `String?` rather than each row
    /// reaching into `model.status` itself. Under `@Observable`, a row that
    /// observes `model.status` re-renders on every 1Hz poll tick; threading a
    /// narrow value down means only the row whose active/playing state actually
    /// changed gets rebuilt (#119).
    private var currentTrackId: String? { model.status.currentTrack?.id }

    /// Whether the active track is currently playing (vs paused). Combined with
    /// `currentTrackId` this is the only status-derived signal rows need, so
    /// they no longer depend on the full `PlayerStatus` value.
    private var isPlaying: Bool { model.status.state == .playing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !model.sessionPlayHistory.isEmpty {
                    sessionHistorySection
                }
                nowPlayingSection
                upNextSection
                playingFromSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        // Save-queue sheet. Mirrors the inspector's flow so the two Save
        // entry points behave identically. Kept local to this view — the
        // shared work is `saveQueueAsPlaylist(name:)` on the model.
        .sheet(isPresented: $showSaveSheet, onDismiss: { saveDraftName = "" }) {
            FullQueueSaveSheet(
                name: $saveDraftName,
                trackCount: saveTrackCount,
                onCancel: { showSaveSheet = false },
                onSave: {
                    let trimmed = saveDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    showSaveSheet = false
                    Task { await model.saveQueueAsPlaylist(name: trimmed) }
                }
            )
            .environment(model)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Play Queue")
                    .font(Theme.font(28, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text(queueSummary)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            Button(action: beginSave) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Save Queue as Playlist")
                        .font(Theme.font(12, weight: .semibold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saveTrackCount == 0)
            .accessibilityLabel("Save Queue as Playlist")
            .accessibilityHint("Creates a new playlist from the current queue")
        }
    }

    /// One-line summary of the queue size, e.g. "12 up next · 8 played this
    /// session". Reads as a stable status line under the title.
    private var queueSummary: String {
        let upcoming = model.upNextUserAdded.count + model.upNextAutoQueue.count
        let played = model.sessionPlayHistory.count
        var parts: [String] = []
        parts.append("\(upcoming) up next")
        if played > 0 { parts.append("\(played) played this session") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Recently in this session (#81)

    @ViewBuilder
    private var sessionHistorySection: some View {
        let history = model.sessionPlayHistory
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recently in this session")
            // LazyVStack so off-screen history rows aren't materialized for a
            // long session (#119). `id: \.offset` keeps duplicate track ids
            // (a song replayed in-session) as distinct rows.
            LazyVStack(spacing: 2) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, track in
                    FullQueueTrackRow(
                        track: track,
                        queue: history,
                        index: index,
                        currentTrackId: currentTrackId,
                        isPlayingActive: isPlaying
                    )
                }
            }
        }
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Now Playing")
            if let track = model.status.currentTrack {
                // Hand the Now Playing row the *whole* reconstructed queue
                // (current + user-added + auto tail) at index 0, so tapping it
                // re-seeks the current track without collapsing the queue to a
                // single entry (#134). The earlier `queue: [track]` form rebuilt
                // the queue with just this track, wiping Up Next / Playing From.
                FullQueueTrackRow(
                    track: track,
                    queue: reconstructedQueue,
                    index: 0,
                    currentTrackId: currentTrackId,
                    isPlayingActive: isPlaying
                )
            } else {
                emptyRow("Nothing is playing.")
            }
        }
    }

    /// The full forward queue as the player sees it: the current track, then
    /// the user-added Up Next entries, then the auto-queue tail. Used so the
    /// Now Playing row can re-seek to index 0 without clobbering everything
    /// after it. Logic lives in `FullQueuePlayback` so it stays testable.
    private var reconstructedQueue: [Track] {
        FullQueuePlayback.reconstructedQueue(
            current: model.status.currentTrack,
            upNextUserAdded: model.upNextUserAdded.map(\.track),
            upNextAutoQueue: model.upNextAutoQueue.map(\.track)
        )
    }

    // MARK: - Up Next

    @ViewBuilder
    private var upNextSection: some View {
        let entries = model.upNextUserAdded
        let tracks = entries.map(\.track)
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Up Next")
            if entries.isEmpty {
                emptyRow("Nothing queued. Use \u{2318}-click \u{2192} Play Next on a track.")
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        FullQueueTrackRow(
                            track: entry.track,
                            queue: tracks,
                            index: index,
                            currentTrackId: currentTrackId,
                            isPlayingActive: isPlaying
                        )
                    }
                }
            }
        }
    }

    // MARK: - Playing From

    @ViewBuilder
    private var playingFromSection: some View {
        let entries = model.upNextAutoQueue
        let tracks = entries.map(\.track)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let seed = model.radioSeedName {
                    RadioQueueHeader(seed: seed)
                } else {
                    sectionHeader(playingFromTitle)
                }
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        FullQueueTrackRow(
                            track: entry.track,
                            queue: tracks,
                            index: index,
                            currentTrackId: currentTrackId,
                            isPlayingActive: isPlaying
                        )
                    }
                }
            }
        }
    }

    private var playingFromTitle: String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "Playing From \(name)"
        }
        return "Playing From Queue"
    }

    // MARK: - Actions

    /// Number of tracks the Save action would write: current + user-added +
    /// auto tail. Drives the disabled state and the sheet's count copy.
    /// History is intentionally excluded — Save persists what's queued, not
    /// what already played, matching the inspector's Save semantics.
    private var saveTrackCount: Int {
        let current = model.status.currentTrack == nil ? 0 : 1
        return current + model.upNextUserAdded.count + model.upNextAutoQueue.count
    }

    private func beginSave() {
        saveDraftName = defaultPlaylistName()
        showSaveSheet = true
    }

    private func defaultPlaylistName() -> String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "\(name) + Up Next"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Queue \(formatter.string(from: Date()))"
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(11, weight: .bold))
            .foregroundStyle(Theme.ink2)
            .tracking(1.5)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Playback planning

/// Pure helpers behind the full-queue rows' tap-to-play behaviour, kept out of
/// the SwiftUI views so they're unit-testable without a scene graph (mirrors
/// `TrackSelectionResolver`). Two decisions live here:
///
///   * `reconstructedQueue` — the forward queue handed to the Now Playing row
///     so a tap re-seeks index 0 instead of collapsing the queue (#134).
///   * `plan(queue:tappedIndex:)` — the `(tracks, startIndex)` pair for a tap,
///     resolved by the tapped row's *position* so a duplicate track id starts
///     at the row the user actually clicked (#340).
enum FullQueuePlayback {
    /// The full forward queue as the player sees it: the current track, then
    /// the user-added Up Next entries, then the auto-queue tail. Mirrors the
    /// order `saveQueueAsPlaylist` persists. Empty when nothing is playing.
    static func reconstructedQueue(
        current: Track?,
        upNextUserAdded: [Track],
        upNextAutoQueue: [Track]
    ) -> [Track] {
        guard let current else { return [] }
        return [current] + upNextUserAdded + upNextAutoQueue
    }

    /// Resolve the `(tracks, startIndex)` pair for a tapped row. Uses the row's
    /// own `tappedIndex` rather than `firstIndex(by id)` so a duplicate track
    /// id elsewhere in the queue starts at the tapped row (#340). Falls back to
    /// a single-track queue (`fallbackTrack`, the row's own track) at index 0
    /// when `tappedIndex` is out of bounds — defensive only; call sites always
    /// pass an in-range index.
    static func plan(
        queue: [Track],
        tappedIndex: Int,
        fallbackTrack: Track
    ) -> (tracks: [Track], startIndex: Int) {
        guard queue.indices.contains(tappedIndex) else {
            return ([fallbackTrack], 0)
        }
        return (queue, tappedIndex)
    }
}

// MARK: - Row

/// One track row in the full-page queue. Click plays the track in the
/// context of its surrounding list (`queue`) so auto-advance continues
/// naturally — the same contract `TopTrackRow` uses. Right-click surfaces
/// the shared `TrackContextMenu` (Play Next / Add to Queue / favorite / …).
///
/// Active/playing state is passed in as plain values (`currentTrackId` +
/// `isPlayingActive`) rather than read from `model.status` inside the row, so
/// only the row whose state actually changed re-renders on a status tick
/// instead of the whole list every 1Hz poll (#119).
private struct FullQueueTrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: Track
    /// The list this row belongs to, passed to `play(tracks:startIndex:)` so
    /// playback continues through the rest of the section.
    let queue: [Track]
    /// This row's position within `queue`. Threaded explicitly so a duplicate
    /// track id elsewhere in the queue (e.g. a song replayed in session
    /// history) starts playback at *this* row, not the first matching id
    /// (#340).
    let index: Int
    /// Id of the track currently loaded in the player, or nil. Compared against
    /// `track.id` to decide whether this row is the active one.
    let currentTrackId: String?
    /// Whether the active track is playing (vs paused). Only meaningful when
    /// this row is the active one.
    let isPlayingActive: Bool

    @State private var isHovering = false

    private var isActive: Bool {
        currentTrackId == track.id
    }
    private var isPlaying: Bool {
        isActive && isPlayingActive
    }

    var body: some View {
        Button(action: playFromHere) {
            HStack(spacing: 12) {
                ZStack {
                    if isPlaying {
                        EqualizerIcon()
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink)
                    } else {
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
                        .frame(width: 40, height: 40)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let album = track.albumName, !album.isEmpty {
                    Text(album)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                }

                Text(track.durationFormatted)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
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
        .focusable(true)
        .focusEffectDisabled(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityHint("Plays this track")
        .accessibilityAddTraits(.isButton)
    }

    /// Start playback at this row, handing the surrounding list to
    /// `play(tracks:startIndex:)` so the rest of the section queues up. Uses
    /// the row's own `index` rather than `firstIndex(by id)` so a duplicate
    /// track id in the queue starts at the tapped row (#340). Planning logic
    /// lives in `FullQueuePlayback` so it stays testable.
    private func playFromHere() {
        let plan = FullQueuePlayback.plan(
            queue: queue,
            tappedIndex: index,
            fallbackTrack: track
        )
        model.play(tracks: plan.tracks, startIndex: plan.startIndex)
    }
}

// MARK: - Save sheet

/// Name-and-save sheet for the full-page queue. Functionally identical to
/// the inspector's `SaveQueueSheet`, kept private here so the full-page view
/// stays self-contained; both call `AppModel.saveQueueAsPlaylist(name:)`.
private struct FullQueueSaveSheet: View {
    @Binding var name: String
    let trackCount: Int
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save queue as playlist")
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Creates a new playlist with \(CountStrings.label(trackCount, .tracks)).")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(12, weight: .medium))
                .focused($focused)
                .onSubmit { onSave() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}
