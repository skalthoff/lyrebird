import XCTest

@testable import Lyrebird

/// Coverage for `VinylSpin`, the freeze-on-pause math behind the Now Playing
/// vinyl disc.
///
/// The contract that bit the first cut: pausing must commit the *interpolated*
/// on-screen angle, not the model's already-advanced ramp target. The math
/// lives in `VinylSpin` precisely so it can be checked here without a scene
/// graph, where the presentation-layer value is otherwise unobservable.
final class VinylSpinTests: XCTestCase {

    private let degreesPerSecond = 360.0 / VinylSpin.secondsPerRotation

    func testSweepIsLinearAtEightSecondsPerRotation() {
        XCTAssertEqual(VinylSpin.sweep(elapsed: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(
            VinylSpin.sweep(elapsed: 4),
            180,
            accuracy: 1e-9,
            "half a rotation lands at 180° four seconds in"
        )
        XCTAssertEqual(
            VinylSpin.sweep(elapsed: VinylSpin.secondsPerRotation),
            360,
            accuracy: 1e-9,
            "a full 8s ramp sweeps exactly one rotation"
        )
    }

    func testSweepClampsNegativeElapsedToZero() {
        XCTAssertEqual(
            VinylSpin.sweep(elapsed: -3),
            0,
            "a clock skew must not rewind the disc"
        )
    }

    func testFrozenAngleReflectsInterpolatedPositionNotRampTarget() {
        // The view's ramp pushes the model angle to base+360 immediately, so
        // truncating *that* by 360 would snap the disc back to `base % 360`.
        // The bug repro: pausing 2s into a ramp from 0° must freeze at 90°
        // (2s * 45°/s), not at 0°.
        let frozen = VinylSpin.frozenAngle(base: 0, elapsed: 2)
        XCTAssertEqual(frozen, 90, accuracy: 1e-9)
        XCTAssertNotEqual(
            frozen,
            VinylSpin.normalize(0 + 360),
            "freezing must not collapse onto the ramp target's remainder (0°)"
        )
    }

    func testFrozenAngleResumesFromAccumulatedBase() {
        // Pause once at 90°, resume, then pause again 1s later: the second
        // freeze advances from the carried-over base, landing at 90° + 45°.
        let base = VinylSpin.frozenAngle(base: 0, elapsed: 2)  // 90°
        let next = VinylSpin.frozenAngle(base: base, elapsed: 1)  // +45°
        XCTAssertEqual(next, 135, accuracy: 1e-9)
    }

    func testFrozenAngleWrapsPastFullRotation() {
        // base 350°, +5s sweep (225°) = 575° → normalised 215°.
        let frozen = VinylSpin.frozenAngle(base: 350, elapsed: 5)
        XCTAssertEqual(frozen, 215, accuracy: 1e-9)
    }

    func testNormalizeMapsIntoZeroTo360() {
        XCTAssertEqual(VinylSpin.normalize(0), 0, accuracy: 1e-9)
        XCTAssertEqual(VinylSpin.normalize(360), 0, accuracy: 1e-9)
        XCTAssertEqual(VinylSpin.normalize(450), 90, accuracy: 1e-9)
        XCTAssertEqual(VinylSpin.normalize(720), 0, accuracy: 1e-9)
    }

    func testNormalizeHandlesNegativesWithoutSignQuirk() {
        // truncatingRemainder alone returns -90 here; the disc must read 270°.
        XCTAssertEqual(VinylSpin.normalize(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(VinylSpin.normalize(-450), 270, accuracy: 1e-9)
    }

    func testDegreesPerSecondMatchesEightSecondPeriod() {
        XCTAssertEqual(degreesPerSecond, 45, accuracy: 1e-9)
    }
}
