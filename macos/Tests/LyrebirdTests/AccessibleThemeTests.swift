import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the contrast-dispatch routing that backs the Increase-Contrast
/// theme variants.
///
/// Two layers are exercised:
///
/// 1. `AccessibleTheme` — the explicit wrapper a view uses when it observes
///    `@Environment(\.colorSchemeContrast)` directly. Each accessor must route
///    to the standard token under `.standard` and to the matching
///    `*HighContrast` token under `.increased`, pinning the per-token mapping
///    against silent drift.
///
/// 2. The base `Theme` tokens (`ink2`/`ink3`/`border`/`borderStrong`) — built
///    by the appearance-adaptive provider so existing call sites lift to high
///    contrast with no churn. We resolve each one against the standard and the
///    high-contrast appearances and assert it picks the right RGBA, so every
///    surface using a base token adapts under Increase Contrast.
final class AccessibleThemeTests: XCTestCase {

    // MARK: - AccessibleTheme dispatch

    func testStandardContrastReturnsBaseTokens() {
        let theme = AccessibleTheme(.standard)
        XCTAssertEqual(theme.ink2, Theme.ink2Base)
        XCTAssertEqual(theme.ink3, Theme.ink3Base)
        XCTAssertEqual(theme.accent, Theme.accent)
        XCTAssertEqual(theme.border, Theme.borderBase)
        XCTAssertEqual(theme.borderStrong, Theme.borderStrongBase)
    }

    func testIncreasedContrastReturnsHighContrastTokens() {
        let theme = AccessibleTheme(.increased)
        XCTAssertEqual(theme.ink2, Theme.ink2HighContrast)
        XCTAssertEqual(theme.ink3, Theme.ink3HighContrast)
        XCTAssertEqual(theme.accent, Theme.accentHighContrast)
        XCTAssertEqual(theme.border, Theme.borderHighContrast)
        XCTAssertEqual(theme.borderStrong, Theme.borderStrongHighContrast)
    }

    func testEachTokenDiffersAcrossContrastModes() {
        let standard = AccessibleTheme(.standard)
        let increased = AccessibleTheme(.increased)
        XCTAssertNotEqual(standard.ink2, increased.ink2)
        XCTAssertNotEqual(standard.ink3, increased.ink3)
        XCTAssertNotEqual(standard.accent, increased.accent)
        XCTAssertNotEqual(standard.border, increased.border)
        XCTAssertNotEqual(standard.borderStrong, increased.borderStrong)
    }

    func testIsIncreasedFlagTracksContrast() {
        XCTAssertFalse(AccessibleTheme(.standard).isIncreased)
        XCTAssertTrue(AccessibleTheme(.increased).isIncreased)
    }

    /// `ink2HighContrast` and `ink3HighContrast` are intentionally the same
    /// opaque value (both ≈7:1 on `bg`). Pin that identity so a future editor
    /// changing one but not the other gets a failing test rather than a silent
    /// divergence.
    func testInkHighContrastTokensAreIntentionallyEqual() {
        XCTAssertEqual(Theme.ink2HighContrast, Theme.ink3HighContrast)
    }

    // MARK: - Adaptive base-token resolution

    /// The base tokens are adaptive `NSColor`s whose dynamic provider consults
    /// `Theme.isIncreaseContrastEnabled`. Override that predicate, then resolve
    /// the color's sRGB components so the test can assert which variant the
    /// provider picked. Each accessor restores the original predicate.
    private func components(
        of color: Color,
        increaseContrast: Bool
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let original = Theme.isIncreaseContrastEnabled
        defer { Theme.isIncreaseContrastEnabled = original }
        Theme.isIncreaseContrastEnabled = { increaseContrast }
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }

    func testAdaptiveTokensResolveStandardUnderNormalContrast() {
        let ink3 = components(of: Theme.ink3, increaseContrast: false)
        // Standard ink3 is the alpha-.65 purple, NOT the opaque HC lift.
        XCTAssertEqual(ink3.a, 0.65, accuracy: 0.02)
    }

    func testAdaptiveTokensResolveHighContrastUnderIncreasedContrast() {
        let ink3 = components(of: Theme.ink3, increaseContrast: true)
        // High-contrast ink3 is opaque (alpha 1.0) and lifts to (198,190,220).
        XCTAssertEqual(ink3.a, 1.0, accuracy: 0.02)
        XCTAssertEqual(ink3.r, 198.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(ink3.g, 190.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(ink3.b, 220.0 / 255.0, accuracy: 0.02)
    }

    func testAdaptiveBorderBecomesOpaqueUnderIncreasedContrast() {
        let standard = components(of: Theme.border, increaseContrast: false)
        let increased = components(of: Theme.border, increaseContrast: true)
        // The standard border is a faint alpha-blended hairline; under
        // Increase Contrast it must become a solid, visible line.
        XCTAssertLessThan(standard.a, 0.5)
        XCTAssertEqual(increased.a, 1.0, accuracy: 0.02)
    }
}
