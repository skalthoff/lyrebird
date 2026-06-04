import Foundation
import Observation

/// Local persistence for `SmartPlaylist`s (#77 / #238).
///
/// Smart playlists are a client-only feature, so they're stored as a single
/// JSON document in Application Support rather than on the server. The store
/// is split into two halves:
///
/// - **`SmartPlaylistCodec`** — pure encode/decode + the on-disk file URL
///   derivation. No I/O state, no `@Observable`, so it's exhaustively
///   unit-testable: round-trips, forward-compatibility (unknown keys), and
///   corrupt-data tolerance all pin here.
/// - **`SmartPlaylistStore`** — the `@Observable @MainActor` view-model the
///   sidebar / builder bind to. It owns the live `[SmartPlaylist]` array,
///   loads it once on init, and writes through to disk on every mutation.
///
/// File location mirrors `CoreDataLocation`: `~/Library/Application
/// Support/lyrebird-desktop/smart-playlists.json`. Reusing that folder keeps
/// all the app's local state in one place a user can find (and the
/// "uninstall data locations" surface, #197, already documents it).

// MARK: - Codec

/// Pure, side-effect-free JSON codec + path derivation for smart playlists.
/// Everything here is `static` and takes its inputs explicitly so the tests
/// never touch the real Application Support directory.
enum SmartPlaylistCodec {
    /// Versioned envelope so a future schema migration has a hook. `version`
    /// is written on save and ignored on load today (all v1), but a decoder
    /// that bumps the model can branch on it without a flag-day.
    struct Document: Codable {
        var version: Int
        var playlists: [SmartPlaylist]

        init(version: Int = SmartPlaylistCodec.currentVersion, playlists: [SmartPlaylist]) {
            self.version = version
            self.playlists = playlists
        }
    }

    static let currentVersion = 1
    static let fileName = "smart-playlists.json"

    /// The on-disk document URL inside the app's Application Support folder.
    /// `nil` only when no home / `XDG_DATA_HOME` is resolvable (matching
    /// `CoreDataLocation.resolve`). Shares the core's folder so all local
    /// state co-locates.
    static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = NSHomeDirectory()
    ) -> URL? {
        CoreDataLocation.resolve(environment: environment, home: home)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Encode playlists to pretty-printed JSON (human-diffable; a user can
    /// inspect / hand-edit the file). Sorted keys keep the output stable
    /// across runs so the file doesn't churn in backups.
    static func encode(_ playlists: [SmartPlaylist]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(playlists: playlists))
    }

    /// Decode a document back to playlists. Tolerant of an empty file (yields
    /// `[]`). Throws on genuinely malformed JSON so the store can decide
    /// whether to quarantine it.
    static func decode(_ data: Data) throws -> [SmartPlaylist] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Document.self, from: data).playlists
    }
}

// MARK: - Store

/// Observable, main-actor store the UI binds to. Holds the live playlists,
/// persists through to disk on mutation, and exposes small CRUD helpers so
/// call sites never re-encode by hand.
@Observable
@MainActor
final class SmartPlaylistStore {
    /// The live, ordered list. The sidebar renders these; mutating it through
    /// the CRUD helpers keeps disk in sync. Direct assignment also persists
    /// (via `didSet`) so SwiftUI bindings that write the whole array still
    /// save.
    private(set) var playlists: [SmartPlaylist] = []

    /// Injected so tests can point the store at a temp file (or `nil` to run
    /// fully in-memory). Production resolves the Application Support URL.
    private let fileURL: URL?
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to the Application Support
    ///     document. Pass an explicit temp URL in tests, or `nil` to disable
    ///     persistence entirely (pure in-memory).
    ///   - load: when `true` (default) the store reads any existing document
    ///     on init. Tests that want a clean slate pass `false`.
    init(
        fileURL: URL? = SmartPlaylistCodec.fileURL(),
        fileManager: FileManager = .default,
        load: Bool = true
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if load { self.playlists = Self.readFromDisk(url: fileURL, fileManager: fileManager) }
    }

    // MARK: CRUD

    /// Look up a playlist by id. `nil` when it's been deleted out from under
    /// a stale route / sidebar selection.
    func playlist(id: UUID) -> SmartPlaylist? {
        playlists.first { $0.id == id }
    }

    /// Insert a new playlist (appends) and persist.
    func add(_ playlist: SmartPlaylist) {
        playlists.append(playlist)
        persist()
    }

    /// Replace an existing playlist (matched by id) in place and persist. No-op
    /// if the id isn't present, so a save from a builder editing a since-deleted
    /// playlist doesn't resurrect it.
    func update(_ playlist: SmartPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx] = playlist
        persist()
    }

    /// Insert-or-replace: update in place if the id exists, else append. The
    /// builder's "Save" calls this so the same code path handles both editing
    /// an existing playlist and committing a brand-new draft.
    func save(_ playlist: SmartPlaylist) {
        if playlists.contains(where: { $0.id == playlist.id }) {
            update(playlist)
        } else {
            add(playlist)
        }
    }

    /// Remove a playlist by id and persist.
    func remove(id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    /// Rename a playlist in place. Convenience over `update` for the common
    /// sidebar inline-rename path.
    func rename(id: UUID, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        persist()
    }

    // MARK: Persistence

    /// Write the current `playlists` to disk. Best-effort: encode / write
    /// failures are logged (Console under `category:app`) rather than thrown,
    /// because a failed save of a *local convenience* feature shouldn't crash
    /// the app or block the UI — the in-memory array remains the source of
    /// truth for the session. A `nil` `fileURL` means "in-memory only".
    private func persist() {
        guard let fileURL else { return }
        do {
            let data = try SmartPlaylistCodec.encode(playlists)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Failed to persist smart playlists: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read + decode the document, returning `[]` on a missing file or any
    /// decode error (a corrupt file degrades to "no smart playlists" rather
    /// than crashing the launch). Static so `init` can call it before `self`
    /// is fully formed.
    private static func readFromDisk(url: URL?, fileManager: FileManager) -> [SmartPlaylist] {
        guard let url, fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try SmartPlaylistCodec.decode(data)
        } catch {
            Log.app.error("Failed to read smart playlists, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
