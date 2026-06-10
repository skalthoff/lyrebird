import Foundation
import os
@preconcurrency import LyrebirdCore

private let shutdownLog = Logger(subsystem: "org.lyrebird.desktop", category: "shutdown")

// MARK: - Persisted queue snapshot

/// Lightweight `Codable` mirror of `Track` that round-trips through
/// `UserDefaults` JSON without relying on the generated FFI type having
/// `Codable` synthesis.
///
/// Only the fields needed to restore queue identity and display metadata are
/// persisted. Playback uses the Jellyfin item `id`; the name, artist, and
/// album fields let the Queue Inspector render meaningful rows before the
/// library page has been re-fetched on the new launch.
struct PersistedTrack: Codable, Equatable {
    var id: String
    var name: String
    var albumId: String?
    var albumName: String?
    var artistName: String
    var artistId: String?
    var indexNumber: UInt32?
    var discNumber: UInt32?
    var year: Int32?
    var runtimeTicks: UInt64
    var imageTag: String?
    var container: String?

    init(from track: Track) {
        id = track.id
        name = track.name
        albumId = track.albumId
        albumName = track.albumName
        artistName = track.artistName
        artistId = track.artistId
        indexNumber = track.indexNumber
        discNumber = track.discNumber
        year = track.year
        runtimeTicks = track.runtimeTicks
        imageTag = track.imageTag
        container = track.container
    }

    /// Reconstruct a `Track` from the persisted mirror. Fields that are not
    /// stored (favorite, play count, user data, playlist item id, bitrate) are
    /// left at their zero values — they are refreshed by subsequent library
    /// loads and do not affect whether the track can be played.
    func toTrack() -> Track {
        Track(
            id: id,
            name: name,
            albumId: albumId,
            albumName: albumName,
            artistName: artistName,
            artistId: artistId,
            indexNumber: indexNumber,
            discNumber: discNumber,
            year: year,
            runtimeTicks: runtimeTicks,
            isFavorite: false,
            playCount: 0,
            container: container,
            bitrate: nil,
            imageTag: imageTag,
            playlistItemId: nil,
            userData: nil
        )
    }
}

/// The full queue state snapshotted at shutdown and restored on the next
/// launch. Persisted as JSON under `AppModel.queueSnapshotKey` in
/// `UserDefaults`.
///
/// Layout mirrors the Queue Inspector's three sections:
///   1. `currentTrack` — the track that was playing or paused.
///   2. `userAdded`    — the "Up Next" user-added overlay, in order.
///   3. `autoQueue`    — the auto-queue tail (album / playlist remainder).
///
/// The context fields allow the inspector's "PLAYING FROM" header to be
/// reconstructed from the persisted source without a server round-trip.
struct QueueSnapshot: Codable, Equatable {
    /// The track that was playing (or paused) when the app quit.
    var currentTrack: PersistedTrack?
    /// Playback position in seconds within the current track.
    var positionSeconds: Double
    /// User-added "Up Next" overlay, in queue order.
    var userAdded: [PersistedTrack]
    /// Auto-queue tail (album / playlist remainder), in queue order.
    var autoQueue: [PersistedTrack]
    /// Display label for the source that populated the auto-queue, if known.
    var contextName: String?
    /// Jellyfin item id for the source, if known.
    var contextId: String?
    /// Raw `ContextSourceType` value, used to reconstruct the enum on restore.
    var contextSourceType: String?
}

// MARK: - AppModel shutdown + restore

extension AppModel {

    // MARK: UserDefaults keys

    /// JSON-encoded `QueueSnapshot` from the most recent clean quit.
    static let queueSnapshotKey = "queue.shutdown_snapshot"

    /// Boolean flag: `true` when a snapshot was successfully written in
    /// `persistQueueSnapshot()`. On `kill -9` this flag is never set, but any
    /// JSON left from a prior clean quit is still valid and safe to restore —
    /// SQLite WAL recovery handles the DB side independently.
    static let queueSnapshotReadyKey = "queue.shutdown_snapshot_ready"

