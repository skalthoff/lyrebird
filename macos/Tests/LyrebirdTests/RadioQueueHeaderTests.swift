import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Queue "Radio · Seed: {seed}" on-air header.
///
/// The header swaps in whenever `AppModel.radioSeedName` is non-nil, which is
/// the single source of truth both `QueueInspector` and `FullQueueView` read.
/// These tests pin its derivation from `currentContext`: it surfaces the seed
/// only for a `.radio` source, stays silent for every other source kind, and
/// treats an empty name as "no seed" so the header never renders a bare
/// "Seed:" with nothing after it.
///
/// Same isolation contract as `DiscoverSongRadioRouteTests`: `AppModel` is
/// `@MainActor` and boots a live core pointed at a throwaway data dir.
@MainActor
final class RadioQueueHeaderTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-radioheader-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    func testRadioSeedNameSurfacesSeedForRadioSource() throws {
        let model = try AppModel()
        model.currentContext = QueueContext(name: "Daft Punk", id: "abc", sourceType: .radio)
        XCTAssertEqual(
            model.radioSeedName,
            "Daft Punk",
            "a .radio context must surface its seed so the on-air header renders"
        )
    }

    func testRadioSeedNameIsNilForNonRadioSources() throws {
        let model = try AppModel()
        for source: ContextSourceType in [.album, .playlist, .artist, .genre, .search, .other] {
            model.currentContext = QueueContext(name: "Discovery", id: "abc", sourceType: source)
            XCTAssertNil(
                model.radioSeedName,
                "\(source) is not radio — the queue must keep its usual PLAYING FROM header"
            )
        }
    }

    func testRadioSeedNameIsNilWhenNoContext() throws {
        let model = try AppModel()
        model.currentContext = nil
        XCTAssertNil(model.radioSeedName, "no source means no radio header")
    }

    /// An empty seed label must read as "no seed" rather than rendering a
    /// dangling "Seed:" with nothing after it.
    func testRadioSeedNameIsNilForEmptySeedLabel() throws {
        let model = try AppModel()
        model.currentContext = QueueContext(name: "", id: "abc", sourceType: .radio)
        XCTAssertNil(
            model.radioSeedName,
            "an empty radio seed must not render a bare 'Seed:' header"
        )
    }
}
