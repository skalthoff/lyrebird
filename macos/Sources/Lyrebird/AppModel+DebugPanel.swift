import CryptoKit
import Foundation
import OSLog
@preconcurrency import LyrebirdCore
import Nuke

/// Debug panel state on `AppModel`: the toggle flag, snapshot refresh, and the
/// structured in-memory snapshot that `DebugPanelView` displays.
///
/// The panel never reads FFI on the main actor per-frame (CLAUDE.md gap
/// pattern #2). Instead, `refreshDebugSnapshot()` fires once on open and again
/// on the manual Refresh button. A modest 5 s timer keeps the snapshot live
/// while the window is open; the timer is cancelled when the window closes.
/// All blocking work (log store, disk-cache stats) runs in a detached Task.
extension AppModel {

    // MARK: - Scene identity

    /// Window scene id for the debug panel. Must match `LyrebirdApp`'s
    /// `Window(id:)` declaration and the `openWindow(id:)` call site.
    static let debugPanelWindowID = "debug-panel"

    // MARK: - Panel toggle

    /// Toggle the debug panel. Wired to the ⌘⇧D menu command; flipping the
    /// flag is enough — `RootView` translates the change into the matching
    /// `openWindow` / `dismissWindow` call. The stored properties
    /// (`isDebugPanelOpen`, `debugSnapshot`, `isRefreshingDebugSnapshot`) live
    /// in the main `AppModel` class declaration, not here, because Swift
    /// extensions cannot add stored properties.
    func toggleDebugPanel() {
        isDebugPanelOpen.toggle()
    }

    // MARK: - Snapshot

    /// Populate `debugSnapshot` from the current live state. The session / cache
    /// sections are snapshotted synchronously from main-actor-visible state; the
    /// disk-cache sizes and log tail are collected in a detached task to avoid
    /// blocking the main thread. Idempotent: calling it again overwrites the
    /// previous snapshot (guard against double-fire via `isRefreshingDebugSnapshot`).
    func refreshDebugSnapshot() {
        guard !isRefreshingDebugSnapshot else { return }
        isRefreshingDebugSnapshot = true

        // --- Snapshot the main-actor state first (no blocking I/O) ---

        // Session section
        let sessionSection: DebugSnapshot.SessionSection
        if let sess = session {
            sessionSection = DebugSnapshot.SessionSection(
                serverURL: serverURL,
                userId: DebugSnapshot.hashUserId(sess.user.id),
                username: sess.user.name,
                deviceId: sess.deviceId
            )
        } else {
            sessionSection = DebugSnapshot.SessionSection(
                serverURL: serverURL.isEmpty ? "(not signed in)" : serverURL,
                userId: nil,
                username: nil,
                deviceId: nil
            )
        }

        // Player section — AVPlayer state via AudioEngine + core status snapshot.
        let st = status
        let playerSection = DebugSnapshot.PlayerSection(
            playbackState: String(describing: st.state),
            positionSeconds: st.positionSeconds,
            volume: st.volume,
            dspPipelineEnabled: audio.dspPipelineEnabled,
            offlinePlaybackEnabled: audio.offlinePlaybackEnabled,
            normalizationMode: String(describing: audio.normalizationMode),
            preGainDb: audio.normalizationPreGainDb
        )

        // Queue section — counts only; no track names in the panel output.
        let queueSection = DebugSnapshot.QueueSection(
            userAddedCount: upNextUserAdded.count,
            autoQueueCount: upNextAutoQueue.count,
            currentContextLabel: currentContext.map { "\($0.sourceType.rawValue): \($0.name)" },
            totalQueueLength: upNextUserAdded.count + upNextAutoQueue.count
        )

        // Cache section — library page counts (sync); disk/memory sizes from task.
        let cacheSection = DebugSnapshot.CacheSection(
            albumsLoaded: albums.count,
            albumsTotal: Int(albumsTotal),
            artistsLoaded: artists.count,
            artistsTotal: Int(artistsTotal),
            tracksLoaded: tracks.count,
            tracksTotal: Int(tracksTotal),
            playlistsLoaded: playlists.count,
            playlistsTotal: Int(playlistsTotal),
            nukeDiskCacheSizeLabel: nil,
            nukeMemoryCacheSizeLabel: nil,
            sqliteDbSizeLabel: nil
        )

        // Feature-flags section (Capabilities + UserDefaults flag).
        let flagsSection = DebugSnapshot.FlagsSection(
            supportsDownloads: supportsDownloads,
            supportsMarkPlayed: supportsMarkPlayed,
            supportsArtistPlayShuffle: supportsArtistPlayShuffle,
            supportsTrackInfo: supportsTrackInfo,
            supportsGenreActions: supportsGenreActions,
            supportsStreamingBitrate: supportsStreamingBitrate,
            supportsStreamQualitySelection: supportsStreamQualitySelection,
            supportsCrossfade: supportsCrossfade,
            supportsPlaylistSearch: supportsPlaylistSearch,
            supportsLanguageSelection: supportsLanguageSelection,
            supportsThemeSelection: supportsThemeSelection,
            supportsEngineDSP: supportsEngineDSP,
            engineDSPDefaultsKey: AppModel.engineDSPDefaultsKey
        )

        let networkSection = DebugSnapshot.NetworkSection(
            isOnline: network.isOnline,
            qualityHint: String(describing: network.qualityHint)
        )

        var partial = DebugSnapshot()
        partial.capturedAt = Date()
        partial.session = sessionSection
        partial.player = playerSection
        partial.queue = queueSection
        partial.cache = cacheSection
        partial.flags = flagsSection
        partial.network = networkSection

        // Capture Nuke pipeline references on the main actor before hopping off.
        // `Artwork.pipeline` is main-actor-isolated; capturing here satisfies
        // the concurrency checker (same pattern as `PreferencesLibrary.refreshCacheSize`).
        let dataCache = Artwork.pipeline.configuration.dataCache as? DataCache
        let imageCache = Artwork.pipeline.configuration.imageCache as? ImageCache

        // --- Collect IO-bound stats off the main thread ---
        Task {
            // Nuke disk cache size (DataCache.totalSize enumerates files on disk;
            // Nuke documents: "avoid using from the main thread").
            let diskLabel = await Task.detached(priority: .utility) { [dataCache] in
                guard let dc = dataCache else { return "—" }
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useKB, .useMB, .useGB]
                fmt.countStyle = .file
                return fmt.string(fromByteCount: Int64(dc.totalSize))
            }.value

            // Nuke memory cache size (NSCache totalCost is cheap — sync).
            let memLabel: String = {
                let cost = imageCache?.totalCost ?? 0
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useKB, .useMB]
                fmt.countStyle = .memory
                return fmt.string(fromByteCount: Int64(cost))
            }()

