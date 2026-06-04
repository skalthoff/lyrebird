import XCTest

@testable import Lyrebird

/// Coverage for `LyrebirdErrorPresenter.key(for:)` — the substring routing that
/// maps a flat-error `localizedDescription` onto a banner key.
///
/// Because the core declares `LyrebirdError` as a UniFFI `flat_error`, Swift
/// only sees the rendered `Display` string. These tests construct `NSError`s
/// whose `localizedDescription` mirrors the exact `thiserror` Display text the
/// core emits, and pin the routing for the cases the audit pass fixed:
///
/// - A `429` `RateLimit` renders "rate limited (retry after …)" WITHOUT the
///   "server returned an error:" prefix, so it must match at the top level
///   (previously it fell through to `error.other`).
/// - A `SelfSignedCertificate` renders "… uses a certificate that could not be
///   verified …" and must route to a cert-specific banner (previously there
///   was no certificate branch at all).
final class LyrebirdErrorPresenterTests: XCTestCase {
    /// Helper: an error whose `localizedDescription` is exactly `message`.
    private func error(_ message: String) -> Error {
        NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testRateLimitDisplayRoutesToRateLimitKey() {
        // Matches the core's `RateLimit` Display after the audit fix.
        let withRetry = error("rate limited (retry after 30s)")
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: withRetry), "error.rate_limit")

        let withoutRetry = error("rate limited")
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: withoutRetry), "error.rate_limit")
    }

    func testSelfSignedCertificateRoutesToCertificateKey() {
        // Matches the core's `SelfSignedCertificate` Display.
        let cert = error(
            "the server at 'music.example.com' uses a certificate that could not be verified — it may be self-signed"
        )
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: cert), "error.certificate")
    }

    func testServerRateLimitInsideServerErrorStillRoutesToRateLimit() {
        // A 429 that arrived as `Server { 429, .. }` carries the
        // "server returned an error:" prefix and must still resolve to the
        // rate-limit key (the in-block branch).
        let server = error("server returned an error: 429 slow down")
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: server), "error.rate_limit")
    }

    func testAuthFamilyTakesPriority() {
        // Regression guard: the auth branch is checked first.
        let auth = error("authentication expired — please sign in again")
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: auth), "error.auth.expired")
    }

    func testUnknownErrorFallsThroughToOther() {
        let unknown = error("something totally unrecognized")
        XCTAssertEqual(LyrebirdErrorPresenter.key(for: unknown), "error.other")
    }
}