    // MARK: Pure decision helpers (testable without side-effects)

    /// Whether the current state warrants snapshotting. Returns `false` when
    /// idle (nothing playing or queued) so an empty snapshot is never written.
    ///
    /// Pure function — reads the arguments, not live model state, so tests can
    /// cover every branch without a running audio session.
    static func shouldPersistSnapshot(
        currentTrack: Track?,
        userAddedCount: Int,
        autoQueueCount: Int
    ) -> Bool {
        currentTrack != nil || userAddedCount > 0 || autoQueueCount > 0
    }

    /// Ordered sequence of work items in a graceful shutdown.
    ///
    /// Returned as a value enum so tests can assert ordering (playback stop
    /// before queue persist) without observing side-effects.
    enum ShutdownStep: Equatable {
        /// Stop the AVPlayer / DSP pipeline and emit the final
        /// `POST /Sessions/Playing/Stopped` report so the server's resume
        /// position is correct.
        case stopPlayback
        /// Encode and write the current queue + position to `UserDefaults`.
        case persistQueue
    }

    /// Returns the canonical shutdown sequence for the given state.
    ///
    /// Stopping playback comes first so `positionSeconds` still reflects the
    /// last known playback position when the queue is snapshotted; after the
    /// player drains it would read 0.
    static func shutdownSteps(isPlayingOrPaused: Bool, hasQueue: Bool) -> [ShutdownStep] {
        var steps: [ShutdownStep] = []
        if isPlayingOrPaused { steps.append(.stopPlayback) }
        if hasQueue { steps.append(.persistQueue) }
        return steps
    }

    // MARK: Persist

