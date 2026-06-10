import Foundation
import os
@preconcurrency import LyrebirdCore

/// Cache-first library launch + background revalidation (#431).
///
/// The core persists every fetched library page into its SQLite cache
/// (`album_cache` / `artist_cache` / `track_cache`). On launch we emit those
/// cached rows to the UI immediately — `core.listCached*` is a pure local
/// read, no network — and then kick `core.revalidateLibrary`, which
/// delta-syncs against the server off the main actor and streams only the
/// rows that actually changed back through `LibrarySyncBridge`.
///
/// Extensions of a `@MainActor` type inherit its isolation, so everything in
/// this extension is main-actor-bound; the sync FFI hops run inside
/// `Task.detached` per the repo's gap-pattern-#2 rule.
extension AppModel {
    /// Populate `albums` / `artists` / `tracks` from the local cache when
    /// they're empty — the warm-launch fast path. Cached rows render in
    /// approximate display order (the core's article-stripped sort key);
    /// the regular network refresh running concurrently replaces them with
    /// authoritative pages, totals included. No-op on first launch (empty
    /// cache) and mid-session (arrays already populated).
    func loadCachedLibraryIfEmpty() async {
        guard albums.isEmpty, artists.isEmpty, tracks.isEmpty else { return }
        let pageSize = libraryInitialPageSize
        let cached = await Task.detached(priority: .userInitiated) { [core] () -> ([Album], [Artist], [Track]) in
            // Each read is independent + best-effort: a corrupt table must
            // not block the others (and never the launch).
            let albums = (try? core.listCachedAlbums(limit: pageSize)) ?? []
            let artists = (try? core.listCachedArtists(limit: pageSize)) ?? []
            let tracks = (try? core.listCachedTracks(limit: pageSize)) ?? []
            return (albums, artists, tracks)
        }.value
        // Re-check after the suspension: a fast network refresh (or a second
        // caller) may have populated the arrays while the cache read ran —
        // fresh server data must never be clobbered by cached rows.
        guard albums.isEmpty, artists.isEmpty, tracks.isEmpty else { return }
        if !cached.0.isEmpty { albums = cached.0 }
        if !cached.1.isEmpty { artists = cached.1 }
        if !cached.2.isEmpty { tracks = cached.2 }
        if !cached.0.isEmpty || !cached.1.isEmpty || !cached.2.isEmpty {
            Log.app.info("library cache-first paint: \(cached.0.count) albums, \(cached.1.count) artists, \(cached.2.count) tracks")
        }
    }

    /// Kick the core's background library revalidation. Returns immediately;
    /// changed/removed rows arrive via `LibrarySyncBridge` on the main actor.
    /// The core no-ops (returns `false`) when a sync is already in flight or
    /// no session exists, so calling this from every `refreshLibrary` is safe.
    func startLibraryRevalidation() {
        let bridge = LibrarySyncBridge(model: self)
        Task.detached(priority: .utility) { [core] in
            _ = core.revalidateLibrary(observer: bridge)
        }
    }

    /// Apply a batch of album changes from the background sync: refresh rows
    /// the UI has loaded (matched by id) and drop server-side deletions.
    /// Rows beyond the loaded pagination window are intentionally ignored —
    /// they're already in the cache for the next launch, and load-more pages
    /// fetch fresh from the server anyway.
    func applyLibrarySync(albumsChanged changed: [Album], removedIds: [String]) {
        guard session != nil else { return }
        if !changed.isEmpty {
            let byId = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for index in albums.indices {
                if let fresh = byId[albums[index].id] { albums[index] = fresh }
            }
        }
        if !removedIds.isEmpty {
            let gone = Set(removedIds)
            albums.removeAll { gone.contains($0.id) }
        }
    }

    /// Artist twin of `applyLibrarySync(albumsChanged:removedIds:)`.
    func applyLibrarySync(artistsChanged changed: [Artist], removedIds: [String]) {
        guard session != nil else { return }
        if !changed.isEmpty {
            let byId = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for index in artists.indices {
                if let fresh = byId[artists[index].id] { artists[index] = fresh }
            }
        }
        if !removedIds.isEmpty {
            let gone = Set(removedIds)
            artists.removeAll { gone.contains($0.id) }
        }
    }

    /// Track twin of `applyLibrarySync(albumsChanged:removedIds:)` — tracks
    /// have no removal reconciliation in the core (see #431), so only
    /// changed rows arrive.
    func applyLibrarySync(tracksChanged changed: [Track]) {
        guard session != nil, !changed.isEmpty else { return }
        let byId = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for index in tracks.indices {
            if let fresh = byId[tracks[index].id] { tracks[index] = fresh }
        }
    }

    /// End-of-sync bookkeeping: adopt the server-authoritative totals so the
    /// "N of M" sublines and load-more triggers reflect reality even when
    /// the cached emit ran before any network page. Totals of 0 mean that
    /// phase failed — keep whatever the regular fetch path reported.
    func libraryRevalidationDidComplete(_ summary: LibrarySyncSummary) {
        guard session != nil else { return }
        if summary.albumTotal > 0 { albumsTotal = summary.albumTotal }
        if summary.artistTotal > 0 { artistsTotal = summary.artistTotal }
        if summary.trackTotal > 0 { tracksTotal = summary.trackTotal }
        Log.app.info(
            "library revalidation done: albums \(summary.albumsChanged) changed / \(summary.albumsRemoved) removed of \(summary.albumTotal); artists \(summary.artistsChanged)/\(summary.artistsRemoved) of \(summary.artistTotal); tracks \(summary.tracksChanged) changed of \(summary.trackTotal)\(summary.didFullAlbumSync ? " [full album walk]" : "")\(summary.trackDeltaTruncated ? " [track delta truncated]" : "")"
        )
        if !summary.phaseErrors.isEmpty {
            Log.app.error("library revalidation partial failure: \(summary.phaseErrors.joined(separator: "; "), privacy: .public)")
        }
    }
}

/// UniFFI callback bridge for the core's library revalidation (#431).
///
/// The core invokes these methods on its tokio runtime threads; each one
/// marshals onto the main actor before touching `AppModel` (gap pattern #2,
/// inverted direction). Holds the model weakly — a sync outliving the model
/// (quit, logout teardown) just drops its updates.
///
/// `@unchecked Sendable`: the only state is a `weak` reference assigned once
/// in `init`; ARC weak loads are thread-safe, and all reads happen inside the
/// main-actor hop.
final class LibrarySyncBridge: LibrarySyncObserver, @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func albumsChanged(changed: [Album], removedIds: [String]) {
        let model = model
        Task { @MainActor in
            model?.applyLibrarySync(albumsChanged: changed, removedIds: removedIds)
        }
    }

    func artistsChanged(changed: [Artist], removedIds: [String]) {
        let model = model
        Task { @MainActor in
            model?.applyLibrarySync(artistsChanged: changed, removedIds: removedIds)
        }
    }

    func tracksChanged(changed: [Track]) {
        let model = model
        Task { @MainActor in
            model?.applyLibrarySync(tracksChanged: changed)
        }
    }

    func syncCompleted(summary: LibrarySyncSummary) {
        let model = model
        Task { @MainActor in
            model?.libraryRevalidationDidComplete(summary)
        }
    }

    func syncFailed(message: String) {
        // Best-effort background refresh: log, never banner. The foreground
        // fetch paths own user-visible error surfacing (incl. auth expiry).
        Log.app.error("library revalidation failed: \(message, privacy: .public)")
    }
}
