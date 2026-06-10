import AVFoundation
import XCTest

@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Coverage for crossfade between tracks (#41):
///
///   1. `CrossfadeSettings` value semantics — duration normalization (clamp
///      to 0…12, zero non-finite), the off contract (anything below 1 s is
///      disabled), and curve fallback for unknown persisted raw values.
///   2. Gain envelope math — linear and equal-power shapes, the equal-power
///      constant-power identity, and progress clamping so a jittery timer
///      can never push an out-of-range gain onto a mixer node.
///   3. Scheduling decisions — `effectiveFadeDuration` (off / same-album /
///      short-track / unknown-duration ⇒ zero-fade) and the pure
///      `tickAction` window function the 1 Hz tick drives.
///   4. `UserDefaults` persistence round-trips on the pre-existing
///      `playback.crossfadeSeconds` key (#116) plus the new curve key, and
///      missing/garbage keys degrade to the shipped default (off,
///      equal-power).
///   5. `AudioEngine` integration — `dspApplyCrossfade` never constructs the
///      pipeline while the DSP flag is off (zero-behaviour-change contract),
///      and a freshly built pipeline restores the persisted settings.
@MainActor
final class CrossfadeSettingsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "crossfade-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // The engine restores crossfade settings from the *standard* domain
        // when it builds a pipeline — keep that domain pristine for the
        // integration tests below.
        UserDefaults.standard.removeObject(forKey: CrossfadeSettings.DefaultsKey.duration)
        UserDefaults.standard.removeObject(forKey: CrossfadeSettings.DefaultsKey.curve)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        UserDefaults.standard.removeObject(forKey: CrossfadeSettings.DefaultsKey.duration)
        UserDefaults.standard.removeObject(forKey: CrossfadeSettings.DefaultsKey.curve)
        super.tearDown()
    }

    private func makeEngine() throws -> AudioEngine {
        let dir = NSTemporaryDirectory() + "lyrebird-crossfade-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "crossfade-test"))
        return AudioEngine(core: core)
    }

    // MARK: - 1. Value semantics

    func testShippedDefaultIsOffEqualPower() {
        let settings = CrossfadeSettings()
        XCTAssertEqual(settings.durationSeconds, 0)
        XCTAssertEqual(settings.curve, .equalPower)
        XCTAssertFalse(settings.isEnabled, "crossfade must ship off")
    }

    func testDurationNormalizationClampsAndSanitizes() {
        XCTAssertEqual(CrossfadeSettings.normalizedDuration(99), 12, "clamp to the slider ceiling")
        XCTAssertEqual(CrossfadeSettings.normalizedDuration(-3), 0, "clamp negatives to off")
        XCTAssertEqual(CrossfadeSettings.normalizedDuration(.nan), 0, "NaN must never reach the scheduler")
        XCTAssertEqual(CrossfadeSettings.normalizedDuration(.infinity), 0)
        XCTAssertEqual(CrossfadeSettings.normalizedDuration(7), 7, "in-range values pass through")
        XCTAssertEqual(CrossfadeSettings(durationSeconds: 500).durationSeconds, 12, "init normalizes")
    }

    func testSubSecondDurationsReadAsOff() {
        XCTAssertFalse(CrossfadeSettings(durationSeconds: 0.5).isEnabled)
        XCTAssertTrue(CrossfadeSettings(durationSeconds: 1).isEnabled)
        XCTAssertTrue(CrossfadeSettings(durationSeconds: 12).isEnabled)
    }

    // MARK: - 2. Envelope math

    func testLinearEnvelope() {
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 0, curve: .linear), 0)
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 0.5, curve: .linear), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 1, curve: .linear), 1)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 0, curve: .linear), 1)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 0.5, curve: .linear), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 1, curve: .linear), 0)
    }

    func testEqualPowerEnvelopeEndpointsAndMidpoint() {
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 0, curve: .equalPower), 0, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 1, curve: .equalPower), 1, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 0, curve: .equalPower), 1, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 1, curve: .equalPower), 0, accuracy: 0.0001)
        // Midpoint: sin(π/4) == cos(π/4) == √2/2 ≈ 0.7071 — both sides
        // louder than linear's 0.5, which is the whole point of the curve.
        XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 0.5, curve: .equalPower), 0.70710678, accuracy: 0.0001)
        XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 0.5, curve: .equalPower), 0.70710678, accuracy: 0.0001)
    }

    /// The defining property: gainIn² + gainOut² == 1 at every point, so the
    /// summed acoustic power through the overlap is constant.
    func testEqualPowerHoldsConstantPower() {
        for step in 0...20 {
            let t = Double(step) / 20
            let gainIn = Double(CrossfadeSettings.fadeInGain(progress: t, curve: .equalPower))
            let gainOut = Double(CrossfadeSettings.fadeOutGain(progress: t, curve: .equalPower))
            XCTAssertEqual(gainIn * gainIn + gainOut * gainOut, 1, accuracy: 0.0001, "power sum must be 1 at t=\(t)")
        }
    }

    func testEnvelopeClampsOutOfRangeProgress() {
        for curve in CrossfadeSettings.Curve.allCases {
            XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: -1, curve: curve), 0, accuracy: 0.0001)
            XCTAssertEqual(CrossfadeSettings.fadeInGain(progress: 2, curve: curve), 1, accuracy: 0.0001)
            XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: -1, curve: curve), 1, accuracy: 0.0001)
            XCTAssertEqual(CrossfadeSettings.fadeOutGain(progress: 2, curve: curve), 0, accuracy: 0.0001)
        }
    }

    // MARK: - 3. Scheduling decisions

    func testEffectiveFadeDuration() {
        // Normal case: configured window passes through.
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 4, trackDurationSeconds: 240, sameAlbum: false),
            4
        )
        // Off stays off.
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 0, trackDurationSeconds: 240, sameAlbum: false),
            0
        )
        // Same-album pairs zero-fade (#41's gapless-album rule).
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 4, trackDurationSeconds: 240, sameAlbum: true),
            0
        )
        // A track shorter than twice the window has no room for the fade.
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 12, trackDurationSeconds: 20, sameAlbum: false),
            0
        )
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 12, trackDurationSeconds: 24, sameAlbum: false),
            12,
            "exactly 2× the window is enough room"
        )
        // Unknown duration ⇒ nowhere to place the window.
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: 4, trackDurationSeconds: nil, sameAlbum: false),
            0
        )
        // Corrupted configured values sanitize through the same path.
        XCTAssertEqual(
            CrossfadeSettings.effectiveFadeDuration(configured: .nan, trackDurationSeconds: 240, sameAlbum: false),
            0
        )
    }

    func testTickActionWindows() {
        // Far from the end: nothing to do.
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 120, fadeDuration: 4, prepStarted: false, standbyReady: false),
            .none
        )
        // Inside the buffering window (fade + lead): start the prep once.
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 13, fadeDuration: 4, prepStarted: false, standbyReady: false),
            .prepare
        )
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 13, fadeDuration: 4, prepStarted: true, standbyReady: false),
            .none,
            "prep must not restart every tick"
        )
        // Inside the fade window but the standby stream isn't decodable yet:
        // keep waiting (the fade shortens as remaining shrinks).
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 3, fadeDuration: 4, prepStarted: true, standbyReady: false),
            .none
        )
        // Inside the fade window and ready: begin.
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 3, fadeDuration: 4, prepStarted: true, standbyReady: true),
            .beginFade
        )
        // Zero-fade transitions (same album / short track) never ramp — they
        // hand off at completion — but they still buffer ahead.
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 8, fadeDuration: 0, prepStarted: false, standbyReady: false),
            .prepare
        )
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: 1, fadeDuration: 0, prepStarted: true, standbyReady: true),
            .none
        )
        // Defensive: a non-finite remaining can't fire anything.
        XCTAssertEqual(
            CrossfadeSettings.tickAction(remainingSeconds: .nan, fadeDuration: 4, prepStarted: false, standbyReady: false),
            .none
        )
    }

    // MARK: - 4. Persistence

    func testLoadFromEmptyDefaultsIsShippedDefault() {
        let settings = CrossfadeSettings.load(from: defaults)
        XCTAssertEqual(settings, CrossfadeSettings())
        XCTAssertFalse(settings.isEnabled)
    }

    func testSaveLoadRoundTrip() {
        let original = CrossfadeSettings(durationSeconds: 6, curve: .linear)
        original.save(to: defaults)
        XCTAssertEqual(CrossfadeSettings.load(from: defaults), original)

        // The duration rides the pre-existing #116 Playback-pane key, so a
        // value written before #41 landed is honoured as-is.
        XCTAssertEqual(defaults.double(forKey: "playback.crossfadeSeconds"), 6)
        XCTAssertEqual(defaults.string(forKey: "playback.crossfadeCurve"), "linear")
    }

    func testGarbagePersistedValuesDegrade() {
        defaults.set("totally-not-a-curve", forKey: CrossfadeSettings.DefaultsKey.curve)
        defaults.set(Double.infinity, forKey: CrossfadeSettings.DefaultsKey.duration)
        let settings = CrossfadeSettings.load(from: defaults)
        XCTAssertEqual(settings.curve, .equalPower, "unknown curve raw must fall back, not crash")
        XCTAssertEqual(settings.durationSeconds, 0, "non-finite duration must sanitize to off")
    }

    func testSaveNormalizesOutOfRangeDuration() {
        var settings = CrossfadeSettings(durationSeconds: 4)
        settings.durationSeconds = 99 // bypass init normalization
        settings.save(to: defaults)
        XCTAssertEqual(defaults.double(forKey: CrossfadeSettings.DefaultsKey.duration), 12)
    }

    // MARK: - 5. AudioEngine integration

    /// Flag off ⇒ zero behaviour change: pushing crossfade settings must not
    /// construct the DSP pipeline (the AVQueuePlayer path stays untouched).
    func testApplyCrossfadeIsNoOpWhileFlagOff() throws {
        let engine = try makeEngine()
        XCTAssertFalse(engine.dspPipelineEnabled)
        engine.dspApplyCrossfade(CrossfadeSettings(durationSeconds: 8, curve: .linear))
        XCTAssertNil(engine.dspPipeline, "flag off ⇒ no DSP pipeline may ever be built")
    }

    /// A freshly built pipeline restores the persisted settings — the same
    /// construct-then-restore contract as the EQ (#40), so the crossfade
    /// survives pipeline rebuilds and app relaunches.
    func testPipelineConstructionRestoresPersistedSettings() throws {
        CrossfadeSettings(durationSeconds: 5, curve: .linear).save(to: .standard)

        let engine = try makeEngine()
        engine.dspPipelineEnabled = true
        engine.setVolume(0.5) // cheapest pipeline-constructing call; never starts audio

        let pipeline = try XCTUnwrap(engine.dspPipeline)
        XCTAssertTrue(pipeline.crossfadeIsEnabled, "persisted 5s crossfade must be live on construction")
    }

    /// Live edits route through `dspApplyCrossfade` onto the existing
    /// pipeline: enable → the scheduler sees it; disable → pending arms drop.
    func testApplyCrossfadeDrivesLivePipeline() throws {
        let engine = try makeEngine()
        engine.dspPipelineEnabled = true
        engine.setVolume(0.5)
        let pipeline = try XCTUnwrap(engine.dspPipeline)
        XCTAssertFalse(pipeline.crossfadeIsEnabled)

        engine.dspApplyCrossfade(CrossfadeSettings(durationSeconds: 4))
        XCTAssertTrue(pipeline.crossfadeIsEnabled)

        engine.dspApplyCrossfade(CrossfadeSettings(durationSeconds: 0))
        XCTAssertFalse(pipeline.crossfadeIsEnabled)
    }
}
