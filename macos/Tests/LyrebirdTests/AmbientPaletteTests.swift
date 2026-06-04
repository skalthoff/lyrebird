import SwiftUI
import AppKit
import XCTest

@testable import Lyrebird

/// #271 — coverage for `AmbientPalette`'s string codec, the Swift half of the
/// per-album ambient-wash cache. `AppModel` keys an in-memory cache by album
/// id and stores the opaque `"RRGGBB,RRGGBB"` value verbatim; what these tests
/// pin is the *decoder contract* — that a cached string bridges back to the
/// correct `Color` values, and that a malformed / stale entry is rejected so
/// the wash falls back to a fresh sample instead of rendering garbage.
///
/// They cover `init?(encoded:)` parsing, the hex→`Color` mapping (resolved
/// through sRGB components, the same technique `AccessibleThemeTests` uses),
/// `encoded` symmetry, and the full set of rejection cases.
final class AmbientPaletteTests: XCTestCase {

    /// An sRGB byte triple, made `Equatable` so `XCTAssertEqual` can compare a
    /// whole color in one assertion (raw tuples aren't `Equatable`).
    private struct RGB: Equatable {
        let r: Int
        let g: Int
        let b: Int
    }

    /// Resolve a SwiftUI `Color` to its sRGB byte triple so we can assert the
    /// decoded palette landed on the exact channels the hex string encoded.
    private func rgb(_ color: Color) -> RGB {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return RGB(
            r: Int((ns.redComponent * 255).rounded()),
            g: Int((ns.greenComponent * 255).rounded()),
            b: Int((ns.blueComponent * 255).rounded())
        )
    }

    // MARK: - Decode contract

    /// A well-formed cache string decodes, and each half bridges to the exact
    /// `Color` the hex triple names — this is the contract a byte-level
    /// round-trip can't observe (it only proves the bytes survive storage).
    func testDecodesWellFormedStringToCorrectColors() {
        guard let palette = AmbientPalette(encoded: "0C0622,887BFF") else {
            return XCTFail("well-formed palette string must decode")
        }

        let top = rgb(palette.top)
        XCTAssertEqual(top.r, 0x0C)
        XCTAssertEqual(top.g, 0x06)
        XCTAssertEqual(top.b, 0x22)

        let bottom = rgb(palette.bottom)
        XCTAssertEqual(bottom.r, 0x88)
        XCTAssertEqual(bottom.g, 0x7B)
        XCTAssertEqual(bottom.b, 0xFF)
    }

    /// The decoded palette's `top`/`bottom` must match the canonical
    /// `Color(hex:)` constructor for the same triples — i.e. the codec path and
    /// the direct constructor agree, so a cached value renders identically to a
    /// freshly sampled one.
    func testDecodedColorsMatchCanonicalHexInitializer() {
        guard let palette = AmbientPalette(encoded: "140B30,FF066F") else {
            return XCTFail("well-formed palette string must decode")
        }
        XCTAssertEqual(rgb(palette.top), rgb(Color(hex: 0x140B30)))
        XCTAssertEqual(rgb(palette.bottom), rgb(Color(hex: 0xFF066F)))
    }

    /// Pure black / white extremes must survive the decode without channel
    /// truncation or overflow.
    func testDecodesBlackAndWhiteExtremes() {
        guard let palette = AmbientPalette(encoded: "000000,FFFFFF") else {
            return XCTFail("extreme palette string must decode")
        }
        XCTAssertEqual(rgb(palette.top), RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(rgb(palette.bottom), RGB(r: 255, g: 255, b: 255))
    }

    /// `UInt32(_:radix:)` accepts lowercase hex, so a cache entry that was
    /// written (or hand-edited) in lowercase must still decode to the same
    /// colors.
    func testDecodesLowercaseHex() {
        guard let palette = AmbientPalette(encoded: "0c0622,887bff") else {
            return XCTFail("lowercase palette string must decode")
        }
        XCTAssertEqual(rgb(palette.top), RGB(r: 0x0C, g: 0x06, b: 0x22))
        XCTAssertEqual(rgb(palette.bottom), RGB(r: 0x88, g: 0x7B, b: 0xFF))
    }

    // MARK: - encode/decode symmetry

    /// `encoded` re-serializes to the canonical uppercase form, and that form
    /// decodes back to an equal palette — closing the loop the cache relies on.
    func testEncodeDecodeRoundTrip() {
        let original = AmbientPalette(topHex: 0x0C0622, bottomHex: 0x887BFF)
        XCTAssertEqual(original.encoded, "0C0622,887BFF")

        guard let restored = AmbientPalette(encoded: original.encoded) else {
            return XCTFail("re-encoded palette must decode")
        }
        XCTAssertEqual(restored, original)
    }

    /// Decoding a lowercase string then re-encoding yields the canonical
    /// uppercase form, so the cache self-heals casing on re-write.
    func testReEncodeNormalizesCasing() {
        let palette = AmbientPalette(encoded: "0c0622,887bff")
        XCTAssertEqual(palette?.encoded, "0C0622,887BFF")
    }

    // MARK: - Rejection of malformed / stale cache entries

    func testRejectsMalformedStrings() {
        let bad = [
            "",                  // empty
            "0C0622",            // single color, no comma
            "0C0622,887BFF,FF0", // three colors
            "0C0622887BFF",      // missing separator
            "ZZZZZZ,887BFF",     // non-hex in first half
            "0C0622,ZZZZZZ",     // non-hex in second half
            "0C0622,",           // trailing empty half
            ",887BFF",           // leading empty half
            "  0C0622,887BFF",   // stray whitespace breaks hex parse
        ]
        for input in bad {
            XCTAssertNil(
                AmbientPalette(encoded: input),
                "malformed cache entry \"\(input)\" must decode to nil so the wash re-samples"
            )
        }
    }

    /// A value with more than six hex digits per half still *parses* as a
    /// `UInt32` but names a color outside the 0xRRGGBB space; the high bits are
    /// simply ignored by `Color(hex:)`, so we assert the documented masking
    /// behavior rather than a crash. This pins that an over-wide stale entry
    /// degrades gracefully (low 24 bits win) instead of trapping.
    func testOverWideHexMasksToLow24Bits() {
        guard let palette = AmbientPalette(encoded: "FF887BFF,00000000") else {
            return XCTFail("parseable-but-wide hex should still decode")
        }
        // 0xFF887BFF & 0xFFFFFF == 0x887BFF
        XCTAssertEqual(rgb(palette.top), RGB(r: 0x88, g: 0x7B, b: 0xFF))
        XCTAssertEqual(rgb(palette.bottom), RGB(r: 0, g: 0, b: 0))
    }
}
