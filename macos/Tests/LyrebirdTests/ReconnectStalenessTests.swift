import XCTest

@testable import Lyrebird

/// Coverage for `AppModel.reconnectResultIsStale`, the guard that stops a
/// wake-from-sleep reconnect probe from grafting stale-server results onto a
/// session the user switched to while the (off-main, possibly slow) probe was
/// in flight. The probe snapshots `(url, token)` before suspending; this
/// predicate decides whether the resolved success may apply.
final class ReconnectStalenessTests: XCTestCase {

    private let url = "https://music.example.com"
    private let token = "tok-original"

    /// Unchanged session context: the probe's success applies.
    func testUnchangedContextIsNotStale() {
        XCTAssertFalse(
            AppModel.reconnectResultIsStale(
                probedURL: url,
                probedToken: token,
                currentURL: url,
                currentToken: token,
                authExpired: false
            )
        )
    }

    /// User switched servers mid-probe: drop the result.
    func testServerSwitchIsStale() {
        XCTAssertTrue(
            AppModel.reconnectResultIsStale(
                probedURL: url,
                probedToken: token,
                currentURL: "https://other.example.com",
                currentToken: token,
                authExpired: false
            )
        )
    }

    /// Re-auth / different account rotated the token mid-probe: drop the result.
    func testTokenRotationIsStale() {
        XCTAssertTrue(
            AppModel.reconnectResultIsStale(
                probedURL: url,
                probedToken: token,
                currentURL: url,
                currentToken: "tok-rotated",
                authExpired: false
            )
        )
    }

    /// Signed out mid-probe (no live session → nil token): drop the result.
    func testSignedOutIsStale() {
        XCTAssertTrue(
            AppModel.reconnectResultIsStale(
                probedURL: url,
                probedToken: token,
                currentURL: url,
                currentToken: nil,
                authExpired: false
            )
        )
    }

    /// Session marked auth-expired while the probe ran: drop the result so we
    /// don't fire authenticated refreshes against a dead token.
    func testAuthExpiredIsStale() {
        XCTAssertTrue(
            AppModel.reconnectResultIsStale(
                probedURL: url,
                probedToken: token,
                currentURL: url,
                currentToken: token,
                authExpired: true
            )
        )
    }
}
