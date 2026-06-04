import XCTest

@testable import Lyrebird

/// Coverage for the command-palette recents + pinned store (#308).
///
/// Two layers are exercised:
///   1. The pure, static `appendPaletteRecent(_:into:cap:)` helper — the
///      cap / dedupe / insert-at-front contract that drives the "Recent"
///      group. Pinned by a unit test so a future refactor can't silently
///      drop dedupe or let the list grow past the cap.
///   2. The `AppModel` instance API (`recordPaletteActionUsage`,
///      `pin`/`unpin`/`togglePaletteActionPin`) and its JSON-in-UserDefaults
///      persistence round-trip, mirroring `AutoplayWhenQueueEndsTests`.
///
/// `AppModel` is `@MainActor`, so the suite is main-actor isolated.
/// Constructing it boots a live `LyrebirdCore`; we redirect the core's data
/// directory to a throwaway temp dir via `XDG_DATA_HOME` so the test never
/// touches the real app's database. Persistence runs against the standard
/// `UserDefaults` domain, so each test scrubs both keys before and after to
/// stay hermetic.
@MainActor
final class PaletteRecentPinnedTests: XCTestCase {

    /// Persisted keys, kept in sync with `AppModel`'s private constants. If
    /// those strings ever change, these assertions go stale, so this test
    /// pins the contract.
    private let recentKey = "palette.recentActionIds"
    private let pinnedKey = "palette.pinnedActionIds"

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-palette-rp-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: pinnedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: pinnedKey)
        super.tearDown()
    }

    // MARK: - appendPaletteRecent (pure: cap / dedupe / ordering)

    /// Newest run lands at the front of the list.
    func testAppendInsertsAtFront() {
        let list = AppModel.appendPaletteRecent("b", into: ["a"], cap: 5)
        XCTAssertEqual(list, ["b", "a"])
    }

    /// Re-running an action promotes its existing entry rather than
    /// duplicating it — dedupe is by exact id.
    func testAppendDedupesAndPromotes() {
        var list = ["a", "b", "c"]
        list = AppModel.appendPaletteRecent("c", into: list, cap: 5)
        XCTAssertEqual(list, ["c", "a", "b"], "re-run must move 'c' to front, not duplicate it")
        XCTAssertEqual(list.count, 3, "dedupe must not grow the list")
    }

    /// The list is capped to the most-recent `cap` entries; the oldest tail
    /// falls off when a new id pushes past the limit.
    func testAppendCapsToMostRecent() {
        var list: [String] = []
        for id in ["a", "b", "c", "d", "e", "f"] {
            list = AppModel.appendPaletteRecent(id, into: list, cap: 5)
        }
        XCTAssertEqual(list.count, 5, "cap must bound the list length")
        XCTAssertEqual(list, ["f", "e", "d", "c", "b"], "oldest entry ('a') must fall off")
        XCTAssertFalse(list.contains("a"))
    }

    /// An empty id is ignored — `executePaletteAction` only ever passes a
    /// real id, but the guard keeps a stray empty string out of the store.
    func testAppendIgnoresEmptyId() {
        let list = AppModel.appendPaletteRecent("", into: ["a"], cap: 5)
        XCTAssertEqual(list, ["a"])
    }

    /// The shipped cap is 5 (load-bearing for the empty-query layout).
    func testRecentsCapConstantIsFive() {
        XCTAssertEqual(AppModel.paletteRecentActionsCap, 5)
    }

    // MARK: - JSON codec round-trip

    func testEncodeDecodeRoundTrip() {
        let ids = ["nav.home", "playback.play", "queue.clear"]
        let json = AppModel.encodePaletteActionIds(ids)
        XCTAssertEqual(AppModel.decodePaletteActionIds(json), ids)
    }

    /// Malformed persisted data decodes to `[]` so a stale shape can't wedge
    /// the palette.
    func testDecodeMalformedReturnsEmpty() {
        XCTAssertEqual(AppModel.decodePaletteActionIds("not json"), [])
        XCTAssertEqual(AppModel.decodePaletteActionIds("{\"a\":1}"), [])
    }

    // MARK: - recordPaletteActionUsage (instance + persistence)

    func testRecordUsageUpdatesPropertyAndPersists() throws {
        let model = try AppModel()
        XCTAssertTrue(model.paletteRecentActionIds.isEmpty, "starts empty with no persisted data")

        model.recordPaletteActionUsage(id: "nav.home")
        model.recordPaletteActionUsage(id: "nav.library")
        XCTAssertEqual(model.paletteRecentActionIds, ["nav.library", "nav.home"], "newest first")

        let persisted = UserDefaults.standard.string(forKey: recentKey) ?? "[]"
        XCTAssertEqual(
            AppModel.decodePaletteActionIds(persisted),
            ["nav.library", "nav.home"],
            "recents must persist so the next launch restores them"
        )
    }

    func testExecutePaletteActionRecordsUsage() throws {
        let model = try AppModel()
        // `nav.home` is always present in the roster (no capability gate) and
        // its side effect (selecting the Home tab) is local + safe in tests.
        model.executePaletteAction(id: "nav.home")
        XCTAssertEqual(
            model.paletteRecentActionIds.first,
            "nav.home",
            "committing an action from the palette must record it as most-recent"
        )
    }

    func testRecentsRestoreFromPersistedJSONOnLaunch() throws {
        UserDefaults.standard.set(
            AppModel.encodePaletteActionIds(["queue.clear", "nav.discover"]),
            forKey: recentKey
        )
        let model = try AppModel()
        XCTAssertEqual(
            model.paletteRecentActionIds,
            ["queue.clear", "nav.discover"],
            "a freshly-constructed model must restore the persisted recents"
        )
    }

    // MARK: - pin / unpin / toggle (instance + persistence)

    func testPinInsertsAtFrontAndPersists() throws {
        let model = try AppModel()

        model.pinPaletteAction(id: "nav.home")
        model.pinPaletteAction(id: "queue.clear")
        XCTAssertEqual(model.palettePinnedActionIds, ["queue.clear", "nav.home"], "newest pin first")
        XCTAssertTrue(model.isPaletteActionPinned(id: "nav.home"))
        XCTAssertTrue(model.isPaletteActionPinned(id: "queue.clear"))

        let persisted = UserDefaults.standard.string(forKey: pinnedKey) ?? "[]"
        XCTAssertEqual(
            AppModel.decodePaletteActionIds(persisted),
            ["queue.clear", "nav.home"]
        )
    }

    /// Pinning an already-pinned id is a no-op — no duplicate, no reorder.
    func testPinIsIdempotent() throws {
        let model = try AppModel()
        model.pinPaletteAction(id: "nav.home")
        model.pinPaletteAction(id: "queue.clear")
        model.pinPaletteAction(id: "nav.home")
        XCTAssertEqual(
            model.palettePinnedActionIds,
            ["queue.clear", "nav.home"],
            "re-pinning must not duplicate or reorder"
        )
    }

    func testUnpinRemovesAndPersists() throws {
        let model = try AppModel()
        model.pinPaletteAction(id: "nav.home")
        model.pinPaletteAction(id: "queue.clear")

        model.unpinPaletteAction(id: "nav.home")
        XCTAssertEqual(model.palettePinnedActionIds, ["queue.clear"])
        XCTAssertFalse(model.isPaletteActionPinned(id: "nav.home"))

        let persisted = UserDefaults.standard.string(forKey: pinnedKey) ?? "[]"
        XCTAssertEqual(AppModel.decodePaletteActionIds(persisted), ["queue.clear"])
    }

    /// Unpinning an id that isn't pinned is a safe no-op.
    func testUnpinUnknownIsNoOp() throws {
        let model = try AppModel()
        model.pinPaletteAction(id: "nav.home")
        model.unpinPaletteAction(id: "not.pinned")
        XCTAssertEqual(model.palettePinnedActionIds, ["nav.home"])
    }

    func testToggleFlipsPinState() throws {
        let model = try AppModel()

        XCTAssertFalse(model.isPaletteActionPinned(id: "nav.discover"))
        model.togglePaletteActionPin(id: "nav.discover")
        XCTAssertTrue(model.isPaletteActionPinned(id: "nav.discover"))
        model.togglePaletteActionPin(id: "nav.discover")
        XCTAssertFalse(model.isPaletteActionPinned(id: "nav.discover"))
    }

    func testPinnedRestoreFromPersistedJSONOnLaunch() throws {
        UserDefaults.standard.set(
            AppModel.encodePaletteActionIds(["app.openPreferences"]),
            forKey: pinnedKey
        )
        let model = try AppModel()
        XCTAssertTrue(
            model.isPaletteActionPinned(id: "app.openPreferences"),
            "a freshly-constructed model must restore persisted pins"
        )
    }

    /// Recents and pinned are independent stores: recording usage must not
    /// touch the pinned list, and vice-versa.
    func testRecentAndPinnedStoresAreIndependent() throws {
        let model = try AppModel()
        model.recordPaletteActionUsage(id: "nav.home")
        model.pinPaletteAction(id: "queue.clear")

        XCTAssertEqual(model.paletteRecentActionIds, ["nav.home"])
        XCTAssertEqual(model.palettePinnedActionIds, ["queue.clear"])
        XCTAssertFalse(model.isPaletteActionPinned(id: "nav.home"), "recents are not implicitly pinned")
    }
}
