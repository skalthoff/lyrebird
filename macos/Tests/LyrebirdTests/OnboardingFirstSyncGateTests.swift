import XCTest

@testable import Lyrebird

/// Coverage for `FirstSyncGate` — the decision that unlocks onboarding's
/// "Continue to Home" CTA (#293).
///
/// The regression this guards against: the CTA used to unlock purely from a
/// hard-coded cosmetic timer, so a user whose library failed to load (or never
/// started loading) could be sent straight into an empty Home. The gate is now
/// driven exclusively by real `AppModel` signals; these tests pin that contract
/// so a future edit can't quietly reintroduce the timer-only behaviour.
final class OnboardingFirstSyncGateTests: XCTestCase {

    // MARK: - The load hasn't finished yet

    func testClosedWhileLoadStillInFlight() {
        // No matter how full the cosmetic bar looks, the CTA stays closed until
        // the initial load actually finishes. `finishedLoading: false` models
        // "fetch in flight".
        XCTAssertFalse(
            FirstSyncGate.isReady(
                finishedLoading: false,
                hasError: false,
                hasAnyData: true,
                librarySyncRatio: 1.0,
                serverReportsEmptyLibrary: false
            ),
            "CTA must not unlock before the initial library load finishes"
        )
    }

    func testClosedBeforeLoadStartsEvenIfTotalsLookEmpty() {
        // Pre-load render: nothing loaded, totals unresolved (so they read as
        // zero). This must NOT be mistaken for a finished empty-library load —
        // `finishedLoading` is the guard.
        XCTAssertFalse(
            FirstSyncGate.isReady(
                finishedLoading: false,
                hasError: false,
                hasAnyData: false,
                librarySyncRatio: 0.0,
                serverReportsEmptyLibrary: true
            ),
            "an unresolved (pre-load) empty-looking state must keep the CTA closed"
        )
    }

    // MARK: - Failures

    func testClosedOnErrorEvenWithData() {
        // A partial failure that still produced some data must not silently
        // wave the user through — the error needs surfacing first.
        XCTAssertFalse(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: true,
                hasAnyData: true,
                librarySyncRatio: 1.0,
                serverReportsEmptyLibrary: false
            ),
            "an errored load must keep the CTA closed regardless of partial data"
        )
    }

    func testClosedOnErrorWithNoData() {
        XCTAssertFalse(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: true,
                hasAnyData: false,
                librarySyncRatio: 0.0,
                serverReportsEmptyLibrary: false
            ),
            "a failed load with no data is the empty-library trap; CTA stays closed"
        )
    }

    // MARK: - Large library (more than one page)

    func testOpensForLargeLibraryViaDataEvenBelowThreshold() {
        // The real server has ~20k albums. The initial page is ~100 of each, so
        // the ratio sits far below 0.8 forever. The CTA must still unlock once
        // the first page landed without error — Home paginates on scroll.
        let ratio = Double(300) / Double(24_000)  // ≈ 0.0125
        XCTAssertLessThan(ratio, FirstSyncGate.readyThreshold)
        XCTAssertTrue(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: false,
                hasAnyData: true,
                librarySyncRatio: ratio,
                serverReportsEmptyLibrary: false
            ),
            "a large library must unlock on first-page data, not on the 0.8 ratio"
        )
    }

    // MARK: - Small library (fits in one page)

    func testOpensForSmallLibraryViaThreshold() {
        // A library small enough that the first page is the whole thing crosses
        // the 0.8 ratio. Unlock via the threshold branch.
        XCTAssertTrue(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: false,
                hasAnyData: true,
                librarySyncRatio: 1.0,
                serverReportsEmptyLibrary: false
            ),
            "a fully-loaded small library must unlock the CTA"
        )
    }

    func testThresholdIsInclusiveAtExactly80Percent() {
        XCTAssertTrue(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: false,
                hasAnyData: false,
                librarySyncRatio: FirstSyncGate.readyThreshold,
                serverReportsEmptyLibrary: false
            ),
            "the 0.8 threshold must be inclusive"
        )
    }

    // MARK: - Genuinely empty server

    func testOpensForGenuinelyEmptyServerAfterLoad() {
        // A brand-new server with nothing in it: the load finished, no error,
        // no data, totals all zero. There's nothing to wait for, so the user
        // shouldn't be stranded on the sync screen — unlock.
        XCTAssertTrue(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: false,
                hasAnyData: false,
                librarySyncRatio: 0.0,
                serverReportsEmptyLibrary: true
            ),
            "a finished, error-free, genuinely-empty library must unlock the CTA"
        )
    }

    func testClosedWhenLoadedButNothingYetAndServerNotEmpty() {
        // Defensive: load reported finished, but we somehow hold no data and the
        // server is NOT empty (totals non-zero) and the ratio is below
        // threshold. Treat as not-ready rather than risk an empty Home.
        XCTAssertFalse(
            FirstSyncGate.isReady(
                finishedLoading: true,
                hasError: false,
                hasAnyData: false,
                librarySyncRatio: 0.1,
                serverReportsEmptyLibrary: false
            ),
            "finished-but-empty against a non-empty server must keep the CTA closed"
        )
    }

    // MARK: - Threshold constant

    func testReadyThresholdMatchesSpec() {
        // The spec says the CTA activates "when sync crosses 80%". Pin the
        // constant so a drift is a deliberate, test-breaking change.
        XCTAssertEqual(FirstSyncGate.readyThreshold, 0.8, accuracy: 0.0001)
    }
}
