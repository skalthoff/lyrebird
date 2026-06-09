import XCTest

@testable import Lyrebird

/// Coverage for the Quick Connect + device-name feature (#202).
///
/// Three layers:
///
/// 1. **QR rendering.** `QuickConnectSheet.qrImage(for:)` must turn a code into
///    a non-empty `NSImage` (the QR is the primary affordance in the sheet).
/// 2. **Device-name default.** `AppModel.defaultDeviceName()` must never return
///    an empty string, since it seeds the `Device` auth header.
/// 3. **Catalog sync.** Every `login.quick_connect.*` / `login.device_name.*`
///    key the UI references must exist in `Localizable.xcstrings` with a
///    translated English value — the catalog isn't bundled into the test
///    binary, so it's read off disk (same idiom as `CountStringsTests`).
final class QuickConnectTests: XCTestCase {

    // MARK: - QR rendering

    func testQRImageRendersNonEmptyForCode() {
        let image = QuickConnectSheet.qrImage(for: "639443")
        let unwrapped = try? XCTUnwrap(image)
        XCTAssertNotNil(unwrapped, "a 6-digit code should produce a QR image")
        if let image {
            XCTAssertGreaterThan(image.size.width, 0, "QR image must have a positive width")
            XCTAssertGreaterThan(image.size.height, 0, "QR image must have a positive height")
        }
    }

    func testQRImageHandlesEmptyStringWithoutCrashing() {
        // CoreImage's QR generator accepts empty input; we only require that the
        // helper returns cleanly (nil or an image) rather than trapping.
        _ = QuickConnectSheet.qrImage(for: "")
    }

    // MARK: - Device-name default

    @MainActor
    func testDefaultDeviceNameIsNonEmpty() {
        let name = AppModel.defaultDeviceName().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(
            name.isEmpty,
            "the host-derived default device name must never be empty — it seeds the Device auth header"
        )
    }

    // MARK: - Catalog sync

    func testQuickConnectAndDeviceNameKeysExistInCatalog() throws {
        let catalog = try loadCatalog()
        let requiredKeys = [
            "login.quick_connect.link",
            "login.quick_connect.a11y_hint",
            "login.quick_connect.title",
            "login.quick_connect.subtitle",
            "login.quick_connect.code_label",
            "login.quick_connect.starting",
            "login.quick_connect.waiting",
            "login.quick_connect.needs_server",
            "login.quick_connect.error",
            "login.quick_connect.retry",
            "login.quick_connect.cancel",
            "login.device_name.help",
            "login.device_name.a11y_label %@",
            "login.device_name.title",
            "login.device_name.subtitle",
            "login.device_name.placeholder",
            "login.device_name.a11y_field",
            "login.device_name.save",
            "login.device_name.cancel",
        ]
        for key in requiredKeys {
            guard let entry = catalog[key] as? [String: Any] else {
                XCTFail("missing catalog key: \(key)")
                continue
            }
            let value = englishValue(entry)
            XCTAssertNotNil(value, "catalog key \(key) has no English value")
            XCTAssertFalse(
                (value ?? "").isEmpty,
                "catalog key \(key) has an empty English value"
            )
        }
    }

    // MARK: - Helpers

    /// The `strings` dictionary of `Localizable.xcstrings`, read off disk
    /// relative to this test file (the catalog isn't bundled into the test
    /// binary — SwiftPM copies resources only into the `.app`).
    private func loadCatalog(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let target = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: target)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let strings = json?["strings"] as? [String: Any] else {
            XCTFail("Could not parse strings table from \(target.path)", file: file, line: line)
            return [:]
        }
        return strings
    }

    /// Pulls `localizations.en.stringUnit.value` out of a decoded catalog entry.
    private func englishValue(_ entry: [String: Any]) -> String? {
        guard
            let localizations = entry["localizations"] as? [String: Any],
            let en = localizations["en"] as? [String: Any],
            let unit = en["stringUnit"] as? [String: Any],
            let value = unit["value"] as? String
        else { return nil }
        return value
    }
}
