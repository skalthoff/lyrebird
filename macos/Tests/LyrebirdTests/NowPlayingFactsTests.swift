import Foundation
import XCTest

@testable import Lyrebird

/// Coverage for `NowPlayingFacts` — the pure logic behind the Now Playing
/// rotating tagline. Exercises each quip builder, the lossless container
/// matcher, the wall-clock-to-index mapping, and the assembled variant set.
final class NowPlayingFactsTests: XCTestCase {

    // MARK: - playCountQuip

    func testPlayCountQuipScalesWithCount() {
        XCTAssertEqual(NowPlayingFacts.playCountQuip(0), "")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(1), "You've heard this once.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(2), "You've played this 2 times.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(4), "You've played this 4 times.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(5), "A regular — 5 plays and counting.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(24), "A regular — 24 plays and counting.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(25), "On heavy rotation — 25 plays.")
        XCTAssertEqual(NowPlayingFacts.playCountQuip(200), "On heavy rotation — 200 plays.")
    }

    // MARK: - isLossless

    func testIsLosslessMatchesKnownContainers() {
        for codec in ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"] {
            XCTAssertTrue(NowPlayingFacts.isLossless(codec), "expected \(codec) lossless")
        }
    }

    func testIsLosslessIsCaseInsensitive() {
        XCTAssertTrue(NowPlayingFacts.isLossless("FLAC"))
        XCTAssertTrue(NowPlayingFacts.isLossless("Alac"))
    }

    func testIsLosslessMatchesAnyComponentOfJoinedContainer() {
        XCTAssertTrue(NowPlayingFacts.isLossless("mp3,flac"))
        XCTAssertTrue(NowPlayingFacts.isLossless("flac alac"))
    }

    func testIsLosslessRejectsLossyAndNil() {
        XCTAssertFalse(NowPlayingFacts.isLossless("mp3"))
        XCTAssertFalse(NowPlayingFacts.isLossless("aac,m4a"))
        XCTAssertFalse(NowPlayingFacts.isLossless(nil))
        XCTAssertFalse(NowPlayingFacts.isLossless(""))
    }

    // MARK: - lastHeardQuip

    func testLastHeardQuipParsesFractionalISO() {
        let quip = NowPlayingFacts.lastHeardQuip("2024-03-09T18:30:00.000Z")
        XCTAssertNotNil(quip)
        XCTAssertTrue(quip?.hasPrefix("Last heard ") ?? false)
    }

    func testLastHeardQuipParsesPlainISO() {
        let quip = NowPlayingFacts.lastHeardQuip("2024-03-09T18:30:00Z")
        XCTAssertNotNil(quip)
        XCTAssertTrue(quip?.hasPrefix("Last heard ") ?? false)
    }

    func testLastHeardQuipReturnsNilForMissingOrUnparseable() {
        XCTAssertNil(NowPlayingFacts.lastHeardQuip(nil))
        XCTAssertNil(NowPlayingFacts.lastHeardQuip(""))
        XCTAssertNil(NowPlayingFacts.lastHeardQuip("not-a-date"))
    }

    // MARK: - index

    func testIndexIsStableWithinASlotAndAdvancesAcrossSlots() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(NowPlayingFacts.index(at: base, count: 3), 0)
        XCTAssertEqual(NowPlayingFacts.index(at: base.addingTimeInterval(14), count: 3), 0)
        XCTAssertEqual(NowPlayingFacts.index(at: base.addingTimeInterval(15), count: 3), 1)
        XCTAssertEqual(NowPlayingFacts.index(at: base.addingTimeInterval(30), count: 3), 2)
        XCTAssertEqual(NowPlayingFacts.index(at: base.addingTimeInterval(45), count: 3), 0)
    }

    func testIndexNeverOutOfBoundsForZeroCount() {
        XCTAssertEqual(NowPlayingFacts.index(at: Date(), count: 0), 0)
    }

    func testIndexStaysInBoundsForNegativeReferenceOffsets() {
        let preReference = Date(timeIntervalSinceReferenceDate: -100)
        let idx = NowPlayingFacts.index(at: preReference, count: 4)
        XCTAssertTrue((0..<4).contains(idx))
    }

    // MARK: - variants

    func testVariantsAreEmptyWhenNothingWorthSaying() {
        XCTAssertTrue(
            NowPlayingFacts.variants(playCount: 0, container: "mp3", lastPlayedAt: nil).isEmpty
        )
    }

    func testVariantsOrderAndContent() {
        let facts = NowPlayingFacts.variants(
            playCount: 7,
            container: "flac",
            lastPlayedAt: "2024-03-09T18:30:00Z"
        )
        XCTAssertEqual(facts.count, 3)
        XCTAssertEqual(facts[0], "A regular — 7 plays and counting.")
        XCTAssertEqual(facts[1], "Lossless — you're hearing the master.")
        XCTAssertTrue(facts[2].hasPrefix("Last heard "))
    }

    func testVariantsOmitsLosslessForLossyContainer() {
        let facts = NowPlayingFacts.variants(playCount: 1, container: "mp3", lastPlayedAt: nil)
        XCTAssertEqual(facts, ["You've heard this once."])
    }
}
