import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Queue inspection and editing on `AppModel`: the "Up Next" inspector
/// projection (current + upcoming items with their source context), and the
/// queue-editing actions — move/remove/clear, remove-with-undo, jump-to-index,
/// and reordering that syncs back to the core queue via
/// `syncCoreQueueAfterReorder`.
///
/// The queue snapshot/inspector stored state stays on the main `AppModel`
/// class — stored properties can't live in an extension. Extensions of a
/// `@MainActor` type inherit its isolation, so every method here is
/// main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Queue inspector (BATCH-07a)

    /// Toggle the right-side Queue Inspector panel. Bound to the Cmd+Opt+Q
    /// keyboard shortcut via `MainShell`. See #79.
    func toggleQueueInspector() {
        isQueueInspectorOpen.toggle()
    }

    /// Push a track onto the in-session play history, most-recent first
    /// (#81). De-duplicates against the current head so a track that loops
    /// (e.g. repeat-one) doesn't flood the list with consecutive copies, and
    /// trims to `sessionPlayHistoryLimit`. Called from the status-poll
    /// track-change hook with the *outgoing* track.
    func recordSessionPlay(_ track: Track) {
        if sessionPlayHistory.first?.id == track.id { return }
        sessionPlayHistory.insert(track, at: 0)
        if sessionPlayHistory.count > sessionPlayHistoryLimit {
            sessionPlayHistory.removeLast(sessionPlayHistory.count - sessionPlayHistoryLimit)
        }
    }

    /// Toggle behaviour for the full-page Play Queue view (⌘U, #81): first
    /// press pushes the queue page onto the drill stack, second press pops
    /// it. Mirrors `LyrebirdApp.toggleNowPlaying` so either gesture (menu or
    /// shortcut) behaves the same. Kept here so the ⌘U command and any future
    /// in-app entry point (PlayerBar button) share one code path.
    func toggleFullQueue() {
        if isShowingFullQueue {
            navPath.removeLast()
        } else {
            navPath.append(Route.fullQueue)
        }
    }

    /// Reorder the user-added "Up Next" list. Uses the same `IndexSet` → Int
    /// contract as SwiftUI `List.onMove`, so the inspector can wire this up
    /// directly. See #80.
    ///
    /// Reorders the in-app overlay, then rebuilds and pushes the flat queue to
    /// `core.setQueue` via `syncCoreQueueAfterReorder()` so the engine's view
    /// of "what plays next" matches the inspector (#565).
    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextUserAdded.move(fromOffsets: source, toOffset: destination)
        syncCoreQueueAfterReorder()
    }

    /// Rebuild the flat core queue from the current inspector state and push
    /// it down to `core.setQueue` so the engine's "what plays next" matches
    /// the inspector's Up Next order (#565). Layout: current track at index 0,
    /// then the (possibly reordered / shuffled / pruned) user-added overlay,
    /// then the auto-queue tail. `startIndex: 0` keeps the current track
    /// playing while honouring the new order for everything that follows.
    ///
    /// Shared by `moveUpNext`, `shuffleUpNext`, and `removeFromUpNext` so all
    /// three actually re-sequence playback rather than only mutating the Swift
    /// overlay. Errors surface on `errorMessage` (auth failures route through
    /// `handleAuthError`) instead of being swallowed by `try?`, so a failed
    /// sync is visible rather than silently leaving the engine on the old
    /// order.
    private func syncCoreQueueAfterReorder() {
        var allTracks: [Track] = []
        if let current = status.currentTrack { allTracks.append(current) }
        allTracks.append(contentsOf: upNextUserAdded.map(\.track))
        allTracks.append(contentsOf: upNextAutoQueue.map(\.track))
        guard !allTracks.isEmpty else { return }
        do {
            _ = try core.setQueue(tracks: allTracks, startIndex: 0)
        } catch {
            if handleAuthError(error) { return }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .playback)
        }
    }

    /// Remove one entry from the user-added "Up Next" list by its stable
    /// per-item `queueId`. Uses `queueId` rather than `track.id` so users
    /// can queue the same track twice and still remove a single instance.
    /// See #80.
    ///
    /// After pruning the overlay we rebuild and push the core queue so the
    /// removed track actually drops out of playback — previously this mutated
    /// only the Swift overlay and the engine still played the removed track.
    func removeFromUpNext(id: UUID) {
        upNextUserAdded.removeAll { $0.id == id }
        syncCoreQueueAfterReorder()
    }

    // MARK: - Queue actions (BATCH-07b, #284)

    /// Empty both the user-added "Up Next" overlay and the auto-queue tail.
    /// The Queue Inspector's Clear action lands here behind a confirmation
    /// dialog so an accidental click can't wipe a long queue. Does not
    /// touch the currently-playing track — only what comes after. See #284.
    ///
    /// After clearing the Swift overlays we truncate the engine queue via
    /// `core.clearQueue()`, which drops every entry except the currently
    /// playing track (leaving it as a single-item queue). The current track
    /// keeps playing while everything queued after it stops auto-advancing,
    /// matching the confirmation dialog's promise. Mirrors the command
    /// palette's "Clear Queue" verb (#282).
    func clearQueue() {
        upNextUserAdded.removeAll()
        upNextAutoQueue.removeAll()
        // #282: truncate the engine queue to the currently playing track so
        // playback continues but nothing auto-advances after it. Re-read
        // status so the inspector reflects the now single-item queue.
        core.clearQueue()
        status = core.status()
    }

    /// Serialize the current queue (currently-playing + user-added + auto
    /// tail) into a freshly-created playlist on the server. Called from
    /// the Queue Inspector's Save action (#284) after the user picks a
    /// name.
    ///
    /// Implementation: `core.create_playlist(name:, itemIds:)` accepts an
    /// initial `itemIds` payload, so we try it in a single FFI hop and
    /// then chase with `add_to_playlist` to cover older Jellyfin builds
    /// that rewrite `ItemIds` to empty on create. After a successful save,
    /// the local `playlists` cache picks up the new entry on next library
    /// refresh — we don't eagerly fetch it here to keep the action snappy.
    ///
    /// Errors surface on `errorMessage` so the caller sheet can stay
    /// presentation-only. Empty queues short-circuit — creating an empty
    /// playlist from the queue inspector would be nonsensical.
    func saveQueueAsPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Build the track id list in the order the user sees: current →
        // user-added → auto tail. `Set` de-duplicates in case the same
        // track appears twice (e.g. queued and also present in the auto
        // tail); first-seen order is preserved for clarity.
        var seen = Set<String>()
        var ids: [String] = []
        if let current = status.currentTrack {
            if seen.insert(current.id).inserted { ids.append(current.id) }
        }
        for entry in upNextUserAdded {
            if seen.insert(entry.track.id).inserted { ids.append(entry.track.id) }
        }
        for entry in upNextAutoQueue {
            if seen.insert(entry.track.id).inserted { ids.append(entry.track.id) }
        }
        guard !ids.isEmpty else { return }
        do {
            let newId = try await Task.detached(priority: .userInitiated) { [core] in
                try core.createPlaylist(name: trimmed, itemIds: ids)
            }.value
            // Some older Jellyfin builds ignore the initial `ItemIds` on
            // `create_playlist` and return an empty playlist. Follow up
            // with `add_to_playlist` as a best-effort top-up so the saved
            // queue always lands with its tracks, regardless of server
            // version. `add_to_playlist` on a server that did honor the
            // initial ids would duplicate entries — we accept that
            // tradeoff over silently dropping the saved queue on older
            // servers.
            if !newId.isEmpty {
                _ = await addToPlaylist(trackIds: ids, playlistId: newId)
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Save queue failed: \(error.localizedDescription)"
        }
    }

    /// Shuffle the user-added "Up Next" list in place. The Queue
    /// Inspector's Shuffle action lands here (#284). The currently-playing
    /// track is not part of `upNextUserAdded` — it lives on
    /// `status.currentTrack` and is unaffected by this call.
    ///
    /// A short-list guard keeps the UI honest: shuffling one item (or
    /// none) is a no-op, so we don't waste a pass.
    func shuffleUpNext() {
        guard upNextUserAdded.count > 1 else { return }
        upNextUserAdded.shuffle()
        // Push the shuffled order down so the engine plays in the new order
        // rather than its original load order — same rebuild contract as
        // `moveUpNext`.
        syncCoreQueueAfterReorder()
    }

    /// Jump playback to a specific queue entry (the Queue Inspector's
    /// double-click on an Up Next / "Playing From" row). Rebuilds the flat
    /// track list the inspector shows — current track, then the user-added
    /// overlay, then the auto-queue tail — locates `entry` by its stable
    /// per-instance `queueId`, and replays the whole list starting at that
    /// index via `play(tracks:startIndex:)`. Routing through `play(...)`
    /// means the core queue is re-seated and the engine auto-advances from
    /// the jumped track onward, exactly like picking a track from a track
    /// list. Matching by `queueId` (not `track.id`) means double-clicking the
    /// second of two identical tracks jumps to that instance, not the first.
    ///
    /// No-ops if the entry isn't found in the current queue (e.g. it was
    /// removed between render and tap).
    func jumpToQueueEntry(_ entry: Queue) {
        guard let plan = queueJumpPlan(for: entry.id) else { return }
        play(tracks: plan.tracks, startIndex: plan.startIndex)
    }

    /// Pure helper for `jumpToQueueEntry`: flattens the inspector's three
    /// sections into the play order (current track, then user-added overlay,
    /// then auto-queue tail) and resolves `queueId` to a `(tracks,
    /// startIndex)` pair for `play(tracks:startIndex:)`. Factored out so the
    /// index arithmetic — which has to account for the current track
    /// occupying slot 0 — is unit-testable without the playback FFI. Returns
    /// `nil` when the id isn't present in any section.
    func queueJumpPlan(for queueId: UUID) -> (tracks: [Track], startIndex: Int)? {
        var entries: [Queue] = []
        if let current = status.currentTrack { entries.append(Queue(track: current)) }
        entries.append(contentsOf: upNextUserAdded)
        entries.append(contentsOf: upNextAutoQueue)
        guard let index = entries.firstIndex(where: { $0.id == queueId }) else { return nil }
        return (entries.map(\.track), index)
    }

    /// Navigate to the source that started the current auto queue. Wired
    /// from the PlayerBar's "Playing from {source}" label (#82). No-ops
    /// when `currentContext` has no navigable id (ad-hoc selections, radio
    /// seeds) or an unsupported `sourceType`.
    func goToPlayingFromSource() {
        guard let context = currentContext, let id = context.id, !id.isEmpty else { return }
        switch context.sourceType {
        case .playlist:
            if let playlist = playlists.first(where: { $0.id == id }) {
                goToPlaylist(playlist)
            } else {
                navPath.append(Route.playlist(id))
            }
        case .album:
            navPath.append(Route.album(id))
        case .artist:
            navPath.append(Route.artist(id))
        case .genre, .search, .radio, .other:
            // No dedicated surface for these source types yet — do nothing
            // rather than route to a placeholder. The label itself is
            // rendered non-clickable when this branch would be hit.
            break
        }
    }

    /// Whether the current playback source has a navigable target. Drives
    /// the clickable / non-clickable styling on the PlayerBar's "Playing
    /// from" label (#82). Genre / search / radio / other don't have a
    /// single detail surface today, so the label reads as plain text on
    /// those.
    var currentContextIsNavigable: Bool {
        guard let context = currentContext, let id = context.id, !id.isEmpty else { return false }
        switch context.sourceType {
        case .album, .artist, .playlist: return true
        case .genre, .search, .radio, .other: return false
        }
    }
}
