import XCTest

@testable import Lyrebird

/// Coverage for `NotificationManager`'s pure decision helpers — the
/// track-change guard and the subtitle composition rule.
///
/// Both are exercised through the static `shouldNotify(enabled:)` and
/// `subtitle(artist:album:)` helpers so the behavior is verified without
/// realizing a `UNUserNotificationCenter`, which a headless test run can't do.
final class NotificationManagerTests: XCTestCase {

    // MARK: - Guard

    func testShouldNotifyFalseWhenDisabled() {
        XCTAssertFalse(
            NotificationManager.shouldNotify(enabled: false),
            "track-change notifications must be suppressed when the toggle is off"
        )
    }

    func testShouldNotifyTrueWhenEnabled() {
        XCTAssertTrue(
            NotificationManager.shouldNotify(enabled: true),
            "track-change notifications fire when the toggle is on"
        )
    }

    // MARK: - Subtitle composition

    func testSubtitleJoinsArtistAndAlbum() {
        XCTAssertEqual(
            NotificationManager.subtitle(artist: "Radiohead", album: "Kid A"),
            "Radiohead — Kid A",
            "both present: subtitle is 'Artist — Album'"
        )
    }

    func testSubtitleArtistOnly() {
        XCTAssertEqual(
            NotificationManager.subtitle(artist: "Radiohead", album: nil),
            "Radiohead",
            "album missing: subtitle is just the artist (no bare dash)"
        )
    }

    func testSubtitleAlbumOnly() {
        XCTAssertEqual(
            NotificationManager.subtitle(artist: nil, album: "Kid A"),
            "Kid A",
            "artist missing: subtitle is just the album (no bare dash)"
        )
    }

    func testSubtitleNilWhenBothMissing() {
        XCTAssertNil(
            NotificationManager.subtitle(artist: nil, album: nil),
            "neither present: no subtitle rather than an empty / dash-only body"
        )
    }

    func testSubtitleTreatsEmptyStringsAsMissing() {
        XCTAssertEqual(
            NotificationManager.subtitle(artist: "", album: "Kid A"),
            "Kid A",
            "empty artist string is dropped so the subtitle never leads with a dash"
        )
        XCTAssertNil(
            NotificationManager.subtitle(artist: "", album: ""),
            "two empty strings collapse to no subtitle"
        )
    }
}
