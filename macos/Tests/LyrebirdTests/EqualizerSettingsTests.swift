import AVFoundation
import XCTest

@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Coverage for the 10-band graphic equalizer (#40):
///
///   1. The band layout (count, ISO octave centers) matches what
///      `EngineDSPPipeline` actually configures on its `AVAudioUnitEQ`.
///   2. Gain normalization — clamp to ±12 dB, zero non-finite values,
///      pad/truncate to exactly 10 bands — so no corrupt persisted value can
///      reach the audio node.
///   3. The preset table is well-formed and `activeGains` resolves named
///      presets / Custom / unknown ids correctly.
///   4. `UserDefaults` persistence round-trips, and missing/garbage keys
///      degrade to the shipped default (disabled, Flat).
///   5. `applyEqualizer` drives band gains + bypass flags with the
///      bit-perfect contract: disabled ⇒ all bypassed, and a 0 dB band is
///      bypassed rather than run as a zero-gain filter.
///   6. `AudioEngine` re-applies the stored settings when the pipeline is
///      (re)constructed and pushes live edits onto an existing pipeline.
@MainActor
final class EqualizerSettingsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "eq-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEngine() throws -> AudioEngine {
        let dir = NSTemporaryDirectory() + "lyrebird-eq-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "eq-test"))
        return AudioEngine(core: core)
    }

    // MARK: - 1. Band layout

    func testBandLayoutMatchesPipelineConfiguration() {
        XCTAssertEqual(EqualizerSettings.bandCount, 10)
        XCTAssertEqual(
            EqualizerSettings.bandFrequencies,
            [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        )

        // The model's layout must be the same one the pipeline configures on
        // the real node — index i of a gains array maps to band i.
        let pipeline = EngineDSPPipeline()
        XCTAssertEqual(pipeline.eq.bands.count, EqualizerSettings.bandCount)
        XCTAssertEqual(
            pipeline.eq.bands.map(\.frequency),
            EqualizerSettings.bandFrequencies
        )
    }

    // MARK: - 2. Normalization

    func testNormalizedGainsClampToRange() {
        let normalized = EqualizerSettings.normalizedGains(
            [-30, 30, 12, -12, 5.5, 0, 1, -1, 11.9, -11.9]
        )
        XCTAssertEqual(normalized, [-12, 12, 12, -12, 5.5, 0, 1, -1, 11.9, -11.9])
    }

    func testNormalizedGainsPadAndTruncateToBandCount() {
        XCTAssertEqual(
            EqualizerSettings.normalizedGains([3, -2]),
            [3, -2, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(
            EqualizerSettings.normalizedGains([Float](repeating: 1, count: 14)),
            [Float](repeating: 1, count: 10)
        )
        XCTAssertEqual(
            EqualizerSettings.normalizedGains([]),
            [Float](repeating: 0, count: 10)
        )
    }

    func testNormalizedGainsZeroNonFiniteValues() {
        let normalized = EqualizerSettings.normalizedGains(
            [.nan, .infinity, -.infinity, 4, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(normalized, [0, 0, 0, 4, 0, 0, 0, 0, 0, 0])
    }

    func testInitNormalizesCustomGains() {
        let settings = EqualizerSettings(customGains: [99, -99, .nan])
        XCTAssertEqual(settings.customGains, [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - 3. Presets

    func testPresetTableIsWellFormed() {
        XCTAssertFalse(EqualizerPreset.all.isEmpty)
        for preset in EqualizerPreset.all {
            XCTAssertEqual(
                preset.gains.count, EqualizerSettings.bandCount,
                "\(preset.id) must define a gain per band"
            )
            for gain in preset.gains {
                XCTAssertTrue(
                    EqualizerSettings.gainRange.contains(gain),
                    "\(preset.id) gain \(gain) escapes ±12 dB"
                )
            }
        }
        // Unique ids, none colliding with the Custom sentinel.
        let ids = EqualizerPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(EqualizerPreset.customID))
        // Flat heads the list and is all-zero.
        XCTAssertEqual(EqualizerPreset.all.first, EqualizerPreset.flat)
        XCTAssertTrue(EqualizerPreset.flat.gains.allSatisfy { $0 == 0 })
    }

    func testPresetLookup() {
        XCTAssertEqual(EqualizerPreset.preset(id: "rock"), EqualizerPreset.rock)
        XCTAssertNil(EqualizerPreset.preset(id: "polka"))
        XCTAssertNil(EqualizerPreset.preset(id: EqualizerPreset.customID))
    }

    func testActiveGainsResolution() {
        // Named preset resolves through the table…
        var settings = EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.rock.id)
        XCTAssertEqual(settings.activeGains, EqualizerPreset.rock.gains)
        XCTAssertFalse(settings.isActiveCurveFlat)

        // …Custom resolves through customGains…
        settings.presetID = EqualizerPreset.customID
        settings.customGains = [1, 2, 3, 4, 5, -5, -4, -3, -2, -1]
        XCTAssertEqual(settings.activeGains, [1, 2, 3, 4, 5, -5, -4, -3, -2, -1])

        // …and an unknown id degrades to Flat instead of trapping.
        settings.presetID = "removed-in-a-future-build"
        XCTAssertEqual(settings.activeGains, EqualizerPreset.flat.gains)
        XCTAssertTrue(settings.isActiveCurveFlat)
    }

    func testActiveGainsNormalizeHandMutatedCustomCurve() {
        var settings = EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.customID)
        // Direct property mutation skips init's normalization on purpose —
        // the point-of-use normalization must still protect the node.
        settings.customGains = [50, -50, .nan, 3]
        XCTAssertEqual(settings.activeGains, [12, -12, 0, 3, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - 4. Persistence

    func testPersistenceRoundTrip() {
        let original = EqualizerSettings(
            isEnabled: true,
            presetID: EqualizerPreset.customID,
            customGains: [6, 5, 4, 3, 1, 0, -1, -2, -3, -4]
        )
        original.save(to: defaults)

        let loaded = EqualizerSettings.load(from: defaults)
        XCTAssertEqual(loaded, original)
    }

    func testNamedPresetSelectionPersists() {
        let original = EqualizerSettings(
            isEnabled: true,
            presetID: EqualizerPreset.jazz.id,
            customGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        )
        original.save(to: defaults)

        let loaded = EqualizerSettings.load(from: defaults)
        XCTAssertEqual(loaded.presetID, EqualizerPreset.jazz.id)
        XCTAssertEqual(loaded.activeGains, EqualizerPreset.jazz.gains)
        // The custom curve survives alongside the named selection, so
        // switching back to Custom restores it.
        XCTAssertEqual(loaded.customGains, [1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
    }

    func testLoadDefaultsWhenKeysMissing() {
        let loaded = EqualizerSettings.load(from: defaults)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.presetID, EqualizerPreset.flat.id)
        XCTAssertTrue(loaded.isActiveCurveFlat)
        XCTAssertEqual(loaded.customGains, [Float](repeating: 0, count: 10))
    }

    func testLoadDegradesGarbageToSafeValues() {
        // A preset id this build doesn't know (renamed/removed preset, or a
        // hand-edited plist) must fall back to Flat, and an out-of-range /
        // wrong-length gains array must come back normalized.
        defaults.set(true, forKey: EqualizerSettings.DefaultsKey.enabled)
        defaults.set("turbo-bass-9000", forKey: EqualizerSettings.DefaultsKey.preset)
        defaults.set([99.0, -99.0, 3.0], forKey: EqualizerSettings.DefaultsKey.customGains)

        let loaded = EqualizerSettings.load(from: defaults)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.presetID, EqualizerPreset.flat.id)
        XCTAssertEqual(loaded.customGains, [12, -12, 3, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - 5. Pipeline application

    func testApplyEqualizerDrivesBandGainsAndBypass() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyEqualizer(
            EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.rock.id)
        )

        for (index, band) in pipeline.eq.bands.enumerated() {
            let expected = EqualizerPreset.rock.gains[index]
            XCTAssertEqual(band.gain, expected, accuracy: 0.0001)
            // Bit-perfect contract: only bands doing real work run.
            XCTAssertEqual(band.bypass, expected == 0)
        }
        XCTAssertEqual(pipeline.eq.globalGain, 0)
    }

    func testApplyEqualizerDisabledBypassesEveryBand() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyEqualizer(
            EqualizerSettings(isEnabled: false, presetID: EqualizerPreset.dance.id)
        )
        XCTAssertTrue(pipeline.eq.bands.allSatisfy(\.bypass))
        XCTAssertEqual(pipeline.eq.globalGain, 0)
    }

    func testFlatEnabledIsFullyBypassed() {
        // Enabled + Flat must be indistinguishable from EQ-off: every band
        // bypassed at 0 dB — the same inert state the pipeline ships in.
        let pipeline = EngineDSPPipeline()
        pipeline.applyEqualizer(
            EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.flat.id)
        )
        XCTAssertTrue(pipeline.isEQFlatForTesting)
    }

    func testApplyAfterPresetRestoresBypassedBands() {
        // Rock leaves bands 6 at 0 dB (bypassed); switching to Treble Boost
        // must re-engage what it needs and release what it doesn't.
        let pipeline = EngineDSPPipeline()
        pipeline.applyEqualizer(
            EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.rock.id)
        )
        pipeline.applyEqualizer(
            EqualizerSettings(isEnabled: true, presetID: EqualizerPreset.trebleBoost.id)
        )
        for (index, band) in pipeline.eq.bands.enumerated() {
            let expected = EqualizerPreset.trebleBoost.gains[index]
            XCTAssertEqual(band.gain, expected, accuracy: 0.0001)
            XCTAssertEqual(band.bypass, expected == 0)
        }
    }

    // MARK: - 6. Engine wiring

    func testEngineAppliesSettingsOnPipelineConstruction() throws {
        let engine = try makeEngine()
        engine.equalizer = EqualizerSettings(
            isEnabled: true, presetID: EqualizerPreset.electronic.id
        )
        // No pipeline yet — the assignment is just stored state.
        XCTAssertNil(engine.dspPipeline)

        // Construction must re-apply the stored curve (the node ships flat).
        let pipeline = engine.dspEnsurePipeline()
        for (index, band) in pipeline.eq.bands.enumerated() {
            let expected = EqualizerPreset.electronic.gains[index]
            XCTAssertEqual(band.gain, expected, accuracy: 0.0001)
            XCTAssertEqual(band.bypass, expected == 0)
        }
    }

    func testEnginePushesLiveEditsOntoExistingPipeline() throws {
        let engine = try makeEngine()
        let pipeline = engine.dspEnsurePipeline()
        XCTAssertTrue(pipeline.isEQFlatForTesting, "pipeline ships flat")

        engine.equalizer = EqualizerSettings(
            isEnabled: true, presetID: EqualizerPreset.bassBoost.id
        )
        for (index, band) in pipeline.eq.bands.enumerated() {
            let expected = EqualizerPreset.bassBoost.gains[index]
            XCTAssertEqual(band.gain, expected, accuracy: 0.0001)
            XCTAssertEqual(band.bypass, expected == 0)
        }

        // Toggling off live must drop the whole stage back to bypass.
        engine.equalizer.isEnabled = false
        XCTAssertTrue(pipeline.eq.bands.allSatisfy(\.bypass))
    }
}
