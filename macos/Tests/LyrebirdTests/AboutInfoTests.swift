import Foundation
import XCTest

@testable import Lyrebird

/// Coverage for `AboutInfo` — the shared, side-effect-free payload behind both
/// the Preferences → About pane and the dedicated About window (#25). Keeping
/// these two surfaces reading from one source is the whole point of the type,
/// so the tests defend the contracts each surface relies on:
///
/// 1. Version / build / copyright read the right Info.plist keys, trim empty
///    values to `nil`, and fall back to a non-blank placeholder when absent —
///    asserted against a fake bundle so no assertion touches `Bundle.main`.
/// 2. `connectedServerHost(from:)` reduces a server URL to its bare host
///    (no scheme / userinfo / port / path / query) and returns `nil` when
///    signed out, matching `DiagnosticBundle.redactServerHost`'s redaction so
///    the screenshot-prone About window never leaks a token or proxy path.
/// 3. The static `credits` catalog is non-empty, fully populated, and has
///    stable unique ids so the About window's `ForEach` can't collide.
final class AboutInfoTests: XCTestCase {

    // MARK: - Test double

    /// In-memory `BundleReading` so version / build / copyright are asserted
    /// without `Bundle.main`. Mirrors `AppBundle`'s empty-string-is-absent
    /// rule: an explicit `""` value reads back as `nil`.
    private struct FakeBundle: AboutInfo.BundleReading {
        var values: [String: String]
        func infoString(for key: String) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            return value
        }
    }

    // MARK: - Identity literals

    func testIdentityLiteralsAreStable() {
        XCTAssertEqual(AboutInfo.appName, "Lyrebird")
        XCTAssertFalse(AboutInfo.tagline.isEmpty)
    }

    // MARK: - Version / build / copyright lookups

    func testVersionAndBuildReadInfoPlistKeys() {
        let bundle = FakeBundle(values: [
            "CFBundleShortVersionString": "2.0.1",
            "CFBundleVersion": "447",
        ])
        XCTAssertEqual(AboutInfo.version(bundle: bundle), "2.0.1")
        XCTAssertEqual(AboutInfo.build(bundle: bundle), "447")
    }

    func testCopyrightReadsHumanReadableKey() {
        let bundle = FakeBundle(values: [
            "NSHumanReadableCopyright": "Copyright © 2026 Skyler Althoff.",
        ])
        XCTAssertEqual(AboutInfo.copyright(bundle: bundle), "Copyright © 2026 Skyler Althoff.")
    }

    func testMissingKeysFallBackToNonBlankPlaceholders() {
        let empty = FakeBundle(values: [:])
        // The placeholders matter: a blank version / build / copyright row in
        // the About window reads as a bug, so each accessor must return
        // something printable rather than "".
        XCTAssertEqual(AboutInfo.version(bundle: empty), "0.0.0 (dev)")
        XCTAssertEqual(AboutInfo.build(bundle: empty), "—")
        XCTAssertFalse(AboutInfo.copyright(bundle: empty).isEmpty)
    }

    func testEmptyStringValuesAreTreatedAsAbsent() {
        // A present-but-empty Info.plist value (seen when running unbundled
        // from Xcode against an unconfigured plist) must fall back rather than
        // render a blank row.
        let blanks = FakeBundle(values: [
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "",
            "NSHumanReadableCopyright": "",
        ])
        XCTAssertEqual(AboutInfo.version(bundle: blanks), "0.0.0 (dev)")
        XCTAssertEqual(AboutInfo.build(bundle: blanks), "—")
        XCTAssertFalse(AboutInfo.copyright(bundle: blanks).isEmpty)
    }

    func testDefaultBundleArgumentResolvesWithoutCrashing() {
        // Exercises the `AppBundle(.main)` default path so the production
        // accessor is covered end-to-end. We don't assert the values (they
        // depend on the test host's plist) — only that they're non-empty,
        // which the placeholder fallbacks guarantee.
        XCTAssertFalse(AboutInfo.version().isEmpty)
        XCTAssertFalse(AboutInfo.build().isEmpty)
        XCTAssertFalse(AboutInfo.copyright().isEmpty)
    }

    // MARK: - Connected-server host redaction

    func testHostStripsSchemePathAndQuery() {
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "https://music.example.com/jellyfin"),
            "music.example.com"
        )
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "http://music.example.com/?x=1"),
            "music.example.com"
        )
    }

    func testHostStripsUserinfoAndPort() {
        // The screenshot-safety contract: basic-auth userinfo, port, and any
        // token query must never survive into the rendered host row.
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "https://user:pw@host.example.com:8443/x?token=abc"),
            "host.example.com"
        )
    }

    func testHostHandlesSchemelessAuthority() {
        // Bare `host[:port][/path]` with no scheme — `URLComponents` parses the
        // whole thing as a path, so the manual fallback must kick in.
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "music.example.com:8096"),
            "music.example.com"
        )
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "music.example.com/jellyfin"),
            "music.example.com"
        )
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "user:pw@bare.example.com:9000"),
            "bare.example.com"
        )
    }

    func testHostSchemelessUserinfoDoesNotLeakPassword() {
        // The whole `user:pw@` userinfo must be dropped even when the password
        // itself contains an `@` — splitting on the first `@` would leak it.
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "admin:p@ssw0rd@host.internal:8443/jf"),
            "host.internal"
        )
    }

    func testHostMalformedSchemelessInputReturnsNil() {
        // Garbage that parses to a space-containing non-host must map to nil so
        // the About row hides rather than render junk.
        XCTAssertNil(AboutInfo.connectedServerHost(from: "ht!tp://weird host/with space"))
        XCTAssertNil(AboutInfo.connectedServerHost(from: "weird host"))
        XCTAssertNil(AboutInfo.connectedServerHost(from: "???"))
    }

    func testHostTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            AboutInfo.connectedServerHost(from: "  https://music.example.com  "),
            "music.example.com"
        )
    }

    func testEmptyOrWhitespaceURLReturnsNil() {
        // The About window hides the server row entirely when signed out, so
        // an empty / blank URL must map to `nil` (not a placeholder string).
        XCTAssertNil(AboutInfo.connectedServerHost(from: ""))
        XCTAssertNil(AboutInfo.connectedServerHost(from: "   "))
        XCTAssertNil(AboutInfo.connectedServerHost(from: "\n\t"))
    }

    /// The host extraction must agree with `DiagnosticBundle.redactServerHost`
    /// on every non-empty input — they document the identical redaction. The
    /// only intentional divergence is the empty case (About → `nil`, the
    /// bundle → `"(not signed in)"`), which is covered separately above.
    func testHostMatchesDiagnosticBundleRedactionForNonEmptyInputs() {
        let inputs = [
            "https://music.example.com/jellyfin",
            "https://user:pw@host.example.com:8443/x?token=abc",
            "music.example.com:8096",
            "http://10.0.0.5:8096/",
            "https://sub.domain.example.org/path/deeper?a=b&c=d",
            // Scheme-less + embedded creds (incl. an `@` inside the password):
            // both redactors must extract the same bare host. (Malformed inputs
            // that yield NO host are the one intentional divergence — About →
            // nil, bundle → "(not signed in)" — so they're asserted separately.)
            "admin:p@ssw0rd@host.internal:8443/jf",
            "user:pw@bare.example.com:9000",
        ]
        for input in inputs {
            XCTAssertEqual(
                AboutInfo.connectedServerHost(from: input),
                DiagnosticBundle.redactServerHost(input),
                "About host extraction diverged from DiagnosticBundle for \(input)"
            )
        }
    }

    // MARK: - Credits catalog

    func testCreditsCatalogIsPopulated() {
        XCTAssertFalse(AboutInfo.credits.isEmpty)
        for credit in AboutInfo.credits {
            XCTAssertFalse(credit.name.isEmpty, "A credit has an empty name")
            XCTAssertFalse(credit.role.isEmpty, "Credit \(credit.name) has an empty role")
            XCTAssertEqual(credit.id, credit.name, "Credit id must derive from its name")
        }
    }

    func testCreditIdsAreUnique() {
        // The About window drives a `ForEach` straight off `credits`, so
        // duplicate ids would silently drop or duplicate rows.
        let ids = AboutInfo.credits.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Credit ids are not unique")
    }
}
