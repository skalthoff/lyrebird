import SwiftUI
import XCTest
@testable import Lyrebird

/// Guards the colour-blindness work: every shipped `ThemePreset` must
/// keep its primary and accent legible against the dark surfaces *and* keep
/// the two distinguishable from each other for protanopia / deuteranopia /
/// tritanopia. The numeric targets here mirror the table in
/// `macos/docs/a11y/color-blindness/README.md`.
final class ThemePresetTests: XCTestCase {
    // App surfaces the brand colours sit on (see `Theme.bg` / `Theme.bgAlt`).
    private let bg: UInt32 = 0x0C0622
    private let bgAlt: UInt32 = 0x140B30

    /// WCAG 2.1 §1.4.11 minimum for UI components / graphical objects. The
    /// brand primary/accent are used as large fills (swatch rings, badges,
    /// the now-playing wash), so 3:1 is the governing threshold.
    private let uiComponentMin = 3.0

    func testContrastRatioMatchesKnownPairs() {
        // White on black is the canonical 21:1.
        XCTAssertEqual(Color.contrastRatio(0xFFFFFF, 0x000000), 21.0, accuracy: 0.01)
        // A colour against itself is 1:1.
        XCTAssertEqual(Color.contrastRatio(0x887BFF, 0x887BFF), 1.0, accuracy: 0.001)
        // Symmetric regardless of argument order.
        XCTAssertEqual(
            Color.contrastRatio(0x887BFF, bg),
            Color.contrastRatio(bg, 0x887BFF),
            accuracy: 0.0001
        )
    }

    func testEveryPresetPrimaryAndAccentClearUIContrastOnBothSurfaces() {
        for preset in ThemePreset.allCases {
            for surface in [bg, bgAlt] {
                let p = Color.contrastRatio(preset.primaryHex, surface)
                let a = Color.contrastRatio(preset.accentHex, surface)
                XCTAssertGreaterThanOrEqual(
                    p, uiComponentMin,
                    "\(preset.rawValue) primary contrast \(p) below 3:1 on \(String(format: "#%06X", surface))"
                )
                XCTAssertGreaterThanOrEqual(
                    a, uiComponentMin,
                    "\(preset.rawValue) accent contrast \(a) below 3:1 on \(String(format: "#%06X", surface))"
                )
            }
        }
    }

    /// The two failure modes from the issue: under protanopia and
    /// deuteranopia the purple pair desaturates toward similar grey-browns.
    /// Ocean and Forest must keep their primary/accent *clearly* apart for
    /// every dichromat type. We measure separation as Euclidean distance in
    /// the simulated colour after a Viénot-1999 dichromat projection.
    func testPresetPrimaryAccentStayDistinguishableUnderColorVisionDeficiency() {
        // Minimum Euclidean separation in the dichromat-projected LMS space.
        // Calibrated against the reproducible reference numbers documented in
        // the a11y doc: the shipping Ocean/Forest pairs separate by ≥1928 for
        // every dichromat type, while a naive green/gold pair collapses to
        // ~555 under protanopia. 1000 sits comfortably between the two so a
        // future palette edit that reintroduces a red-green collision fails
        // here instead of in the wild.
        let minSeparation = 1000.0

        for preset in [ThemePreset.ocean, .forest] {
            for kind in ColorVisionDeficiency.allCases {
                let sep = kind.separation(preset.primaryHex, preset.accentHex)
                XCTAssertGreaterThanOrEqual(
                    sep, minSeparation,
                    "\(preset.rawValue) primary/accent separation \(sep) too low under \(kind)"
                )
            }
        }
    }

    func testAccessibilitySuggestionPrefersOcean() {
        // `suggestedForAccessibility()` reads the live system flag; we can't
        // toggle it in a unit test, but we can assert the contract: it returns
        // either nil or the Ocean preset, never an unverified one.
        let suggestion = ThemePreset.suggestedForAccessibility()
        XCTAssertTrue(suggestion == nil || suggestion == .ocean)
    }

    func testAppearanceThemeMapsToVerifiedPreset() {
        XCTAssertEqual(ThemePreset(appearanceTheme: .ocean), .ocean)
        XCTAssertEqual(ThemePreset(appearanceTheme: .forest), .forest)
        // Presets without a verified CVD pair fall back to purple.
        XCTAssertEqual(ThemePreset(appearanceTheme: .sunset), .purple)
        XCTAssertEqual(ThemePreset(appearanceTheme: .peanut), .purple)
        XCTAssertEqual(ThemePreset(appearanceTheme: .purple), .purple)
    }
}

// MARK: - Dichromat simulation (test-only)

/// Viénot-1999 dichromat simulation, scoped to the test target. Mirrors the
/// reference Python used to tune the palettes in the a11y doc so the
/// committed separation numbers are reproducible from Swift.
private enum ColorVisionDeficiency: CaseIterable {
    case protanopia
    case deuteranopia
    case tritanopia

    /// sRGB → LMS (Hunt-Pointer-Estevez normalised to D65, per Viénot 1999).
    private static let rgb2lms: [[Double]] = [
        [17.8824, 43.5161, 4.11935],
        [3.45565, 27.1554, 3.86714],
        [0.0299566, 0.184309, 1.46709],
    ]

    private var projection: [[Double]] {
        switch self {
        case .protanopia:
            return [[0, 2.02344, -2.52581], [0, 1, 0], [0, 0, 1]]
        case .deuteranopia:
            return [[1, 0, 0], [0.494207, 0, 1.24827], [0, 0, 1]]
        case .tritanopia:
            return [[1, 0, 0], [0, 1, 0], [-0.395913, 0.801109, 0]]
        }
    }

    func separation(_ a: UInt32, _ b: UInt32) -> Double {
        let sa = simulate(a)
        let sb = simulate(b)
        let dr = sa.0 - sb.0
        let dg = sa.1 - sb.1
        let db = sa.2 - sb.2
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func simulate(_ hex: UInt32) -> (Double, Double, Double) {
        let rgb = Self.linearRGB(hex)
        let lms = Self.apply(Self.rgb2lms, rgb)
        let proj = Self.apply(projection, lms)
        // Distance is computed in the dichromat-projected LMS-ish space; we
        // don't need to map back to RGB because we only compare magnitudes.
        return proj
    }

    private static func linearRGB(_ hex: UInt32) -> (Double, Double, Double) {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255.0
            let lin = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            return lin * 255.0
        }
        return (channel((hex >> 16) & 0xFF), channel((hex >> 8) & 0xFF), channel(hex & 0xFF))
    }

    private static func apply(_ m: [[Double]], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
            m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
            m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2
        )
    }
}
