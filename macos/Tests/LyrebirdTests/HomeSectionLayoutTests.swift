import XCTest
@testable import Lyrebird

/// Coverage for `HomeSectionLayout` — the pure ordering + visibility logic
/// behind "Customize Home" (#56).
///
/// Like the sidebar's playlist reorder (#317), Home customization is
/// client-only: the Home view sorts the `HomeSection` catalog by two stored
/// CSV strings (the chosen order + the hidden set), so the contract that
/// matters is set-reconciliation, not any server round-trip. These tests pin:
///   * catalog invariants (stable raw values, default order == declaration);
///   * the CSV codec (`decode` / `encode`) the order `@AppStorage` rides on;
///   * the hidden-set codec (`decodeHidden` / `encodeHidden`);
///   * `reconciled` — stored sections keep their order, new shelves append,
///     retired ids prune, duplicates collapse (the persists-across-launches
///     contract);
///   * `visibleOrder` — order minus hidden, the single call the view makes;
///   * `applyingMove` + `togglingHidden` — folding the sheet's edits back.
final class HomeSectionLayoutTests: XCTestCase {

    // MARK: - Catalog invariants

    /// `defaultOrder` is exactly the declaration order — the reset target and
    /// the reconciliation tail both depend on this.
    func testDefaultOrderIsDeclarationOrder() {
        XCTAssertEqual(HomeSection.defaultOrder, HomeSection.allCases)
        XCTAssertEqual(HomeSection.defaultOrder.first, .recentlyPlayed)
    }

    /// Raw values are the stable persistence keys; assert a representative set
    /// so an accidental rename (which would silently drop a user's stored
    /// layout) trips the suite.
    func testRawValuesAreStablePersistenceKeys() {
        XCTAssertEqual(HomeSection.jumpBackIn.rawValue, "jumpBackIn")
        XCTAssertEqual(HomeSection.favorites.rawValue, "favorites")
        XCTAssertEqual(HomeSection.artistRadio.rawValue, "artistRadio")
        // Raw values must be comma-free so the CSV split is unambiguous.
        for section in HomeSection.allCases {
            XCTAssertFalse(section.rawValue.contains(","), "\(section) raw value has a comma")
        }
    }

