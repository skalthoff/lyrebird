import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the ArtistDetailView transport-row polish (audit fixes):
///
/// - The primary play button's label must match what it *actually* plays:
///   "Play top songs" when there is play history (the common case, where the
///   button plays the loaded Top Songs), and "Play all tracks" only in the
///   no-history fallback that plays the full catalog. Previously the label
///   always claimed "Play all tracks" regardless.
/// - `AppModel.resolveImageURLs` must resolve a batch of artwork URLs off the
///   main thread and return one entry per distinct requested id, deduping
///   repeats and handling empty input — so the eager discography carousel can
///   hand each tile a pre-resolved URL instead of taking the Rust `Inner`
///   mutex on the MainActor inside every tile body.
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; we redirect the
/// core's data dir to a throwaway temp dir via `XDG_DATA_HOME` so the test
/// never touches the real app database. With no authenticated server the
/// image-URL FFI yields `nil`, which is exactly the "not resolvable yet" path
/// the carousel tolerates — the keys-present / dedup contract still holds.
@MainActor
final class ArtistDetailTransportTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Primary play button label (audit L363)

    func testPrimaryPlayHelpReflectsTopSongsWhenHistoryPresent() {
        // Common case: history present → button plays Top Songs, so it must
        // say so rather than promising the full catalog.
        XCTAssertEqual(ArtistDetailView.primaryPlayHelp(hasTopTracks: true), "Play top songs")
    }

    func testPrimaryPlayHelpReflectsAllTracksWhenNoHistory() {
        // Fallback case: no history → button plays the full catalog.
        XCTAssertEqual(ArtistDetailView.primaryPlayHelp(hasTopTracks: false), "Play all tracks")
    }

    func testPrimaryPlayAccessibilityLabelNamesArtistAndMatchesBehavior() {
        XCTAssertEqual(
            ArtistDetailView.primaryPlayAccessibilityLabel(
                hasTopTracks: true, artistName: "Radiohead"
            ),
            "Play top songs by Radiohead"
        )
        XCTAssertEqual(
            ArtistDetailView.primaryPlayAccessibilityLabel(
                hasTopTracks: false, artistName: "Radiohead"
            ),
            "Play all tracks by Radiohead"
        )
    }

    // MARK: - resolveImageURLs (audit L565)

    func testResolveImageURLsReturnsEntryPerDistinctID() async throws {
        let model = try AppModel()
        let result = await model.resolveImageURLs(
            for: [
                (id: "al1", tag: "t1"),
                (id: "al2", tag: nil),
                (id: "al3", tag: "t3"),
            ],
            maxWidth: 400
        )
        // One entry per requested id, regardless of whether the URL resolves
        // (no server in tests → values are nil). The carousel keys off the id.
        XCTAssertEqual(Set(result.keys), ["al1", "al2", "al3"])
    }

    func testResolveImageURLsDedupesRepeatedIDs() async throws {
        let model = try AppModel()
        let result = await model.resolveImageURLs(
            for: [
                (id: "dup", tag: "t"),
                (id: "dup", tag: "t"),
                (id: "dup", tag: "t"),
            ],
            maxWidth: 400
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Set(result.keys), ["dup"])
    }

    func testResolveImageURLsEmptyInputReturnsEmpty() async throws {
        let model = try AppModel()
        let result = await model.resolveImageURLs(for: [], maxWidth: 400)
        XCTAssertTrue(result.isEmpty)
    }

    func testResolveImageURLsIsConsistentAcrossCalls() async throws {
        // Second call (served from the warmed cache for already-seen tuples)
        // must agree with the first — the carousel relies on a stable URL per
        // id across re-renders.
        let model = try AppModel()
        let items = [(id: "al1", tag: "t1"), (id: "al2", tag: nil)]
        let first = await model.resolveImageURLs(for: items, maxWidth: 400)
        let second = await model.resolveImageURLs(for: items, maxWidth: 400)
        XCTAssertEqual(Set(first.keys), Set(second.keys))
        for key in first.keys {
            // URL? equality across the two calls.
            XCTAssertEqual(first[key] ?? nil, second[key] ?? nil)
        }
    }

    // MARK: - Artist bio "Read more" truncation (#1012)
    //
    // The bio "Read more" button must only appear when the text overflows the
    // 4-line clamp. The truncation decision delegates to `AboutOverviewTruncation`
    // (shared with AlbumDetailView) so we exercise that path here from the
    // artist-detail perspective.

    func testBioTruncatedWhenFullExceedsClamped() {
        // A long bio that overflows 4 lines: full height clearly exceeds clamped.
        XCTAssertTrue(
            AboutOverviewTruncation.isTruncated(clamped: 80, full: 240),
            "A multi-paragraph bio taller than 4 lines must show Read more")
    }

    func testBioNotTruncatedWhenHeightsMatch() {
        // A short bio that fits in ≤4 lines: heights are equal.
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: 40, full: 40),
            "A short bio that fits must not show Read more")
    }

    func testBioNotTruncatedBeforeMeasurementSettles() {
        // Heights are both 0 until the first layout pass; button must not flash.
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: 0, full: 0),
            "Read more must not appear before height measurement arrives")
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: 0, full: 200),
            "Read more must not appear when only full height is known")
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: 80, full: 0),
            "Read more must not appear when only clamped height is known")
    }

    func testBioEpsilonAbsorbsSubpointRounding() {
        // A bio that exactly fills 4 lines — clamped and full differ by less
        // than epsilon due to float rounding — must not show Read more.
        let clamped: CGFloat = 80
        let full = clamped + AboutOverviewTruncation.epsilon - 0.01
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: clamped, full: full),
            "Sub-epsilon difference must not register as truncation")
    }

    func testBioDifferenceAboveEpsilonIsTruncated() {
        // A bio that overflows by more than one wrapped line shows Read more.
        let clamped: CGFloat = 80
        let full = clamped + AboutOverviewTruncation.epsilon + 18 // ~one line
        XCTAssertTrue(AboutOverviewTruncation.isTruncated(clamped: clamped, full: full))
    }
}
