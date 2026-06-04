import XCTest
@testable import Lyrebird
@testable import LyrebirdAudio

/// Coverage for the pure ReplayGain / volume-normalization logic behind #42:
/// the dB→linear conversion, tag parsing across the Vorbis / ID3 / iTunes
/// spellings, the track/album fallback chain, the `iTunNORM` fallback, and the
/// clamping that keeps a garbage tag from blowing up the output level. These
/// are deliberately `AVAsset`-free and network-free — `ReplayGain.gains(for:)`
/// is the only impure entry point and it just funnels metadata pairs into
/// `parseGains`, which is exercised here directly.
///
/// Also covers the `AppModel`↔engine raw-value bridge so the persisted
/// `NormalizationMode` maps onto the engine's `ReplayGainMode` without drift.
final class ReplayGainTests: XCTestCase {

    // MARK: - dB ↔ linear

    func testLinearGainZeroDbIsUnity() {
        XCTAssertEqual(ReplayGain.linearGain(fromDb: 0), 1.0, accuracy: 1e-6)
    }

    func testLinearGainKnownPoints() {
        // -6 dB ≈ 0.5012, +6 dB ≈ 1.9953, -20 dB = 0.1, +20 dB = 10.
        XCTAssertEqual(ReplayGain.linearGain(fromDb: -6), 0.5012, accuracy: 1e-3)
        XCTAssertEqual(ReplayGain.linearGain(fromDb: 6), 1.9953, accuracy: 1e-3)
        XCTAssertEqual(ReplayGain.linearGain(fromDb: -20), 0.1, accuracy: 1e-5)
        XCTAssertEqual(ReplayGain.linearGain(fromDb: 20), 10.0, accuracy: 1e-4)
    }

    func testLinearGainIsMonotonic() {
        XCTAssertLessThan(ReplayGain.linearGain(fromDb: -3), ReplayGain.linearGain(fromDb: 0))
        XCTAssertLessThan(ReplayGain.linearGain(fromDb: 0), ReplayGain.linearGain(fromDb: 3))
    }

    // MARK: - dB string parsing

    func testParseGainDbWithUnitSuffix() {
        XCTAssertEqual(ReplayGain.parseGainDb("-7.60 dB") ?? .nan, -7.60, accuracy: 1e-9)
    }

    func testParseGainDbNoSpaceBeforeUnit() {
        XCTAssertEqual(ReplayGain.parseGainDb("-7.60dB") ?? .nan, -7.60, accuracy: 1e-9)
    }

    func testParseGainDbBareNumber() {
        XCTAssertEqual(ReplayGain.parseGainDb("3.21") ?? .nan, 3.21, accuracy: 1e-9)
    }

    func testParseGainDbExplicitPlusSign() {
        XCTAssertEqual(ReplayGain.parseGainDb("+3 dB") ?? .nan, 3.0, accuracy: 1e-9)
    }

    func testParseGainDbLeadingWhitespace() {
        XCTAssertEqual(ReplayGain.parseGainDb("  -2.5 dB") ?? .nan, -2.5, accuracy: 1e-9)
    }

    func testParseGainDbRejectsNonNumeric() {
        XCTAssertNil(ReplayGain.parseGainDb("dB"))
        XCTAssertNil(ReplayGain.parseGainDb(""))
        XCTAssertNil(ReplayGain.parseGainDb("   "))
        XCTAssertNil(ReplayGain.parseGainDb("loud"))
    }

    // MARK: - Tag parsing (key spellings)

    func testParseGainsVorbisUppercase() {
        let gains = ReplayGain.parseGains(from: [
            (key: "REPLAYGAIN_TRACK_GAIN", value: "-7.60 dB"),
            (key: "REPLAYGAIN_ALBUM_GAIN", value: "-5.40 dB"),
        ])
        XCTAssertEqual(gains.trackGainDb ?? .nan, -7.60, accuracy: 1e-9)
        XCTAssertEqual(gains.albumGainDb ?? .nan, -5.40, accuracy: 1e-9)
        XCTAssertNil(gains.iTunNormDb)
        XCTAssertFalse(gains.isEmpty)
    }

    func testParseGainsVorbisLowercase() {
        let gains = ReplayGain.parseGains(from: [
            (key: "replaygain_track_gain", value: "+2.00 dB"),
        ])
        XCTAssertEqual(gains.trackGainDb ?? .nan, 2.0, accuracy: 1e-9)
    }

    func testParseGainsITunesNamespacePrefixStripped() {
        // AVFoundation prepends `com.apple.iTunes.` to iTunes-atom keys.
        let gains = ReplayGain.parseGains(from: [
            (key: "com.apple.iTunes.replaygain_track_gain", value: "-3.10 dB"),
            (key: "com.apple.iTunes.REPLAYGAIN_ALBUM_GAIN", value: "-1.00 dB"),
        ])
        XCTAssertEqual(gains.trackGainDb ?? .nan, -3.10, accuracy: 1e-9)
        XCTAssertEqual(gains.albumGainDb ?? .nan, -1.00, accuracy: 1e-9)
    }