            // SQLite DB size (main file + WAL + SHM).
            let dbLabel = await Task.detached(priority: .utility) {
                guard let dir = CoreDataLocation.defaultDataDirectory else { return "—" }
                let files = ["lyrebird.db", "lyrebird.db-wal", "lyrebird.db-shm"]
                var total: Int64 = 0
                for name in files {
                    let url = dir.appendingPathComponent(name)
                    if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(sz)
                    }
                }
                guard total > 0 else { return "—" }
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useKB, .useMB, .useGB]
                fmt.countStyle = .file
                return fmt.string(fromByteCount: total)
            }.value

            // Log tail — last 100 entries from the process-scoped store.
            let logLines = await Task.detached(priority: .utility) {
                (try? DebugSnapshot.fetchRecentLogLines(limit: 100)) ?? ["(could not read the unified log)"]
            }.value

            // Marshal all IO results back to the main actor.
            await MainActor.run {
                partial.cache.nukeDiskCacheSizeLabel = diskLabel
                partial.cache.nukeMemoryCacheSizeLabel = memLabel
                partial.cache.sqliteDbSizeLabel = dbLabel
                partial.logs = DebugSnapshot.LogsSection(lines: logLines)
                self.debugSnapshot = partial
                self.isRefreshingDebugSnapshot = false
            }
        }
    }
}

// MARK: - DebugSnapshot

/// Value-type snapshot of app state captured at a point in time. Held in
/// `AppModel.debugSnapshot` and displayed read-only by `DebugPanelView`.
/// Completely inert — no FFI, no timers. Refreshed by `AppModel.refreshDebugSnapshot`.
struct DebugSnapshot {

    var capturedAt: Date = Date(timeIntervalSince1970: 0)
    var session: SessionSection = SessionSection()
    var player: PlayerSection = PlayerSection()
    var queue: QueueSection = QueueSection()
    var cache: CacheSection = CacheSection()
    var flags: FlagsSection = FlagsSection()
    var network: NetworkSection = NetworkSection()
    var logs: LogsSection = LogsSection()

    // MARK: - Section types

    struct SessionSection {
        /// Server base URL (not redacted — the user knows their own server).
        var serverURL: String = ""
        /// First 4 bytes of SHA-256(userId) rendered as 8 hex chars.
        /// Sufficient to identify the user in a bug report without exposing the raw id.
        var userId: String?
        var username: String?
        var deviceId: String?
    }

    struct PlayerSection {
        var playbackState: String = "—"
        var positionSeconds: Double = 0
        var volume: Float = 0
        var dspPipelineEnabled: Bool = false
        var offlinePlaybackEnabled: Bool = false
        var normalizationMode: String = "—"
        var preGainDb: Double = 0
    }

    struct QueueSection {
        var userAddedCount: Int = 0
        var autoQueueCount: Int = 0
        var currentContextLabel: String?
        var totalQueueLength: Int = 0
    }

    struct CacheSection {
        var albumsLoaded: Int = 0
        var albumsTotal: Int = 0
        var artistsLoaded: Int = 0
        var artistsTotal: Int = 0
        var tracksLoaded: Int = 0
        var tracksTotal: Int = 0
        var playlistsLoaded: Int = 0
        var playlistsTotal: Int = 0
        /// Nuke on-disk artwork cache footprint (populated by detached task).
        var nukeDiskCacheSizeLabel: String?
        /// Nuke in-memory image cache footprint.
        var nukeMemoryCacheSizeLabel: String?
        /// SQLite DB size (main + WAL + SHM).
        var sqliteDbSizeLabel: String?
    }