    /// Every section exposes a non-empty title + glyph so the sheet never
    /// renders a blank row.
    func testEverySectionHasTitleAndGlyph() {
        for section in HomeSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) has an empty title")
            XCTAssertFalse(section.systemImage.isEmpty, "\(section) has an empty glyph")
        }
    }

    // MARK: - Order CSV codec

    func testEncodeDecodeRoundTrip() {
        let sections: [HomeSection] = [.favorites, .jumpBackIn, .quickPicks]
        XCTAssertEqual(HomeSectionLayout.encode(sections), "favorites,jumpBackIn,quickPicks")
        XCTAssertEqual(HomeSectionLayout.decode("favorites,jumpBackIn,quickPicks"), sections)
    }

    /// The empty `@AppStorage` default decodes to an empty list, not a ghost.
    func testDecodeEmptyStringYieldsEmptyList() {
        XCTAssertEqual(HomeSectionLayout.decode(""), [])
        XCTAssertEqual(HomeSectionLayout.encode([]), "")
    }

    /// Stray / trailing commas and whitespace are dropped; unknown raw values
    /// (a retired shelf id from a newer→older downgrade) are dropped too.
    func testDecodeDropsBlankWhitespaceAndUnknownEntries() {
        XCTAssertEqual(
            HomeSectionLayout.decode("favorites,, jumpBackIn ,bogus,"),
            [.favorites, .jumpBackIn]
        )
    }

    // MARK: - Reconciliation

    /// Stored sections present in the catalog keep their stored relative order —
    /// the whole point of persisting a reorder across launches.
    func testReconcileKeepsStoredOrderForSurvivingSections() {
        let result = HomeSectionLayout.reconciled(stored: [.favorites, .recentlyPlayed, .jumpBackIn])
        XCTAssertEqual(Array(result.prefix(3)), [.favorites, .recentlyPlayed, .jumpBackIn])
    }

    /// Sections shipped but not in the stored order (a shelf added in this app
    /// version) append at the bottom in catalog order rather than reshuffling
    /// the user's arrangement.
    func testReconcileAppendsNewCatalogSectionsAtBottom() {
        // A stored order from an "older" build that only knew two shelves.
        let result = HomeSectionLayout.reconciled(stored: [.quickPicks, .favorites])
        XCTAssertEqual(Array(result.prefix(2)), [.quickPicks, .favorites])
        // Everything else the catalog ships follows, and the whole catalog is
        // present exactly once.
        XCTAssertEqual(Set(result), Set(HomeSection.allCases))
        XCTAssertEqual(result.count, HomeSection.allCases.count)
    }

    /// The result is a duplicate-free permutation of the catalog even when the
    /// stored value is corrupt (a duplicate). Every live section appears once.
    func testReconcileIsDuplicateFreePermutationOfCatalog() {
        let result = HomeSectionLayout.reconciled(stored: [.favorites, .favorites, .jumpBackIn])
        XCTAssertEqual(result.count, Set(result).count, "no duplicates")
        XCTAssertEqual(Set(result), Set(HomeSection.allCases))
        XCTAssertEqual(Array(result.prefix(2)), [.favorites, .jumpBackIn])
    }

    /// An empty stored order yields the shipped default (catalog) order.
    func testReconcileEmptyStoredYieldsDefaultOrder() {
        XCTAssertEqual(HomeSectionLayout.reconciled(stored: []), HomeSection.allCases)
        XCTAssertEqual(HomeSectionLayout.order(stored: ""), HomeSection.allCases)
    }

    /// A full round trip through the codec + reconcile reproduces exactly the
    /// order the user dropped — the persists-across-launches guarantee.
    func testOrderPersistsAsStablePassThrough() {
        let moved = HomeSectionLayout.applyingMove(
            displayed: HomeSection.allCases,
            source: IndexSet(integer: HomeSection.allCases.count - 1),
            destination: 0
        )
        let raw = HomeSectionLayout.encode(moved)
        XCTAssertEqual(HomeSectionLayout.order(stored: raw), moved)
    }

    // MARK: - Hidden-set codec

    /// The hidden set encodes in stable catalog order regardless of insertion
    /// order, so the stored string doesn't churn between writes.
    func testHiddenSetEncodesInStableCatalogOrder() {
        let hidden: Set<HomeSection> = [.artistRadio, .recentlyPlayed]
        // recentlyPlayed precedes artistRadio in the catalog.
        XCTAssertEqual(HomeSectionLayout.encodeHidden(hidden), "recentlyPlayed,artistRadio")
    }

    func testHiddenSetRoundTrip() {
        let hidden: Set<HomeSection> = [.favorites, .quickPicks]
        let raw = HomeSectionLayout.encodeHidden(hidden)
        XCTAssertEqual(HomeSectionLayout.decodeHidden(raw), hidden)
    }

    /// `hidden(stored:)` drops ids no longer in the catalog so a stale hide
    /// can't strand a phantom.
    func testHiddenIntersectsLiveCatalog() {
        XCTAssertEqual(HomeSectionLayout.hidden(stored: "favorites,bogus"), [.favorites])
        XCTAssertEqual(HomeSectionLayout.hidden(stored: ""), [])
    }

    // MARK: - visibleOrder

    /// Hidden sections are removed and the rest keep their order — the single
    /// call the Home view makes to lay out its stack.
    func testVisibleOrderRemovesHiddenKeepsOrder() {
        let order = HomeSectionLayout.encode([.recentlyPlayed, .favorites, .jumpBackIn])
        let hidden = HomeSectionLayout.encodeHidden([.favorites])
        let visible = HomeSectionLayout.visibleOrder(order: order, hidden: hidden)
        XCTAssertEqual(Array(visible.prefix(2)), [.recentlyPlayed, .jumpBackIn])
        XCTAssertFalse(visible.contains(.favorites))
    }

    /// Defaults (both empty) show every shelf in catalog order.
    func testVisibleOrderWithDefaultsShowsEverything() {
        let visible = HomeSectionLayout.visibleOrder(order: "", hidden: "")
        XCTAssertEqual(visible, HomeSection.allCases)
    }

    /// Hiding every section yields an empty visible list (a valid, if bare,
    /// Home — the header CTAs still render).
    func testVisibleOrderHidingAllYieldsEmpty() {
        let hidden = HomeSectionLayout.encodeHidden(Set(HomeSection.allCases))
        XCTAssertTrue(HomeSectionLayout.visibleOrder(order: "", hidden: hidden).isEmpty)
    }

    // MARK: - Move

    /// Moving the last shelf to the front mirrors SwiftUI's `.onMove` semantics.
    func testApplyingMoveReordersDisplayed() {
        let next = HomeSectionLayout.applyingMove(
            displayed: [.recentlyPlayed, .jumpBackIn, .favorites],
            source: IndexSet(integer: 2),
            destination: 0
        )
        XCTAssertEqual(next, [.favorites, .recentlyPlayed, .jumpBackIn])
    }

    // MARK: - togglingHidden

    func testTogglingHiddenAddsThenRemoves() {
        let added = HomeSectionLayout.togglingHidden(.favorites, in: [])
        XCTAssertEqual(added, [.favorites])
        let removed = HomeSectionLayout.togglingHidden(.favorites, in: added)
        XCTAssertTrue(removed.isEmpty)
    }
}
