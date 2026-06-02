import XCTest

@testable import Lyrebird

/// Coverage for the Dock-tile progress mapping and snapshot diffing.
///
/// The ring fill and the throttle's "skip redundant redraw" both hinge on two
/// pure pieces of logic — `DockTileController.progressFraction` and
/// `DockTileSnapshot` equality — so we test those directly without installing
/// the live tile (which would mutate `NSApp.dockTile`).
final class DockTileTests: XCTestCase {

    func testProgressFractionMidTrack() {
        XCTAssertEqual(
            DockTileController.progressFraction(position: 30, duration: 120),
            0.25,
            accuracy: 0.0001
        )
    }

    func testProgressFractionClampsOvershootToOne() {
        // At end-of-track the reported position can briefly exceed duration.
        XCTAssertEqual(
            DockTileController.progressFraction(position: 121, duration: 120),
            1.0,
            accuracy: 0.0001
        )
    }

    func testProgressFractionZeroDurationIsZero() {
        // Unknown / not-yet-loaded duration must not divide by zero or NaN.
        XCTAssertEqual(DockTileController.progressFraction(position: 5, duration: 0), 0)
        XCTAssertEqual(DockTileController.progressFraction(position: 5, duration: -1), 0)
    }

    func testSnapshotEqualitySkipsRedundantRedraw() {
        let a = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.5, isPaused: false)
        let b = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.5, isPaused: false)
        XCTAssertEqual(a, b, "Identical snapshots compare equal so the throttle can skip the redraw")
    }

    func testSnapshotEqualityDetectsPauseTransition() {
        let playing = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.5, isPaused: false)
        let paused = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.5, isPaused: true)
        XCTAssertNotEqual(playing, paused, "A pause transition must force a redraw")
    }

    func testSnapshotEqualityDetectsProgressTick() {
        let earlier = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.50, isPaused: false)
        let later = DockTileSnapshot(artwork: nil, seed: "Song A", progress: 0.51, isPaused: false)
        XCTAssertNotEqual(earlier, later, "A progress tick changes the ring and must redraw")
    }
}