    func testParseGainsIgnoresUnrelatedKeys() {
        let gains = ReplayGain.parseGains(from: [
            (key: "TITLE", value: "Some Song"),
            (key: "REPLAYGAIN_TRACK_PEAK", value: "0.98"),  // peak, not gain
            (key: "ARTIST", value: "Someone"),
        ])
        XCTAssertTrue(gains.isEmpty)
    }

    func testParseGainsEmptyInput() {
        let gains = ReplayGain.parseGains(from: [(key: String, value: String)]())
        XCTAssertTrue(gains.isEmpty)
        XCTAssertNil(gains.trackGainDb)
        XCTAssertNil(gains.albumGainDb)
        XCTAssertNil(gains.iTunNormDb)
    }

    // MARK: - iTunNORM fallback

    func testITunNormParsesVolumeBases() {
        // 1000 (hex 0x3E8) ≈ 0 dB. A value of 2000 (0x7D0) is twice as loud →
        // -10*log10(2) ≈ -3.01 dB of attenuation. Both base pairs read 2000.
        let db = ReplayGain.iTunNormDb(from: "000007D0 000007D0 000007D0 000007D0")
        XCTAssertNotNil(db)
        XCTAssertEqual(db ?? .nan, -3.0103, accuracy: 1e-3)
    }

    func testITunNormPicksLoudestChannel() {
        // Left = 0x7D0 (2000 → -3.01 dB), right = 0x3E8 (1000 → 0 dB). The
        // louder channel (more-negative correction) wins so a loud track is
        // actually attenuated rather than left hot: -3.01 dB.
        let db = ReplayGain.iTunNormDb(from: "000007D0 000003E8")
        XCTAssertEqual(db ?? .nan, -3.0103, accuracy: 1e-3)
    }

    func testITunNormConsidersSecondBasePair() {
        // First pair is quiet (1000/1000 → 0 dB); the second pair is hot
        // (4000 → -6.02 dB). The loudest channel across BOTH pairs wins, so the
        // second (often more reliable) pair is not ignored.
        let db = ReplayGain.iTunNormDb(from: "000003E8 000003E8 00000FA0 00000FA0")
        XCTAssertEqual(db ?? .nan, -6.0206, accuracy: 1e-3)
    }

    func testITunNormFallsBackToSecondPairWhenFirstIsZero() {
        // First pair reads zero (unmeasured); the second pair carries the real
        // measurement (2000 → -3.01 dB). Reading both pairs means we don't give
        // up just because fields 0/1 are 0.
        let db = ReplayGain.iTunNormDb(from: "00000000 00000000 000007D0 000007D0")
        XCTAssertEqual(db ?? .nan, -3.0103, accuracy: 1e-3)
    }

    func testITunNormRejectsMalformed() {
        XCTAssertNil(ReplayGain.iTunNormDb(from: ""))
        XCTAssertNil(ReplayGain.iTunNormDb(from: "000003E8"))          // only one field
        XCTAssertNil(ReplayGain.iTunNormDb(from: "00000000 00000000")) // both zero
        XCTAssertNil(ReplayGain.iTunNormDb(from: "00000000 00000000 00000000 00000000")) // all four zero
        XCTAssertNil(ReplayGain.iTunNormDb(from: "ZZ YY"))             // non-hex
    }

    func testParseGainsITunNorm() {
        let gains = ReplayGain.parseGains(from: [
            (key: "com.apple.iTunes.iTunNORM", value: " 000007D0 000007D0 00000000 00000000"),
        ])
        XCTAssertNil(gains.trackGainDb)
        XCTAssertNil(gains.albumGainDb)
        XCTAssertEqual(gains.iTunNormDb ?? .nan, -3.0103, accuracy: 1e-3)
    }

    // MARK: - replayGainDb mode selection + fallbacks

    func testTrackModePrefersTrackGain() {
        let gains = ReplayGain.Gains(trackGainDb: -7, albumGainDb: -5)
        XCTAssertEqual(ReplayGain.replayGainDb(mode: .track, gains: gains), -7)
    }

    func testTrackModeFallsBackToITunNorm() {
        let gains = ReplayGain.Gains(iTunNormDb: -2)
        XCTAssertEqual(ReplayGain.replayGainDb(mode: .track, gains: gains), -2)
    }

    func testAlbumModePrefersAlbumGain() {
        let gains = ReplayGain.Gains(trackGainDb: -7, albumGainDb: -5)
        XCTAssertEqual(ReplayGain.replayGainDb(mode: .album, gains: gains), -5)
    }

