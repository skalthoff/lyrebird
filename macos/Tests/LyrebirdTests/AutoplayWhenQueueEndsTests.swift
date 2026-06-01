import XCTest

@testable import Lyrebird

/// Coverage for the "autoplay similar music when the queue ends" preference:
/// the **default-on** contract (an unset key must resolve to `true`, not
/// `UserDefaults.bool(forKey:)`'s `false`) and the persistence round-trip
/// through `setAutoplayWhenQueueEnds(_:)`.
///
/// `AppModel` is `@MainActor`, so the whole suite is main-actor isolated.
/// Constructing it boots a live `LyrebirdCore`; we redirect the core's data
/// directory to a throwaway temp dir via `XDG_DATA_HOME` (honoured by
/// `storage::default_data_dir()`) so the test never touches the real app's
/// database. Persistence runs against the standard `UserDefaults` domain, so
/// each test scrubs the key before and after to stay hermetic.
@MainActor
final class AutoplayWhenQueueEndsTests: XCTestCase {

    /// The persisted key, kept in sync with `AppModel.autoplayWhenQueueEndsKey`
    /// (private). If that string ever changes, the default-on probe and the
    /// persistence assertions here go stale, so this test pins the contract.
    private let key = "queue.autoplayWhenQueueEnds"

    /// Point the core at a unique temp data dir before the first `AppModel()`
    /// in the process. Set once for the whole suite — the core reads the env
    /// var when it builds its default data dir, and we never want the real
    /// `~/Library/Application Support/lyrebird-desktop` DB created by tests.
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    override func setUp() {
        super.setUp()
        // A stale persisted value would mask the default-on probe, so clear
        // the key before constructing the model under test.
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - default-on contract

    /// With the key never written, the flag must read `true`. This is the
    /// load-bearing contract: a naive `bool(forKey:)` would return `false`
    /// and silently invert the feature to "stop at end of queue" by default.
    func testDefaultsToOnWhenKeyUnset() throws {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "precondition: key must be unset for the default probe"
        )

        let model = try AppModel()
        XCTAssertTrue(
            model.autoplayWhenQueueEnds,
            "an unset preference must default to autoplay-on"
        )
    }

    /// A persisted `false` must survive into a freshly-constructed model — the
    /// default-on probe must not clobber an explicit opt-out.
    func testPersistedFalseIsHonouredOnLaunch() throws {
        UserDefaults.standard.set(false, forKey: key)

        let model = try AppModel()
        XCTAssertFalse(
            model.autoplayWhenQueueEnds,
            "a persisted opt-out must be restored, not reset to the default"
        )
    }

    // MARK: - setAutoplayWhenQueueEnds (persistence round-trip)

    func testSetAutoplayUpdatesPropertyAndPersists() throws {
        let model = try AppModel()

        model.setAutoplayWhenQueueEnds(false)
        XCTAssertFalse(model.autoplayWhenQueueEnds, "live property reflects the set value")
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: key),
            "turning autoplay off must persist so the next launch restores it"
        )

        model.setAutoplayWhenQueueEnds(true)
        XCTAssertTrue(model.autoplayWhenQueueEnds)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: key),
            "turning autoplay back on must persist too"
        )
    }
}
