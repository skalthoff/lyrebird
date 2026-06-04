import XCTest
@testable import Lyrebird
import LyrebirdCore

/// Coverage for `SmartPlaylistCodec` (pure JSON codec + path derivation) and
/// `SmartPlaylistStore` (the observable, disk-backed CRUD store) for #77 /
/// #238. The codec tests are pure; the store tests run against a temp file
/// so they never touch the real Application Support directory.
final class SmartPlaylistStoreTests: XCTestCase {

    // MARK: - Codec

    /// Encode → decode round-trips the playlists verbatim, through the
    /// versioned document envelope.
    func testCodecRoundTrip() throws {
        let playlists = [
            SmartPlaylist(name: "A", matchMode: .all, rules: [
                SmartPlaylistRule(field: .artist, op: .is, value: "Radiohead"),
            ]),
            SmartPlaylist(name: "B", matchMode: .any, rules: [
                SmartPlaylistRule(field: .year, op: .greaterThan, value: "2000"),
                SmartPlaylistRule(field: .isFavorite, op: .is, value: "true"),
            ]),
        ]
        let data = try SmartPlaylistCodec.encode(playlists)
        let decoded = try SmartPlaylistCodec.decode(data)
        XCTAssertEqual(decoded, playlists)
    }

    /// The encoded document carries the current schema version so a future
    /// migration has a branch point.
    func testCodecWritesVersion() throws {
        let data = try SmartPlaylistCodec.encode([])
        let doc = try JSONDecoder().decode(SmartPlaylistCodec.Document.self, from: data)
        XCTAssertEqual(doc.version, SmartPlaylistCodec.currentVersion)
    }

    /// Decoding empty data yields an empty list rather than throwing (an
    /// empty file is a legitimate "no playlists yet" state).
    func testCodecDecodesEmptyDataToEmptyList() throws {
        XCTAssertEqual(try SmartPlaylistCodec.decode(Data()), [])
    }

    /// A document with an unrecognized extra key still decodes — forward
    /// compatibility so a file written by a newer build doesn't brick an
    /// older one.
    func testCodecToleratesUnknownKeys() throws {
        let json = """
        {
          "version": 1,
          "unexpectedFutureField": "ignored",
          "playlists": [
            { "id": "\(UUID().uuidString)", "name": "X", "matchMode": "all", "rules": [] }
          ]
        }
        """
        let decoded = try SmartPlaylistCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "X")
    }

    /// Genuinely malformed JSON throws so the caller can decide to quarantine.
    func testCodecThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try SmartPlaylistCodec.decode(Data("{ not json".utf8)))
    }

    /// The file URL lands inside the shared `lyrebird-desktop` Application
    /// Support folder, mirroring `CoreDataLocation`.
    func testFileURLDerivation() {
        let url = SmartPlaylistCodec.fileURL(environment: [:], home: "/Users/test")
        XCTAssertEqual(
            url?.path,
            "/Users/test/Library/Application Support/lyrebird-desktop/smart-playlists.json"
        )
    }

    /// `XDG_DATA_HOME` overrides the home-relative path (matching the core).
    func testFileURLHonoursXDG() {
        let url = SmartPlaylistCodec.fileURL(environment: ["XDG_DATA_HOME": "/xdg"], home: "/Users/test")
        XCTAssertEqual(url?.path, "/xdg/lyrebird-desktop/smart-playlists.json")
    }

    // MARK: - Store CRUD (temp file)

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-playlist-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("smart-playlists.json")
    }

    @MainActor
    func testStoreAddAndPersist() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SmartPlaylistStore(fileURL: url, load: false)
        let pl = SmartPlaylist(name: "Drive", rules: [
            SmartPlaylistRule(field: .playCount, op: .greaterThan, value: "10"),
        ])
        store.add(pl)
        XCTAssertEqual(store.playlists.count, 1)

        // A second store pointed at the same file reads the persisted data.
        let reloaded = SmartPlaylistStore(fileURL: url, load: true)
        XCTAssertEqual(reloaded.playlists, [pl])
    }

    @MainActor
    func testStoreSaveUpdatesInPlace() {
        let store = SmartPlaylistStore(fileURL: nil, load: false) // in-memory
        var pl = SmartPlaylist(name: "Original")
        store.save(pl) // insert
        XCTAssertEqual(store.playlists.count, 1)

        pl.name = "Renamed"
        store.save(pl) // update, same id → no duplicate
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlists.first?.name, "Renamed")
    }

    @MainActor
    func testStoreUpdateIgnoresUnknownId() {
        let store = SmartPlaylistStore(fileURL: nil, load: false)
        store.add(SmartPlaylist(name: "Keep"))
        // Updating a playlist that isn't present must not resurrect it.
        store.update(SmartPlaylist(name: "Ghost"))
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlists.first?.name, "Keep")
    }

    @MainActor
    func testStoreRemove() {
        let store = SmartPlaylistStore(fileURL: nil, load: false)
        let a = SmartPlaylist(name: "A")
        let b = SmartPlaylist(name: "B")
        store.add(a)
        store.add(b)
        store.remove(id: a.id)
        XCTAssertEqual(store.playlists.map(\.id), [b.id])
    }

    @MainActor
    func testStoreRename() {
        let store = SmartPlaylistStore(fileURL: nil, load: false)
        let pl = SmartPlaylist(name: "Before")
        store.add(pl)
        store.rename(id: pl.id, to: "After")
        XCTAssertEqual(store.playlist(id: pl.id)?.name, "After")
    }

    /// A store pointed at a non-existent file loads to an empty list rather
    /// than crashing the launch.
    @MainActor
    func testStoreMissingFileLoadsEmpty() {
        let store = SmartPlaylistStore(fileURL: tempFileURL(), load: true)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    /// A store pointed at a corrupt file degrades to empty rather than
    /// throwing out of `init`.
    @MainActor
    func testStoreCorruptFileLoadsEmpty() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ corrupt".utf8).write(to: url)

        let store = SmartPlaylistStore(fileURL: url, load: true)
        XCTAssertTrue(store.playlists.isEmpty)
    }
}
