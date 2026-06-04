import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the first-run feature tour (#113):
///
/// 1. The static step catalog (`FeatureTour.steps`) — count, uniqueness, and
///    the right-click-has-no-shortcut / everything-else-does invariant the
///    overlay's chord pill relies on.
/// 2. The seen-persistence wrapper (`FeatureTourSeenStore`) — first read is
///    `false`, `markSeen()` flips and persists it, `reset()` clears it.
///
/// The persistence assertions run against an isolated `UserDefaults` suite so
/// they never touch the real app's preferences — the same isolation pattern
/// `MiniPlayerStateTests` uses for the mini-player always-on-top flag.
final class FeatureTourTests: XCTestCase {

    // MARK: - Step catalog

    func testCatalogHasThreeToFourSteps() {
        // Spec calls for a "3-4 step" tour. Guard both ends so a future edit
        // can't silently grow it into a slideshow or shrink it to nothing.
        let count = FeatureTour.steps.count
        XCTAssertGreaterThanOrEqual(count, 3, "tour should have at least 3 steps")
        XCTAssertLessThanOrEqual(count, 4, "tour should have at most 4 steps")
    }

    func testStepIDsAreUnique() {
        let ids = FeatureTour.steps.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate step id in tour catalog")
    }

    func testCatalogCoversTheFourAdvertisedFeatures() {
        // The issue names four features: right-click options, Space play/pause,
        // ⌘F search, and the mini player. Assert each has a card so a reorder
        // or rename can't quietly drop one.
        let ids = Set(FeatureTour.steps.map(\.id))
        XCTAssertEqual(
            ids,
            ["right_click", "space_play_pause", "search", "mini_player"],
            "tour must cover exactly the four advertised features"
        )
    }

    func testEveryStepHasSymbolAndTitleKey() {
        for step in FeatureTour.steps {
            XCTAssertFalse(step.symbol.isEmpty, "empty SF Symbol for \(step.id)")
            XCTAssertFalse(
                step.titleKeyString.isEmpty,
                "empty title key for \(step.id)"
            )
            // The raw title key and the LocalizedStringKey-backing string must
            // agree, mirroring the AppShortcuts nameKeyString/nameKey split.
            XCTAssertEqual(step.titleKey, LocalizedStringKey(step.titleKeyString))
        }
    }

    func testOnlyTheRightClickStepLacksAShortcutPill() {
        // The overlay only renders the chord pill when `shortcut != nil`. The
        // right-click step is gesture-driven (no key equivalent), so it's the
        // sole step that should omit the pill; the keyboard-driven steps must
        // all carry one.
        for step in FeatureTour.steps {
            if step.id == "right_click" {
                XCTAssertNil(step.shortcut, "right-click step should not show a chord pill")
            } else {
                XCTAssertNotNil(step.shortcut, "\(step.id) should advertise a chord")
                XCTAssertFalse(step.shortcut!.isEmpty, "\(step.id) chord is empty")
            }
        }
    }

    // MARK: - Seen-persistence

    /// A throwaway `UserDefaults` suite, wiped on every test so reads start
    /// from a known-clean slate and writes never leak into the standard domain.
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "FeatureTourTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFreshStoreReportsNotSeen() {
        let store = FeatureTourSeenStore(defaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasSeen, "a fresh install must show the tour on first run")
    }

    func testMarkSeenFlipsAndPersists() {
        let defaults = makeIsolatedDefaults()
        let store = FeatureTourSeenStore(defaults: defaults)

        store.markSeen()
        XCTAssertTrue(store.hasSeen, "marking seen must flip the flag")
        XCTAssertTrue(
            defaults.bool(forKey: FeatureTourSeenStore.seenKey),
            "the seen flag must persist so the tour doesn't reappear next launch"
        )

        // A second store reading the same domain observes the persisted value —
        // i.e. the next launch (a fresh store) won't re-show the tour.
        let nextLaunch = FeatureTourSeenStore(defaults: defaults)
        XCTAssertTrue(nextLaunch.hasSeen, "the persisted flag must survive a fresh store")
    }

    func testMarkSeenIsIdempotent() {
        let store = FeatureTourSeenStore(defaults: makeIsolatedDefaults())
        store.markSeen()
        store.markSeen()
        XCTAssertTrue(store.hasSeen, "marking seen twice stays seen")
    }

    func testResetClearsTheFlag() {
        let defaults = makeIsolatedDefaults()
        let store = FeatureTourSeenStore(defaults: defaults)

        store.markSeen()
        XCTAssertTrue(store.hasSeen)

        store.reset()
        XCTAssertFalse(store.hasSeen, "reset must clear the seen flag")
        XCTAssertFalse(
            defaults.bool(forKey: FeatureTourSeenStore.seenKey),
            "reset must clear the persisted value too"
        )
    }

    /// The store and the `MainShell` `@AppStorage` read/write the same on-disk
    /// key. Guard the constant so a rename (which would re-show the tour to
    /// every existing user, and desync the store from the menu/overlay) is a
    /// deliberate, test-breaking change rather than a silent one.
    func testSeenKeyIsStable() {
        XCTAssertEqual(FeatureTourSeenStore.seenKey, "tour.firstRunSeen")
    }
}
