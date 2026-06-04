import XCTest

@testable import Lyrebird

/// Coverage for the audit fixes to `ServerUnreachableBanner`:
///   1. **Accessibility** — the banner must not flatten itself into a single
///      static-text element (`children: .combine` + `.isStaticText`), which
///      folds the Retry Button in and makes the action unreachable by
///      VoiceOver. It must use `children: .contain` so the Button stays a
///      separately focusable, actionable element.
///   2. **Localization** — the user-facing strings must come from the string
///      catalog (`LocalizedStringKey` / `Localizable.xcstrings`) rather than
///      hard-coded English literals, matching the rest of the UI and the
///      sibling `OfflineBanner`.
///
/// SwiftUI exposes no public hook to introspect a `some View`'s accessibility
/// tree or resolved copy headlessly, so the behaviour is verified structurally:
/// the banner source is read via `#filePath` and the catalog source is parsed
/// as JSON. A regression that reintroduces the flatten or the hard-coded
/// strings is caught here rather than in the field.
final class ServerUnreachableBannerTests: XCTestCase {

    // MARK: - Accessibility structure

    /// The Retry Button must remain individually reachable: the banner uses
    /// `children: .contain` and drops the `.combine` flatten + `.isStaticText`
    /// trait that previously made the action unreachable by VoiceOver.
    func testBannerDoesNotFlattenRetryButton() throws {
        let code = try bannerSource()
        XCTAssertTrue(
            code.contains(".accessibilityElement(children: .contain)"),
            "Banner must use children: .contain so the Retry button stays actionable"
        )
        XCTAssertFalse(
            code.contains("children: .combine"),
            "children: .combine flattens the Retry button into inert static text"
        )
        XCTAssertFalse(
            code.contains(".isStaticText"),
            "The banner must not mark itself static text — the Retry button is actionable"
        )
    }

    // MARK: - Localization

    /// The banner's strings must route through the catalog. The message is a
    /// `LocalizedStringKey` (so SwiftUI looks the copy up rather than rendering
    /// a literal), and the source references the catalog keys for the generic
    /// message, the named-host format, and the shared `common.retry` button.
    func testBannerStringsAreLocalized() throws {
        let code = try bannerSource()
        XCTAssertTrue(code.contains("private var message: LocalizedStringKey"),
                      "The banner message must be a LocalizedStringKey, not a raw String literal")
        XCTAssertTrue(code.contains("banner.server_unreachable.generic"),
                      "Generic message must use the catalog key")
        XCTAssertTrue(code.contains("banner.server_unreachable.named \\(host)"),
                      "Named-host message must interpolate the host into the catalog key")
        XCTAssertTrue(code.contains("Text(\"common.retry\")"),
                      "Retry label must reuse the shared common.retry catalog key")
    }

    /// The three catalog keys the banner depends on must exist in the source
    /// `Localizable.xcstrings` with a translated English value, and the named
    /// variant must carry the `%@` host placeholder so the host interpolates.
    func testBannerCatalogKeysExist() throws {
        let strings = try catalogStrings()

        for key in [
            "banner.server_unreachable.generic",
            "banner.server_unreachable.named %@",
            "banner.server_unreachable.retry.a11y",
        ] {
            guard let value = englishValue(strings, key) else {
                XCTFail("Missing catalog key: \(key)")
                continue
            }
            XCTAssertFalse(value.isEmpty, "\(key) must have a non-empty English value")
        }

        // The named variant interpolates the user's host — the placeholder must
        // be present so the host actually appears in the rendered copy.
        let named = englishValue(strings, "banner.server_unreachable.named %@")
        XCTAssertEqual(named?.contains("%@"), true,
                       "Named banner copy must contain the %@ host placeholder")
    }

    // MARK: - Helpers

    private func bannerSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = sourcesRoot()
            .appendingPathComponent("Components/ServerUnreachableBanner.swift")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read ServerUnreachableBanner.swift at \(url.path)", file: file, line: line)
            return ""
        }
        return text
    }

    /// Parses the source `Localizable.xcstrings` and returns its `strings` map.
    private func catalogStrings(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = sourcesRoot()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("Could not read Localizable.xcstrings at \(url.path)", file: file, line: line)
            return [:]
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    /// Digs the English `stringUnit` value out of an `.xcstrings` entry.
    private func englishValue(_ strings: [String: Any], _ key: String) -> String? {
        guard
            let entry = strings[key] as? [String: Any],
            let locs = entry["localizations"] as? [String: Any],
            let en = locs["en"] as? [String: Any],
            let unit = en["stringUnit"] as? [String: Any],
            let value = unit["value"] as? String
        else { return nil }
        return value
    }

    /// `macos/Sources/Lyrebird`, resolved relative to this test file via
    /// `#filePath` so the lookup is independent of the runner's working dir.
    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird")
    }
}
