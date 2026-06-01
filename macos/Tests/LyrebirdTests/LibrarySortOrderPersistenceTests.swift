import XCTest

@testable import Lyrebird

/// Coverage for the Library-preferences persistence contract.
///
/// The default-sort preferences (`PreferencesLibrary`) persist a
/// `LibrarySortOrder` via `@AppStorage`, which relies on the enum being
/// `RawRepresentable` over *stable* String keys. If a raw value is ever
/// renamed, every user's saved default silently resets — these tests pin the
/// on-disk identifiers and the round-trip so that regression is caught here
/// rather than in the field.
final class LibrarySortOrderPersistenceTests: XCTestCase {
    /// Every case round-trips through its raw value, so `@AppStorage` can
    /// decode whatever it wrote.
    func testRawValueRoundTrips() {
        for order in LibrarySortOrder.allCases {
            XCTAssertEqual(
                LibrarySortOrder(rawValue: order.rawValue),
                order,
                "LibrarySortOrder.\(order) failed to round-trip through its raw value"
            )
        }
    }

    /// The stable on-disk identifiers. Renaming any of these is a breaking
    /// change to persisted user defaults and must come with a migration.
    func testStableRawValues() {
        XCTAssertEqual(LibrarySortOrder.nameAscending.rawValue, "nameAscending")
        XCTAssertEqual(LibrarySortOrder.nameDescending.rawValue, "nameDescending")
        XCTAssertEqual(LibrarySortOrder.artist.rawValue, "artist")
        XCTAssertEqual(LibrarySortOrder.recentlyAdded.rawValue, "recentlyAdded")
        XCTAssertEqual(LibrarySortOrder.recentlyPlayed.rawValue, "recentlyPlayed")
        XCTAssertEqual(LibrarySortOrder.mostPlayed.rawValue, "mostPlayed")
        XCTAssertEqual(LibrarySortOrder.longest.rawValue, "longest")
        XCTAssertEqual(LibrarySortOrder.shortest.rawValue, "shortest")
        XCTAssertEqual(LibrarySortOrder.yearAscending.rawValue, "yearAscending")
        XCTAssertEqual(LibrarySortOrder.yearDescending.rawValue, "yearDescending")
        XCTAssertEqual(LibrarySortOrder.random.rawValue, "random")
    }

    /// An unknown raw value (e.g. a key written by a future build) decodes to
    /// nil so the `@AppStorage` default kicks in rather than crashing.
    func testUnknownRawValueDecodesToNil() {
        XCTAssertNil(LibrarySortOrder(rawValue: "not-a-real-sort"))
    }

    /// Every case carries a non-empty menu label so the default-sort picker
    /// never renders a blank row.
    func testEveryCaseHasALabel() {
        for order in LibrarySortOrder.allCases {
            XCTAssertFalse(order.label.isEmpty, "LibrarySortOrder.\(order) has an empty label")
        }
    }

    /// The Library-preferences storage keys are stable identifiers. These are
    /// shared between `PreferencesLibrary` (writer) and the views that read
    /// them; a drift here silently disconnects the setting from its effect.
    func testLibraryDefaultsKeysAreStable() {
        XCTAssertEqual(LibraryDefaults.albumSortKey, "library.defaultSort.albums")
        XCTAssertEqual(LibraryDefaults.songSortKey, "library.defaultSort.songs")
        XCTAssertEqual(LibraryDefaults.showTrackNumbersKey, "library.showTrackNumbers")
        XCTAssertEqual(LibraryDefaults.showPlayCountOnHoverKey, "library.showPlayCountOnHover")
        XCTAssertEqual(LibraryDefaults.sidebarShowFavoritesKey, "library.sidebar.showFavorites")
        XCTAssertEqual(LibraryDefaults.sidebarShowAlbumsKey, "library.sidebar.showAlbums")
        XCTAssertEqual(LibraryDefaults.sidebarShowArtistsKey, "library.sidebar.showArtists")
        XCTAssertEqual(LibraryDefaults.sidebarShowPlaylistsKey, "library.sidebar.showPlaylists")
    }
}
