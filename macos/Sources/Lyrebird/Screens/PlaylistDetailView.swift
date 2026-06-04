import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import LyrebirdCore

/// Rich playlist detail view with multi-select remove and drop-to-add. The
/// hero mirrors `AlbumDetailView` (title, description, track count + total
/// runtime, Play / Shuffle / `•••` CTAs) and the track list follows the
/// `TrackListRow` density. Interactions land #74 and #236:
///
/// - **Multi-select**: Cmd+Click toggles a row into / out of the selection,
///   Shift+Click extends a contiguous range from the anchor. Bare-click
///   plays the row (same as `TrackListRow`) and resets the selection.
/// - **Delete / Backspace** on a non-empty selection calls
///   `AppModel.removeFromPlaylist` (optimistic local drop; the real
///   `core.remove_from_playlist` FFI is tracked in core-#128 — see the
///   TODO in `AppModel`). The dropped batch is stashed and an overlay
///   toast offers a 10-second undo window that restores via
///   `core.add_to_playlist`.
/// - **Drop-to-add**: a `.onDrop(of: [.data] + [.plainText])` handler on
///   the view reads any UTF-8 payload that parses as one or more Jellyfin
///   track ids (either a JSON array of strings or a newline-separated
///   blob) and fires `AppModel.addToPlaylist`. Minimal by design — the
///   drop source's Transferable format is up to the caller; a plain
///   newline-separated track-id list is the interoperable fallback.
///
/// Not reachable from `MainShell` yet — #313's routing uses the older
/// `PlaylistView`. Wiring this up behind `.playlist(id)` is a one-line
/// swap in `MainShell` that lives outside the scope of this PR per the
/// "do not touch other screens" guideline.
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: String

    /// Row ids currently in the user's multi-selection. Empty means no
    /// selection; single-element means one row is highlighted; more means
    /// a batch operation (Delete, contiguous extend, etc.) applies. Reset
    /// when the user plays a track via a bare click.
    @State private var selectedTrackIds: Set<String> = []
    /// The last-interacted row's index, used as the anchor for Shift+Click
    /// range extension. Falls back to 0 when no selection has been made.
    @State private var anchorIndex: Int? = nil
    /// True while a drop is being dragged over the view — gates a subtle
    /// highlight so the user sees where their drop will land.
    @State private var isDropTargeted: Bool = false

    /// Controls whether the undo toast is visible. Flipped on by
    /// `removeFromPlaylist`; flipped off by the 10s timer, an Undo tap, or
    /// navigating away from the view.
    @State private var showUndoToast: Bool = false
    /// Work item backing the 10s auto-dismiss. Held so a second remove
    /// batch within the window cancels the prior timer before scheduling
    /// a fresh one. See `scheduleUndoDismiss`.
    @State private var undoDismissWork: DispatchWorkItem?

    @State private var isLoading: Bool = true

    private var playlist: Playlist? {
        model.playlist(id: playlistID)
    }

    private var tracks: [Track] {
        model.currentPlaylistTracks
    }

    private var totalRuntimeFormatted: String {
        let seconds = tracks.reduce(0.0) { $0 + Double($1.runtimeTicks) / 10_000_000.0 }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    transportBar
                    trackList
                }
            }
            .background(Theme.bg)

            if showUndoToast, let pending = model.pendingPlaylistRemoval {
                UndoRemovalToast(
                    count: pending.tracks.count,
                    onUndo: handleUndo,
                    onDismiss: dismissUndoToast
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showUndoToast)
        // Backspace / Delete on a non-empty selection → remove. SwiftUI
        // routes `.onKeyPress` to whichever focusable view is key; we
        // `.focusable(true)` the whole scene so the view is eligible.
        .focusable(true)
        .onKeyPress(.delete) { handleDeleteKey() }
        .onKeyPress(.deleteForward) { handleDeleteKey() }
        // Alt+Up / Alt+Down: keyboard reorder for the focused (single-selected) track.
        // Only fires when exactly one row is selected so the semantics are unambiguous.
        .onKeyPress(.upArrow, phases: .down) { event in
            guard event.modifiers.contains(.option) else { return .ignored }
            return handleKeyboardReorder(direction: .up)
        }
        .onKeyPress(.downArrow, phases: .down) { event in
            guard event.modifiers.contains(.option) else { return .ignored }
            return handleKeyboardReorder(direction: .down)
        }
        // Drop-to-add: accept any data (tracks as JSON-of-ids or newline
        // list, per the view doc comment). See `handleDrop`.
        .onDrop(
            of: [UTType.data, UTType.plainText, UTType.utf8PlainText],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            // Subtle drop-target indicator — a 2pt inset accent border. The
            // list content stays fully visible so the user's sense of where
            // the drop will land is intact.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.accent, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .task(id: playlistID) {
            isLoading = true
            await model.loadPlaylistTracks(playlistId: playlistID)
            isLoading = false
        }
        .onDisappear {
            // Prevent the auto-dismiss firing against a detached view.
            undoDismissWork?.cancel()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let playlist = playlist {
            VStack(alignment: .leading, spacing: 12) {
                Text("PLAYLIST")
                    .font(Theme.font(11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .tracking(3)

                Text(playlist.name)
                    .font(Theme.font(44, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                    .tracking(-1)
                    .lineLimit(2)

                if let description = model.playlistDescriptions[playlist.id], !description.isEmpty {
                    Text(description)
                        .font(Theme.font(13, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(3)
                }

                HStack(spacing: 10) {
                    Text("\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")")
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                    Text("·")
                        .foregroundStyle(Theme.ink3)
                    Text(totalRuntimeFormatted)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 20)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        } else {
            HStack {
                Text("Playlist not found")
                    .font(Theme.font(16, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
        }
    }

    // MARK: - Transport bar

    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                if !tracks.isEmpty { model.play(tracks: tracks, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel("Play playlist")

            Button {
                if !tracks.isEmpty {
                    model.play(tracks: tracks.shuffled(), startIndex: 0)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel("Shuffle playlist")

            Menu {
                if let playlist = playlist {
                    Button("Play Next") { model.playNext(playlist: playlist) }
                        .disabled(true)
                    Button("Add to Queue") { model.addToQueue(playlist: playlist) }
                        .disabled(true)
                    Divider()
                    Button("Export as M3U…") { model.exportPlaylist(playlist: playlist) }
                        .disabled(tracks.isEmpty)
                    Button("Export as JSON…") { model.exportPlaylistJSON(playlist: playlist) }
                        .disabled(tracks.isEmpty)
                    Divider()
                    Button("Copy Link") { model.copyShareLink(playlist: playlist) }
                        .disabled(model.webURL(for: playlist) == nil)
                    Button("Open in Jellyfin") { model.openInJellyfin(playlist: playlist) }
                        .disabled(model.webURL(for: playlist) == nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 36)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")

            Spacer()

            if !selectedTrackIds.isEmpty {
                Text("\(selectedTrackIds.count) selected")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Button {
                    performRemove(ids: Array(selectedTrackIds))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Remove")
                            .font(Theme.font(12, weight: .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.danger.opacity(0.25))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.danger, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(selectedTrackIds.count) selected tracks from playlist")
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isLoading {
                ProgressView()
                    .tint(Theme.ink2)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if tracks.isEmpty {
                Text("No tracks in this playlist")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    SelectableTrackRow(
                        track: track,
                        tracks: tracks,
                        index: idx,
                        isSelected: selectedTrackIds.contains(track.id),
                        onClick: { modifiers in handleRowClick(index: idx, modifiers: modifiers) }
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    // MARK: - Selection handling

    /// Resolve a click on `index` given the current modifier state into a
    /// new selection set. Cmd toggles the hit row. Shift extends the range
    /// from `anchorIndex` to the hit row. Bare click plays the row.
    private func handleRowClick(index: Int, modifiers: NSEvent.ModifierFlags) {
        let track = tracks[index]
        if modifiers.contains(.command) {
            if selectedTrackIds.contains(track.id) {
                selectedTrackIds.remove(track.id)
            } else {
                selectedTrackIds.insert(track.id)
            }
            anchorIndex = index
        } else if modifiers.contains(.shift) {
            let from = anchorIndex ?? index
            let range = from <= index ? from...index : index...from
            var next = selectedTrackIds
            for i in range where tracks.indices.contains(i) {
                next.insert(tracks[i].id)
            }
            selectedTrackIds = next
            anchorIndex = index
        } else {
            // Bare click → play the track and reset any selection.
            selectedTrackIds = []
            anchorIndex = index
            model.play(tracks: tracks, startIndex: index)
        }
    }

    /// Handle Delete / Backspace on the list. Only fires a remove when at
    /// least one row is selected — otherwise the key press is ignored so
    /// the event continues to propagate.
    private func handleDeleteKey() -> KeyPress.Result {
        guard !selectedTrackIds.isEmpty else { return .ignored }
        performRemove(ids: Array(selectedTrackIds))
        return .handled
    }

    private func performRemove(ids: [String]) {
        guard !ids.isEmpty else { return }
        model.removeFromPlaylist(playlistId: playlistID, entryIds: ids)
        selectedTrackIds = []
        anchorIndex = nil
        showUndoToast = true
        scheduleUndoDismiss()
    }

    /// Move the single-selected track one step up or down via keyboard.
    ///
    /// Only handles a single-row selection; multi-select reorder has no
    /// well-defined UX so the key is ignored when more than one row is
    /// selected. Bounds: Up is ignored at index 0; Down is ignored at the
    /// last index. Uses the same `moveTrackInPlaylist` path as drag-and-drop.
    ///
    /// `moveTrackInPlaylist` uses SwiftUI `move(fromOffsets:toOffset:)`
    /// insertion-index semantics:
    ///   - Move UP:   from = i, to = i - 1   (insert before predecessor)
    ///   - Move DOWN: from = i, to = i + 2   (insert after successor in
    ///                pre-remove coordinates where successor is still at i+1)
    private func handleKeyboardReorder(direction: VerticalDirection) -> KeyPress.Result {
        guard selectedTrackIds.count == 1,
              let trackId = selectedTrackIds.first,
              let currentIndex = tracks.firstIndex(where: { $0.id == trackId })
        else { return .ignored }

        let lastIndex = tracks.count - 1
        switch direction {
        case .up:
            guard currentIndex > 0 else { return .ignored }
            model.moveTrackInPlaylist(playlistId: playlistID, from: currentIndex, to: currentIndex - 1)
            // Keep anchor in sync so Shift+Click range-extend still works.
            anchorIndex = currentIndex - 1
        case .down:
            guard currentIndex < lastIndex else { return .ignored }
            model.moveTrackInPlaylist(playlistId: playlistID, from: currentIndex, to: currentIndex + 2)
            anchorIndex = currentIndex + 1
        }
        return .handled
    }

    // MARK: - Undo toast

    private func scheduleUndoDismiss() {
        undoDismissWork?.cancel()
        let work = DispatchWorkItem {
            showUndoToast = false
            // Also clear the stash so a later "undo" tap after the window
            // can't resurrect a stale batch.
            model.pendingPlaylistRemoval = nil
        }
        undoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func handleUndo() {
        undoDismissWork?.cancel()
        model.undoRemoveFromPlaylist()
        showUndoToast = false
    }

    private func dismissUndoToast() {
        undoDismissWork?.cancel()
        showUndoToast = false
        model.pendingPlaylistRemoval = nil
    }

    // MARK: - Drop handling

    /// Read any pasted / dropped track-id payloads out of `providers` and
    /// forward to `AppModel.addToPlaylist`. Accepts two shapes, in order of
    /// preference:
    ///
    /// - JSON array of strings: `["id-1","id-2"]` — the canonical form a
    ///   future `Track: Transferable` conformance would emit via its
    ///   `.data` representation.
    /// - Newline-separated plain text — interop fallback for drops coming
    ///   from external sources (e.g. a text file of ids, or a hand-rolled
    ///   `.plainText` Transferable implementation).
    ///
    /// Returns `true` as long as at least one provider is in flight so
    /// SwiftUI's drop affordance confirms the drop visually. The actual
    /// add happens asynchronously after the provider resolves.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let playlistId = playlistID
        // Best-effort: try data first, then fall back to plain-text.
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { data, _ in
                    guard let data else { return }
                    let ids = parseTrackIds(from: data)
                    guard !ids.isEmpty else { return }
                    Task { @MainActor in
                        model.addToPlaylist(playlistId: playlistId, trackIds: ids)
                        await model.loadPlaylistTracks(playlistId: playlistId)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data else { return }
                    let ids = parseTrackIds(from: data)
                    guard !ids.isEmpty else { return }
                    Task { @MainActor in
                        model.addToPlaylist(playlistId: playlistId, trackIds: ids)
                        await model.loadPlaylistTracks(playlistId: playlistId)
                    }
                }
            }
        }
        return true
    }

    /// Pull a list of track ids out of arbitrary dropped bytes. Tries JSON
    /// first, then newline-separated text; ignores blanks and whitespace.
    private func parseTrackIds(from data: Data) -> [String] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return json.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Row

/// A click-only wrapper around the same visual density as `TrackListRow`.
/// The difference from `TrackListRow` is that clicks are intercepted before
/// they fire `model.play` so the parent can resolve Cmd/Shift modifiers and
/// drive multi-selection. Right-clicks still bring up the standard track
/// context menu through the parent's `.contextMenu` surface (follow-up).
private struct SelectableTrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let tracks: [Track]
    let index: Int
    let isSelected: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void

    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }

    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    var body: some View {
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
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // Selection rail — a 2pt accent bar on the leading edge so
            // selection reads at-a-glance even on wide rows.
            if isSelected {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .gesture(
            TapGesture().modifiers(.command).onEnded { onClick(.command) }
        )
        .gesture(
            TapGesture().modifiers(.shift).onEnded { onClick(.shift) }
        )
        .simultaneousGesture(
            TapGesture().onEnded { onClick([]) }
        )
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.18))
        } else if isActive {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surface2)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 6).fill(Theme.rowHover)
        } else {
            Color.clear
        }
    }
}

// MARK: - Helpers

/// Direction enum used by `handleKeyboardReorder` to avoid raw booleans.
private enum VerticalDirection { case up, down }

// MARK: - Undo toast

private struct UndoRemovalToast: View {
    let count: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    private var message: String {
        count == 1 ? "Removed 1 track" : "Removed \(count) tracks"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Spacer(minLength: 12)

            Button(action: onUndo) {
                Text("Undo")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accent.opacity(0.28))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.accent, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo remove")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgAlt)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}
