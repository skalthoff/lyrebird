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

    // MARK: - Accent adoption at view call sites (#888)
    //
    // The legibility-critical accent foregrounds (active-track titles, the
    // now-playing equalizer, favorite hearts, the "NOW PLAYING" label, the
    // sidebar active-tab glyphs, prominent buttons) now read
    // `@Environment(\.accessibleTheme).accent` instead of the static
    // `Theme.accent`. These tests pin the two invariants that swap relies on:
    // (1) the accessor routes to the right hex per contrast mode, and
    // (2) the lift is load-bearing — the standard accent fails AA body
    // contrast while the high-contrast accent clears it. Surfaces (`bg`/`bgAlt`)
    // mirror `Theme.bg` / `Theme.bgAlt`.

    private let bg: UInt32 = 0x0C0622
    private let bgAlt: UInt32 = 0x140B30
    /// Standard body accent (`Theme.accent`) and its Increase-Contrast lift
    /// (`Theme.accentHighContrast` == `Theme.accentHot`).
    private let accentHex: UInt32 = 0xCC2F71
    private let accentHotHex: UInt32 = 0xFF066F
    /// WCAG 2.2 §1.4.3 minimum for body text.
    private let bodyTextMin = 4.5

    /// The `colorSchemeContrast`-driven accessor a view binds via
    /// `@Environment(\.accessibleTheme)` must resolve to the static `accent`
    /// under `.standard` and to the brighter `accentHot` lift under
    /// `.increased`. This is the exact value every converted call site now
    /// renders, so the mapping is pinned against silent drift.
    func testAccessibleAccentResolvesPerContrastForCallSites() {
        XCTAssertEqual(AccessibleTheme(.standard).accent, Theme.accent)
        XCTAssertEqual(AccessibleTheme(.increased).accent, Theme.accentHighContrast)
        // The high-contrast variant is intentionally `accentHot`.
        XCTAssertEqual(Theme.accentHighContrast, Theme.accentHot)
        // Standard and increased must differ, or the adoption would be a
        // no-op under Increase Contrast.
        XCTAssertNotEqual(AccessibleTheme(.standard).accent, AccessibleTheme(.increased).accent)
    }

    /// Why the call-site swap matters: the static `Theme.accent` fails the
    /// 4.5:1 body-text threshold on both dark surfaces, while the
    /// high-contrast accent the wrapper substitutes clears it. If a future
    /// palette edit made the base accent already-compliant (or broke the
    /// lift), this test flags that the adoption is no longer load-bearing /
    /// correct.
    func testStandardAccentFailsBodyContrastButHighContrastAccentPasses() {
        for surface in [bg, bgAlt] {
            let standard = Color.contrastRatio(accentHex, surface)
            let lifted = Color.contrastRatio(accentHotHex, surface)
            XCTAssertLessThan(
                standard, bodyTextMin,
                "Standard accent contrast \(standard) unexpectedly clears 4.5:1 on \(String(format: "#%06X", surface)) — accent adoption may no longer be needed"
            )
            XCTAssertGreaterThanOrEqual(
                lifted, bodyTextMin,
                "High-contrast accent contrast \(lifted) below 4.5:1 on \(String(format: "#%06X", surface)) — the lift no longer clears AA body text"
            )
        }
    }

    /// The high-contrast accent must resolve to the documented `accentHot`
    /// RGBA (#FF066F) when the wrapper reports increased contrast, so the
    /// converted foregrounds actually paint the brighter pink rather than
    /// silently falling back to the standard token.
    func testIncreasedAccentResolvesToAccentHotComponents() {
        let rgb = NSColor(AccessibleTheme(.increased).accent)
            .usingColorSpace(.sRGB) ?? NSColor(AccessibleTheme(.increased).accent)
        XCTAssertEqual(rgb.redComponent, Double(0xFF) / 255.0, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, Double(0x06) / 255.0, accuracy: 0.01)
        XCTAssertEqual(rgb.blueComponent, Double(0x6F) / 255.0, accuracy: 0.01)
        XCTAssertEqual(rgb.alphaComponent, 1.0, accuracy: 0.01)
    }
}