    func testAlbumModeFallsBackToTrackGain() {
        // No album gain tagged — album mode still normalizes off the track gain.
        let gains = ReplayGain.Gains(trackGainDb: -7)
        XCTAssertEqual(ReplayGain.replayGainDb(mode: .album, gains: gains), -7)
    }

    func testAlbumModeFallsBackToITunNormWhenNoReplayGain() {
        let gains = ReplayGain.Gains(iTunNormDb: -1.5)
        XCTAssertEqual(ReplayGain.replayGainDb(mode: .album, gains: gains), -1.5)
    }

    func testOffModeNeverResolvesGain() {
        let gains = ReplayGain.Gains(trackGainDb: -7, albumGainDb: -5, iTunNormDb: -2)
        XCTAssertNil(ReplayGain.replayGainDb(mode: .off, gains: gains))
    }

    func testEmptyGainsResolveNil() {
        let gains = ReplayGain.Gains()
        XCTAssertNil(ReplayGain.replayGainDb(mode: .track, gains: gains))
        XCTAssertNil(ReplayGain.replayGainDb(mode: .album, gains: gains))
    }

    // MARK: - linearVolume (the value the engine hands to setVolume)

    func testLinearVolumeOffIsNoOp() {
        let gains = ReplayGain.Gains(trackGainDb: -6)
        // Off must return nil — the engine treats nil as "leave the level
        // alone" and never touches volume.
        XCTAssertNil(ReplayGain.linearVolume(mode: .off, gains: gains))
    }

    func testLinearVolumeUntaggedIsNoOp() {
        // Mode is on, but the track carries no usable loudness tag → nil so the
        // engine plays the stream at its natural volume rather than guessing.
        XCTAssertNil(ReplayGain.linearVolume(mode: .track, gains: ReplayGain.Gains()))
    }

    func testLinearVolumeAppliesTrackGain() {
        let gains = ReplayGain.Gains(trackGainDb: -6)
        let v = ReplayGain.linearVolume(mode: .track, gains: gains)
        XCTAssertNotNil(v)
        XCTAssertEqual(v ?? .nan, 0.5012, accuracy: 1e-3)
    }

    func testLinearVolumeAddsPreGain() {
        // -6 dB track gain + +6 dB pre-gain = 0 dB total = unity.
        let gains = ReplayGain.Gains(trackGainDb: -6)
        let v = ReplayGain.linearVolume(mode: .track, gains: gains, preGainDb: 6)
        XCTAssertEqual(v ?? .nan, 1.0, accuracy: 1e-4)
    }

    func testLinearVolumeClampsRunawayPositiveGain() {
        // A mis-scanned +60 dB tag must clamp to +maxAbsGainDb, not 1000x.
        let gains = ReplayGain.Gains(trackGainDb: 60)
        let v = ReplayGain.linearVolume(mode: .track, gains: gains)
        let ceiling = ReplayGain.linearGain(fromDb: ReplayGain.maxAbsGainDb)
        XCTAssertEqual(v ?? .nan, ceiling, accuracy: 1e-4)
    }

    func testLinearVolumeClampsRunawayNegativeGain() {
        let gains = ReplayGain.Gains(trackGainDb: -60)
        let v = ReplayGain.linearVolume(mode: .track, gains: gains)
        let floorValue = ReplayGain.linearGain(fromDb: -ReplayGain.maxAbsGainDb)
        XCTAssertEqual(v ?? .nan, floorValue, accuracy: 1e-4)
    }

    func testLinearVolumeClampIncludesPreGain() {
        // +10 dB tag + +10 dB pre-gain = +20 dB requested, clamped to the ceiling.
        let gains = ReplayGain.Gains(trackGainDb: 10)
        let v = ReplayGain.linearVolume(mode: .track, gains: gains, preGainDb: 10)
        let ceiling = ReplayGain.linearGain(fromDb: ReplayGain.maxAbsGainDb)
        XCTAssertEqual(v ?? .nan, ceiling, accuracy: 1e-4)
    }

    // MARK: - AppModel ↔ engine raw-value bridge

    func testNormalizationModeBridgeRoundTrips() {
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: "off"), .off)
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: "track"), .track)
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: "album"), .album)
    }

    func testNormalizationModeBridgeDefaultsToOff() {
        // A nil (never-written) key or a stale/unknown raw value falls back to
        // .off so a missing preference never silently alters volume.
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: nil), .off)
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: ""), .off)
        XCTAssertEqual(AppModel.normalizationMode(forStoredValue: "bogus"), .off)
    }

    func testNormalizationModeBridgeMatchesAppEnumRawValues() {
        // Guard against the two enums drifting apart: every NormalizationMode
        // raw value must map to the same-named ReplayGainMode.
        for mode in NormalizationMode.allCases {
            let bridged = AppModel.normalizationMode(forStoredValue: mode.rawValue)
            XCTAssertEqual(bridged.rawValue, mode.rawValue)
        }
    }
}
