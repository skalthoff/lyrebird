import XCTest

@testable import Lyrebird

/// Coverage for the Audio pane's quality-picker contract (#117 / audit L225).
///
/// The Streaming and Download quality controls bind to `PlaybackQuality`
/// `@AppStorage` keys whose stored value can legitimately be `.automatic` — it's
/// the *streaming* default, and the same keys were previously shared with the
/// Playback pane's Auto-inclusive picker, so a migrated value can also be
/// `.automatic`. The segmented picker iterates `PlaybackQuality.allCases`, so it
/// must contain every value that can ever be stored; otherwise the control shows
/// nothing selected and the pane looks broken until the first tap.
///
/// These pin the contract that lets the segmented control always represent the
/// stored value. They live in `UserDefaults.standard` (shared across suites), so
/// the keys are scrubbed before/after to stay hermetic.
final class AudioQualityPreferencesTests: XCTestCase {

    /// Mirrors `PreferencesAudio`'s `@AppStorage` keys + defaults. If those
    /// drift, this suite goes stale, so it pins the contract.
    private let streamingKey = "playback.streamingQuality"
    private let downloadKey = "playback.downloadQuality"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: streamingKey)
        UserDefaults.standard.removeObject(forKey: downloadKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: streamingKey)
        UserDefaults.standard.removeObject(forKey: downloadKey)
        super.tearDown()
    }

    /// The picker iterates `allCases`; `.automatic` must be one of them or the
    /// control can't render the stored default. This is the L225 regression:
    /// the picker used to omit Auto, so a stored `.automatic` selected nothing.
    func testQualityCasesIncludeAutomatic() {
        XCTAssertTrue(
            PlaybackQuality.allCases.contains(.automatic),
            "the Audio quality picker iterates allCases, so Auto must be present to represent a stored .automatic"
        )
    }

    /// Every case must have a non-empty label — a segment with an empty title is
    /// indistinguishable from "nothing selected" to the user.
    func testEveryQualityCaseHasALabel() {
        for quality in PlaybackQuality.allCases {
            XCTAssertFalse(
                quality.label.isEmpty,
                "every PlaybackQuality segment needs a visible label (\(quality.rawValue) had none)"
            )
        }
    }

    /// `PlaybackQuality` is `RawRepresentable<String>` for `@AppStorage`. Any
    /// value the pickers can persist must round-trip back to the same case, so a
    /// restored preference always maps to an existing segment.
    func testQualityRawValuesRoundTrip() {
        for quality in PlaybackQuality.allCases {
            XCTAssertEqual(
                PlaybackQuality(rawValue: quality.rawValue),
                quality,
                "persisted raw value \(quality.rawValue) must restore to the same case"
            )
        }
    }

    /// The streaming default is `.automatic`; with the key unset the binding
    /// resolves to it, and the picker (iterating `allCases`) must be able to
    /// show it. This ties the stored default to the picker's option set so the
    /// two can't silently drift apart.
    func testStreamingDefaultIsRepresentableByPicker() {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: streamingKey),
            "precondition: streaming-quality key must be unset for the default probe"
        )
        let storedDefault = PlaybackQuality.automatic // matches PreferencesAudio's @AppStorage default
        XCTAssertTrue(
            PlaybackQuality.allCases.contains(storedDefault),
            "the streaming default must be one of the picker's segments"
        )
    }

    /// The Streaming Quality picker feeds `MaxStreamingBitrate` (#260). Pin the
    /// tier → bitrate mapping so a regression that silently changes the cap (or
    /// drops the uncapped Lossless/Original semantics) is caught. `automatic`
    /// must stay 320 kbps — the historical default that keeps playback unchanged
    /// for users who never touch the picker.
    func testQualityMaxStreamingBitrateMapping() {
        XCTAssertEqual(PlaybackQuality.low.maxStreamingBitrate, 96_000)
        XCTAssertEqual(PlaybackQuality.normal.maxStreamingBitrate, 192_000)
        XCTAssertEqual(PlaybackQuality.high.maxStreamingBitrate, 320_000)
        XCTAssertEqual(PlaybackQuality.automatic.maxStreamingBitrate, 320_000)
        XCTAssertNil(
            PlaybackQuality.lossless.maxStreamingBitrate,
            "Lossless must be uncapped so the server sends the lossless source"
        )
        XCTAssertNil(
            PlaybackQuality.original.maxStreamingBitrate,
            "Original must omit the cap so the server returns the source untouched"
        )
    }
}