    /// Snapshot the current queue and position to `UserDefaults` and mark it
    /// ready for restore on the next launch.
    ///
    /// Called synchronously on the main actor inside `applicationShouldTerminate`
    /// after `audio.stop()` has been called. `UserDefaults.standard.set` is
    /// synchronous; the OS writes it to disk on its normal plist schedule, which
    /// is reliable for a clean quit. A `kill -9` may skip the write — that is
    /// acceptable: WAL recovery handles any in-flight DB writes, and the user
    /// simply starts fresh.
    @MainActor
    func persistQueueSnapshot() {
        let currentTrack = status.currentTrack
        let positionSeconds = status.positionSeconds
        let userAdded = upNextUserAdded.map { PersistedTrack(from: $0.track) }
        let autoQueue = upNextAutoQueue.map { PersistedTrack(from: $0.track) }

        guard AppModel.shouldPersistSnapshot(
            currentTrack: currentTrack,
            userAddedCount: userAdded.count,
            autoQueueCount: autoQueue.count
        ) else {
            // Nothing to restore — clear any stale snapshot so the next launch
            // does not offer a resume from an older session.
            UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotKey)
            UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotReadyKey)
            shutdownLog.info("graceful-shutdown: idle — queue snapshot cleared")
            return
        }

        let snapshot = QueueSnapshot(
            currentTrack: currentTrack.map(PersistedTrack.init(from:)),
            positionSeconds: positionSeconds,
            userAdded: userAdded,
            autoQueue: autoQueue,
            contextName: currentContext?.name,
            contextId: currentContext?.id,
            contextSourceType: currentContext?.sourceType.rawValue
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            let json = String(data: data, encoding: .utf8) ?? ""
            UserDefaults.standard.set(json, forKey: AppModel.queueSnapshotKey)
            UserDefaults.standard.set(true, forKey: AppModel.queueSnapshotReadyKey)
            shutdownLog.info(
                "graceful-shutdown: persisted — track=\(currentTrack?.name ?? "nil", privacy: .public) pos=\(positionSeconds, privacy: .public)s userAdded=\(userAdded.count) autoQueue=\(autoQueue.count)"
            )
        } catch {
            shutdownLog.error(
                "graceful-shutdown: snapshot encode failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Restore

    /// Decode and return the persisted `QueueSnapshot` from `UserDefaults`, if
    /// one exists. Returns `nil` when there is no snapshot or it cannot be
    /// decoded (e.g. schema change).
    ///
    /// Does not consume the snapshot — call `applyQueueSnapshot(_:)` to
    /// hydrate the in-app state and clear the stored entry.
    static func loadQueueSnapshot() -> QueueSnapshot? {
        guard UserDefaults.standard.bool(forKey: AppModel.queueSnapshotReadyKey),
              let json = UserDefaults.standard.string(forKey: AppModel.queueSnapshotKey),
              let data = json.data(using: .utf8)
        else { return nil }

        do {
            return try JSONDecoder().decode(QueueSnapshot.self, from: data)
        } catch {
            // Malformed / stale snapshot — clear it so the next launch starts
            // fresh rather than repeatedly trying to decode a corrupt blob.
            UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotKey)
            UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotReadyKey)
            shutdownLog.error(
                "graceful-shutdown: snapshot decode failed (\(error.localizedDescription, privacy: .public)) — cleared"
            )
            return nil
        }
    }

    /// Hydrate the in-app queue overlays from a decoded snapshot and store it in
    /// `pendingResumeSnapshot` so the UI can present a "Resume where you left
    /// off?" toast.
    ///
    /// This method does **not** start playback. The user's explicit tap of the
    /// play button on the toast calls `resumeFromSnapshot()`.
    ///
    /// Clears the `UserDefaults` entry after reading so a subsequent cold launch
    /// (without the user pressing Play) does not re-offer a stale resume.
    @MainActor
    func applyQueueSnapshot(_ snapshot: QueueSnapshot) {
        upNextUserAdded = snapshot.userAdded.map { Queue(track: $0.toTrack()) }
        upNextAutoQueue = snapshot.autoQueue.map { Queue(track: $0.toTrack()) }

        if let name = snapshot.contextName,
           let rawType = snapshot.contextSourceType,
           let sourceType = ContextSourceType(rawValue: rawType) {
            currentContext = QueueContext(
                name: name,
                id: snapshot.contextId,
                sourceType: sourceType
            )
        }

        pendingResumeSnapshot = snapshot

        UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotKey)
        UserDefaults.standard.removeObject(forKey: AppModel.queueSnapshotReadyKey)

        shutdownLog.info(
            "graceful-shutdown: snapshot applied — track=\(snapshot.currentTrack?.name ?? "nil", privacy: .public) pos=\(snapshot.positionSeconds)"
        )
    }

    /// Dismiss the pending resume toast without starting playback.
    @MainActor
    func dismissResumeSnapshot() {
        pendingResumeSnapshot = nil
    }

    /// Resume playback from the pending snapshot: push the full queue to the
    /// core engine and play from the saved position. Called when the user taps
    /// the play button on the "Resume?" toast.
    @MainActor
    func resumeFromSnapshot() {
        guard let snapshot = pendingResumeSnapshot else { return }
        pendingResumeSnapshot = nil

        // Flatten to play order: current track first, then user-added, then tail.
        var allTracks: [Track] = []
        if let current = snapshot.currentTrack { allTracks.append(current.toTrack()) }
        allTracks.append(contentsOf: snapshot.userAdded.map { $0.toTrack() })
        allTracks.append(contentsOf: snapshot.autoQueue.map { $0.toTrack() })

        guard !allTracks.isEmpty else { return }

        play(tracks: allTracks, startIndex: 0)

        // Seek to the saved position once the player has loaded. A short delay
        // gives AVQueuePlayer time to reach .readyToPlay before the seek fires.
        // Positions ≤ 1 s are effectively "from the start" and not worth seeking.
        let savedPosition = snapshot.positionSeconds
        guard savedPosition > 1.0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.audio.seek(toSeconds: savedPosition)
        }
    }
}
