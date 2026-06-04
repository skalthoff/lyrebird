import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Offline downloads (#819) — the AppModel surface the UI talks to.
///
/// Design notes:
///
/// * **No synchronous FFI on a per-cell path.** Row views (`TrackRow`,
///   `DownloadsView`) read `downloadStateById` / `downloadStats`, which are
///   plain in-memory `@Observable` state. The Rust core is only touched
///   off-main: when the user enqueues / deletes a download, when one finishes,
///   or in `refreshDownloads()`. This honours CLAUDE.md runtime gap #2.
///
/// * **Fully gated.** Every public entry checks `supportsDownloads` (the
///   `Capabilities` flag). While that flag is `false` the maps stay empty,
///   `downloadState(forTrackId:)` returns `nil`, and offline playback is never
///   reached — the streaming path is byte-for-byte unchanged.
///
/// * **Optimistic + reconciled.** Enqueue stamps a `.queued` badge immediately,
///   then the off-main `core.downloadTrack` flips it to `.done` (or `.failed`,
///   surfaced via `errorMessage`). Delete is optimistic too, with the row
///   removed up front and restored only implicitly by the next refresh on
///   failure.
extension AppModel {
    /// The cached download state for a track id, or `nil` when the track has no
    /// download record. The single read the UI should use — never calls the
    /// core. Returns `nil` for everything while `supportsDownloads` is off.
    func downloadState(forTrackId id: String) -> DownloadState? {
        downloadStateById[id]
    }

    /// Convenience: is this track fully downloaded and playable offline?
    func isDownloaded(_ track: Track) -> Bool {
        downloadStateById[track.id] == .done
    }

    /// Convenience: is a download for this track currently queued / running?
    func isDownloading(_ track: Track) -> Bool {
        switch downloadStateById[track.id] {
        case .queued, .downloading: return true
        default: return downloadsInFlight.contains(track.id)
        }
    }

    /// Download a batch of tracks for offline playback. Idempotent per track:
    /// already-done or in-flight tracks are skipped. Each track is fetched on
    /// its own detached task so one failure (or a budget refusal) doesn't sink
    /// the rest of the batch — mirroring the favorite/played multi-select
    /// convention.
    ///
    /// No-op while `supportsDownloads` is false.
    func downloadTracks(_ tracks: [Track]) async {
        guard supportsDownloads else { return }
        for track in tracks {
            // Skip ones already done or in flight.
            if downloadStateById[track.id] == .done { continue }
            if downloadsInFlight.contains(track.id) { continue }

            // Optimistic queued badge + in-flight guard on the main actor.
            downloadsInFlight.insert(track.id)
            downloadStateById[track.id] = .queued

            do {
                let entry = try await Task.detached(priority: .utility) { [core] in
                    try core.downloadTrack(track: track)
                }.value
                // Reconcile from the authoritative entry the core returned.
                applyDownloadEntry(entry)
            } catch {
                if handleAuthError(error) {
                    downloadsInFlight.remove(track.id)
                    // Auth expired mid-batch: clear the optimistic `.queued`
                    // badge so the row doesn't show a permanent spinner with
                    // nothing in flight (markAuthExpired() doesn't touch the
                    // download maps). `.failed` mirrors the core, which marks
                    // the DB row failed on the same auth error.
                    downloadStateById[track.id] = .failed
                    continue
                }
                // Mark failed locally and surface the reason. We deliberately
                // keep a `.failed` badge (rather than clearing the row) so the
                // user can see the attempt and retry.
                downloadStateById[track.id] = .failed
                errorMessage = LyrebirdErrorPresenter.message(for: error, context: .download)
                Log.tracks.error("download failed track=\(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            downloadsInFlight.remove(track.id)
        }
        // Refresh aggregate stats once after the batch rather than per track:
        // the per-track `downloadStateById` updates already drive row badges,
        // and the stats aggregate (SQLite sum) only feeds the preferences pane,
        // so one read at the end avoids O(n) serialized FFI hops.
        await refreshDownloadStats()
    }

    /// Remove the offline copies of a batch of tracks: deletes the files + index
    /// rows in the core and clears the local snapshot. Optimistic — the badges
    /// clear immediately. No-op while `supportsDownloads` is false.
    func removeDownloads(_ tracks: [Track]) async {
        guard supportsDownloads else { return }
        let ids = tracks.map { $0.id }
        // Optimistic local clear.
        for id in ids {
            downloadStateById.removeValue(forKey: id)
            downloadsInFlight.remove(id)
        }
        downloads.removeAll { ids.contains($0.track.id) }

        do {
            try await Task.detached(priority: .utility) { [core] in
                for id in ids {
                    try core.deleteDownload(trackId: id)
                }
            }.value
        } catch {
            if handleAuthError(error) { return }
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .download)
            Log.tracks.error("delete download failed: \(error.localizedDescription, privacy: .public)")
            // Re-sync so the snapshot reflects whatever actually got deleted.
            await refreshDownloads()
            return
        }
        await refreshDownloadStats()
    }

    /// Remove a single track's offline copy. Thin wrapper over
    /// `removeDownloads` for call sites that have one track.
    func removeDownload(_ track: Track) async {
        await removeDownloads([track])
    }

    /// Rehydrate the full download snapshot from the core: the list, the
    /// per-track state map, and the aggregate stats. Called after login /
    /// session-restore and whenever the Downloads screen wants a fresh read.
    /// No-op while `supportsDownloads` is false.
    func refreshDownloads() async {
        guard supportsDownloads else { return }
        do {
            let list = try await Task.detached(priority: .utility) { [core] in
                try core.listDownloads()
            }.value
            downloads = list
            // Rebuild the per-track map from the authoritative list. Preserve
            // any in-flight `.queued` badges for tracks not yet in the list.
            var map: [String: DownloadState] = [:]
            for entry in list {
                map[entry.track.id] = entry.state
            }
            for id in downloadsInFlight where map[id] == nil {
                map[id] = .queued
            }
            downloadStateById = map
            await refreshDownloadStats()
        } catch {
            if handleAuthError(error) { return }
            Log.tracks.error("refreshDownloads failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Refresh just the aggregate stats (used / budget / count). Cheap; called
    /// after each completion and on demand by the preferences pane.
    func refreshDownloadStats() async {
        guard supportsDownloads else { return }
        let stats = try? await Task.detached(priority: .utility) { [core] in
            try core.downloadStats()
        }.value
        if let stats { downloadStats = stats }
    }

    /// Persist the storage budget (in gigabytes from the slider) to the core,
    /// then refresh stats so the usage readout reflects the new cap.
    func setDownloadBudget(gigabytes: Double) {
        guard supportsDownloads else { return }
        let bytes = UInt64(max(0, gigabytes) * 1_000_000_000)
        Task {
            do {
                try await Task.detached(priority: .utility) { [core] in
                    try core.setDownloadBudgetBytes(bytes: bytes)
                }.value
                await refreshDownloadStats()
            } catch {
                Log.tracks.error("setDownloadBudget failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The resolved on-disk directory offline audio lives in. Shown read-only in
    /// the Downloads pane. Safe to call on the main thread (one cheap settings
    /// read in the core).
    func downloadDirectoryPath() -> String {
        core.downloadDirPath()
    }

    // MARK: - Internal

    /// Fold a single authoritative `DownloadEntry` (from the core) into the
    /// local snapshot: update the per-track state and upsert it into the list.
    private func applyDownloadEntry(_ entry: DownloadEntry) {
        downloadStateById[entry.track.id] = entry.state
        if let idx = downloads.firstIndex(where: { $0.track.id == entry.track.id }) {
            downloads[idx] = entry
        } else {
            downloads.insert(entry, at: 0)
        }
    }
}
