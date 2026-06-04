import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Home "Pinned Stations" row (#253) becoming a real reader
/// of the genre pin-to-home write path.
///
/// Before this fix `HomeView.pinnedStationsRow` was defined but never mounted
/// in `body`, while `AppModel.pinGenreToHome` (reachable from the genre Pin
/// button and the genre context menu) kept writing pins into
/// `PinnedStationsStore`. That is a write path with no reader. These tests pin
/// the now-load-bearing contracts:
///
///   1. A genre pinned via `pinGenreToHome` lands in `PinnedStationsStore`,
///      which is exactly the slice `pinnedStationsRow` decodes and renders.
///   2. The dedupe + 6-entry cap that keeps the row bounded.
///   3. `PinnedStationsStore.defaultsKey` matches the `@AppStorage` key the
///      Home row reads ("pinned_stations") — a silent rename would desync the
///      writer (`AppModel`) from the reader (`HomeView`) and make every pin
///      vanish again, which is the very regression this fix closes.
///   4. `startStationRadio(seedId:)`, the routing entry point the row uses for
///      artist / mood / mix tiles, exists and is callable.
///
/// `AppModel` is `@MainActor` and boots a live core, so the suite is
/// main-actor isolated and redirects the core's data dir to a throwaway temp
/// dir via `XDG_DATA_HOME`. Persistence runs against the standard
/// `UserDefaults` domain, so each test scrubs the key before and after to stay
/// hermetic (same pattern as `PaletteRecentPinnedTests`).
@MainActor
final class PinnedStationsHomeTests: XCTestCase {

    private let pinnedKey = PinnedStationsStore.defaultsKey

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-pinned-stations-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: pinnedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: pinnedKey)
        super.tearDown()
    }

    // MARK: - Write path now has a reader

    /// Pinning a genre persists a `.genre` station into the store the Home row
    /// reads. The genre's `id` doubles as its `title` because `Genre(name:)`
    /// sets `id == name`.
    func testPinGenrePersistsIntoStore() throws {
        let model = try AppModel()
        model.pinGenreToHome(genre: Genre(name: "Jazz"))

        let stations = PinnedStationsStore.load()
        XCTAssertEqual(stations.count, 1)
        let station = try XCTUnwrap(stations.first)
        XCTAssertEqual(station.type, .genre)
        XCTAssertEqual(station.title, "Jazz")
        XCTAssertEqual(station.id, "Jazz")
    }

    /// The most-recently pinned genre lands at the front so the row reads
    /// newest-first.
    func testPinGenreInsertsAtFront() throws {
        let model = try AppModel()
        model.pinGenreToHome(genre: Genre(name: "Jazz"))
        model.pinGenreToHome(genre: Genre(name: "Soul"))

        XCTAssertEqual(PinnedStationsStore.load().map(\.title), ["Soul", "Jazz"])
    }

    /// Re-pinning an already-pinned genre promotes it to the front rather than
    /// duplicating it — the row never shows the same genre twice.
    func testPinGenreDedupesAndPromotes() throws {
        let model = try AppModel()
        model.pinGenreToHome(genre: Genre(name: "Jazz"))
        model.pinGenreToHome(genre: Genre(name: "Soul"))
        model.pinGenreToHome(genre: Genre(name: "Jazz"))

        XCTAssertEqual(PinnedStationsStore.load().map(\.title), ["Jazz", "Soul"])
    }

    /// The store keeps at most six pins so the Home shelf stays bounded; the
    /// oldest pin falls off the end.
    func testPinGenreCapsAtSix() throws {
        let model = try AppModel()
        for name in ["A", "B", "C", "D", "E", "F", "G"] {
            model.pinGenreToHome(genre: Genre(name: name))
        }

        let titles = PinnedStationsStore.load().map(\.title)
        XCTAssertEqual(titles.count, 6)
        XCTAssertEqual(titles, ["G", "F", "E", "D", "C", "B"])
        XCTAssertFalse(titles.contains("A"), "the oldest pin must be evicted past the cap")
    }

    // MARK: - Writer/reader key contract

    /// `HomeView` reads the row via `@AppStorage(PinnedStationsStore.defaultsKey)`
    /// and `AppModel` writes via `PinnedStationsStore.save`. Both sides resolve
    /// to this one on-disk key; renaming it silently desyncs them and re-opens
    /// the "pins vanish" bug, so the literal is pinned here.
    func testPersistedKeyIsStable() {
        XCTAssertEqual(PinnedStationsStore.defaultsKey, "pinned_stations")
    }

    /// A genre written through `pinGenreToHome` is decodable straight off the
    /// raw `UserDefaults` blob the `@AppStorage` reader observes — i.e. the
    /// writer and the Home reader agree on the encoded shape end to end.
    func testPinIsReadableFromRawDefaultsBlob() throws {
        let model = try AppModel()
        model.pinGenreToHome(genre: Genre(name: "Ambient"))

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: pinnedKey))
        let decoded = try JSONDecoder().decode([PinnedStation].self, from: data)
        XCTAssertEqual(decoded.map(\.title), ["Ambient"])
    }

    // MARK: - Station-tap routing entry point

    /// The artist / mood / mix tiles route through `startStationRadio(seedId:)`.
    /// It must exist and run without throwing for an arbitrary seed id (the
    /// async instant-mix FFI it kicks off is fire-and-forget; we only assert
    /// the synchronous entry point is wired and callable).
    func testStartStationRadioIsCallable() throws {
        let model = try AppModel()
        model.startStationRadio(seedId: "seed-artist-1")
    }
}
