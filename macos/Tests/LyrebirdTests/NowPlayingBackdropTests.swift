import SwiftUI
import XCTest

@testable import Lyrebird

/// #21 — coverage for the Now Playing blurred-artwork backdrop's visibility
/// rule. The backdrop's whole accessibility + fallback contract collapses to
/// one pure predicate — `NowPlayingBackdrop.showsArtworkLayer(reduceTransparency:hasArtwork:)`
/// — so we pin that truth table directly rather than booting a SwiftUI scene
/// (same idiom as `DockTileTests` / `NowPlayingView.nowPlayingArtworkLabel`).
///
/// What it guarantees:
///   * the blurred cover *is* present in the normal case (art available,
///     transparency allowed),
///   * **Reduce Transparency** suppresses the translucent layer so the opaque
///     `AmbientWash` (`Theme.bg` + palette gradient) is the fallback, and
///   * a track with no artwork suppresses the layer too, deferring to the
///     ambient palette wash.
///
/// Plus a guard on the tuned dim/blur constants so an accidental edit that
/// would either stop blurring the cover or blow the dim past opaque (hiding
/// the cover entirely) trips a test.
final class NowPlayingBackdropTests: XCTestCase {

    // MARK: - Visibility truth table

    /// The normal path: there's a cover URL and the user hasn't asked for
    /// reduced transparency, so the immersive blurred backdrop layer renders.
    func testBackdropLayerPresentWhenArtworkAvailable() {
        XCTAssertTrue(
            NowPlayingBackdrop.showsArtworkLayer(
                reduceTransparency: false,
                hasArtwork: true
            ),
            "With artwork and transparency allowed, the blurred backdrop must render"
        )
    }

    /// Reduce-Transparency fallback: the system asks us to drop translucent /
    /// layered material, so the backdrop suppresses itself and the opaque
    /// `AmbientWash` (`Theme.bg` + palette) carries the background — even when a
    /// cover is available.
    func testReduceTransparencySuppressesBackdropEvenWithArtwork() {
        XCTAssertFalse(
            NowPlayingBackdrop.showsArtworkLayer(
                reduceTransparency: true,
                hasArtwork: true
            ),
            "Reduce Transparency must drop the blurred cover so AmbientWash's flat Theme.bg shows"
        )
    }

    /// No-artwork fallback: an album-less / art-less track has no cover to
    /// blur, so the layer stays hidden and the ambient palette gradient is the
    /// background.
    func testNoArtworkSuppressesBackdrop() {
        XCTAssertFalse(
            NowPlayingBackdrop.showsArtworkLayer(
                reduceTransparency: false,
                hasArtwork: false
            ),
            "Without a cover URL the backdrop must defer to the ambient palette wash"
        )
    }

    /// Both fallbacks at once still resolves to hidden — no accidental
    /// re-enable when neither precondition holds.
    func testReduceTransparencyAndNoArtworkSuppressesBackdrop() {
        XCTAssertFalse(
            NowPlayingBackdrop.showsArtworkLayer(
                reduceTransparency: true,
                hasArtwork: false
            )
        )
    }

    /// The predicate depends on *both* inputs: it is true only when transparency
    /// is allowed AND artwork exists. This exhaustively pins the 2×2 table so a
    /// future refactor can't silently weaken it to depend on a single input.
    func testVisibilityIsConjunctionOfBothInputs() {
        let cases: [(reduceTransparency: Bool, hasArtwork: Bool, expected: Bool)] = [
            (false, false, false),
            (false, true, true),
            (true, false, false),
            (true, true, false),
        ]
        for c in cases {
            XCTAssertEqual(
                NowPlayingBackdrop.showsArtworkLayer(
                    reduceTransparency: c.reduceTransparency,
                    hasArtwork: c.hasArtwork
                ),
                c.expected,
                "reduceTransparency=\(c.reduceTransparency) hasArtwork=\(c.hasArtwork) should be \(c.expected)"
            )
        }
    }

    // MARK: - Tuned constants

    /// The cover must actually be blurred — a backdrop that rendered the cover
    /// sharp would read as a second thumbnail rather than an immersive wash.
    func testBlurRadiusIsSubstantial() {
        XCTAssertGreaterThanOrEqual(
            NowPlayingBackdrop.blurRadius,
            20,
            "The backdrop blur must be heavy enough to dissolve the cover into a wash"
        )
    }

    /// The blurred cover is drawn at reduced opacity so it never competes with
    /// the foreground type — strictly between fully transparent (invisible) and
    /// fully opaque (would dominate the screen).
    func testArtworkOpacityIsDimmedButVisible() {
        XCTAssertGreaterThan(NowPlayingBackdrop.artworkOpacity, 0)
        XCTAssertLessThan(
            NowPlayingBackdrop.artworkOpacity,
            1,
            "The cover is dimmed, not drawn at full strength, so type stays legible"
        )
    }
}