    struct FlagsSection {
        var supportsDownloads: Bool = false
        var supportsMarkPlayed: Bool = false
        var supportsArtistPlayShuffle: Bool = false
        var supportsTrackInfo: Bool = false
        var supportsGenreActions: Bool = false
        var supportsStreamingBitrate: Bool = false
        var supportsStreamQualitySelection: Bool = false
        var supportsCrossfade: Bool = false
        var supportsPlaylistSearch: Bool = false
        var supportsLanguageSelection: Bool = false
        var supportsThemeSelection: Bool = false
        var supportsEngineDSP: Bool = false
        var engineDSPDefaultsKey: String = ""
    }

    struct NetworkSection {
        var isOnline: Bool = true
        var qualityHint: String = "unmetered"
    }

    struct LogsSection {
        var lines: [String] = []
    }

    // MARK: - Helpers

    /// Return the first 4 bytes of SHA-256(userId) as a lowercase hex string
    /// (8 chars). Enough for identification in a bug report without exposing the raw id.
    static func hashUserId(_ userId: String) -> String {
        let digest = SHA256.hash(data: Data(userId.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Read the most recent `limit` log entries from the process-scoped store
    /// for `Log.subsystem`. Must be called off the main thread.
    static func fetchRecentLogLines(limit: Int) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date().addingTimeInterval(-3600))
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        let entries = try store.getEntries(at: since, matching: predicate)
        let all: [String] = entries.compactMap { entry -> String? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return DiagnosticBundle.formatLogLine(
                date: entry.date,
                category: log.category,
                message: entry.composedMessage
            )
        }
        return all.count <= limit ? all : Array(all.suffix(limit))
    }

    // MARK: - Diagnostic bundle JSON

    /// Serialize the snapshot as pretty-printed JSON for the "Copy diagnostic bundle"
    /// clipboard action. No raw access tokens, track names, or other secrets.
    func jsonString() -> String {
        var dict: [String: Any] = [:]
        dict["capturedAt"] = DiagnosticBundle.iso8601(capturedAt)
        dict["appVersion"] = {
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            return "\(v) (\(b))"
        }()
        dict["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString

        dict["session"] = [
            "serverURL": session.serverURL,
            "userId": session.userId ?? "(not signed in)",
            "username": session.username ?? "(not signed in)",
            "deviceId": session.deviceId ?? "(not signed in)",
        ] as [String: Any]

        dict["player"] = [
            "state": player.playbackState,
            "positionSeconds": player.positionSeconds,
            "volume": player.volume,
            "dspPipelineEnabled": player.dspPipelineEnabled,
            "offlinePlaybackEnabled": player.offlinePlaybackEnabled,
            "normalizationMode": player.normalizationMode,
            "preGainDb": player.preGainDb,
        ] as [String: Any]

        dict["queue"] = [
            "userAddedCount": queue.userAddedCount,
            "autoQueueCount": queue.autoQueueCount,
            "currentContext": queue.currentContextLabel ?? "(none)",
            "totalQueueLength": queue.totalQueueLength,
        ] as [String: Any]

        dict["cache"] = [
            "albums": "\(cache.albumsLoaded)/\(cache.albumsTotal)",
            "artists": "\(cache.artistsLoaded)/\(cache.artistsTotal)",
            "tracks": "\(cache.tracksLoaded)/\(cache.tracksTotal)",
            "playlists": "\(cache.playlistsLoaded)/\(cache.playlistsTotal)",
            "nukeDiskCache": cache.nukeDiskCacheSizeLabel ?? "—",
            "nukeMemoryCache": cache.nukeMemoryCacheSizeLabel ?? "—",
            "sqliteDb": cache.sqliteDbSizeLabel ?? "—",
        ] as [String: Any]

        dict["flags"] = [
            "supportsDownloads": flags.supportsDownloads,
            "supportsMarkPlayed": flags.supportsMarkPlayed,
            "supportsArtistPlayShuffle": flags.supportsArtistPlayShuffle,
            "supportsTrackInfo": flags.supportsTrackInfo,
            "supportsGenreActions": flags.supportsGenreActions,
            "supportsStreamingBitrate": flags.supportsStreamingBitrate,
            "supportsStreamQualitySelection": flags.supportsStreamQualitySelection,
            "supportsCrossfade": flags.supportsCrossfade,
            "supportsPlaylistSearch": flags.supportsPlaylistSearch,
            "supportsLanguageSelection": flags.supportsLanguageSelection,
            "supportsThemeSelection": flags.supportsThemeSelection,
            "supportsEngineDSP": flags.supportsEngineDSP,
        ] as [String: Any]

        dict["network"] = ["isOnline": network.isOnline, "qualityHint": network.qualityHint] as [String: Any]
        dict["logs"] = logs.lines

        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"serialization failed\"}" }
        return json
    }
}
