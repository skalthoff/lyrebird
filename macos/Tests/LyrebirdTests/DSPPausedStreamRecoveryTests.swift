import AVFoundation
import XCTest

@testable import LyrebirdAudio

/// Coverage for #1048: a paused transport must never start the next track.
///
/// Pausing the DSP path freezes consumption, so the current track's open
/// HTTP response idles until CFNetwork's request timeout kills it (~60s).
/// Before the fix that surfaced as a stream error, and the owner's
/// skip-on-error advanced the queue and started playback — audibly, while
/// the user believed the app was paused.
///
/// Two layers under test:
///   1. `EngineDSPPipeline` parks active-deck stream events (error/finish)
///      that arrive while paused and delivers them on `resume()` — the skip
///      then happens in response to an explicit transport action.
///   2. `DSPTrackStreamer` parks a transfer failure while the owner's
///      transport is paused and reconnects (ranged request) on unpause,
///      so a survivable timeout continues the same track instead of
///      failing it.
@MainActor
final class DSPPausedStreamRecoveryTests: XCTestCase {

    // MARK: - Pipeline: deferred stream events

    /// An active-deck stream failure while paused must not reach the owner
    /// (whose handler skips to — and starts — the next track). It parks, and
    /// `resume()` delivers it instead.
    func testActiveStreamErrorWhilePausedParksUntilResume() {
        let pipeline = EngineDSPPipeline()
        var errors: [String] = []
        var finishes = 0
        pipeline.onStreamError = { errors.append($0) }
        pipeline.onTrackFinished = { finishes += 1 }

        pipeline.play()
        pipeline.pause()
        XCTAssertEqual(pipeline.state, .paused)

        pipeline.injectActiveStreamerErrorForTesting("The request timed out.")

        XCTAssertTrue(errors.isEmpty, "a failure while paused must park, not skip the track from under the user")
        XCTAssertEqual(pipeline.state, .paused, "the transport must stay paused across a parked failure")
        XCTAssertTrue(pipeline.hasDeferredStreamEventForTesting)

        pipeline.resume()

        XCTAssertEqual(errors, ["The request timed out."], "resume must deliver the parked failure exactly once")
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(pipeline.state, .idle, "the delivered failure takes the ordinary error path")
        XCTAssertFalse(pipeline.hasDeferredStreamEventForTesting)
    }

    /// The paused-state guard must not change the playing-time contract:
    /// a failure mid-playback surfaces immediately (the stall-recovery skip).
    func testActiveStreamErrorWhilePlayingFiresImmediately() {
        let pipeline = EngineDSPPipeline()
        var errors: [String] = []
        pipeline.onStreamError = { errors.append($0) }

        pipeline.play()
        pipeline.injectActiveStreamerErrorForTesting("decode failed")

        XCTAssertEqual(errors, ["decode failed"], "failures while playing must keep surfacing immediately")
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertFalse(pipeline.hasDeferredStreamEventForTesting)
    }

    /// End-of-playback while paused (completion storms when a node stops
    /// under a paused engine) must not advance the queue — `onTrackFinished`
    /// starts the next track. It parks, and `resume()` runs the finish.
    func testActiveFinishWhilePausedParksUntilResume() {
        let pipeline = EngineDSPPipeline()
        var finishes = 0
        pipeline.onTrackFinished = { finishes += 1 }

        pipeline.play()
        pipeline.pause()

        pipeline.injectActiveStreamerFinishedForTesting()

        XCTAssertEqual(finishes, 0, "a finish while paused must park, not start the next track")
        XCTAssertEqual(pipeline.state, .paused)
        XCTAssertTrue(pipeline.hasDeferredStreamEventForTesting)

        pipeline.resume()

        XCTAssertEqual(finishes, 1, "resume must run the parked finish")
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertFalse(pipeline.hasDeferredStreamEventForTesting)
    }

    /// Parked events belong to the track that parked them: an explicit load
    /// of a new track (and a stop) must drop them, or a stale failure would
    /// fire against the wrong track on the next resume.
    func testLoadAndStopClearParkedStreamEvents() {
        let pipeline = EngineDSPPipeline()
        var errors: [String] = []
        pipeline.onStreamError = { errors.append($0) }

        pipeline.play()
        pipeline.pause()
        pipeline.injectActiveStreamerErrorForTesting("stale failure")
        XCTAssertTrue(pipeline.hasDeferredStreamEventForTesting)

        pipeline.load(url: URL(fileURLWithPath: "/dev/null"), authHeader: nil)
        XCTAssertFalse(pipeline.hasDeferredStreamEventForTesting, "an explicit load supersedes the outgoing track's parked events")
        XCTAssertTrue(errors.isEmpty)

        pipeline.pause()
        pipeline.injectActiveStreamerErrorForTesting("stale failure 2")
        XCTAssertTrue(pipeline.hasDeferredStreamEventForTesting)

        pipeline.stop()
        XCTAssertFalse(pipeline.hasDeferredStreamEventForTesting, "stop tears down parked events with the rest of the track state")
        XCTAssertTrue(errors.isEmpty, "cleared events must never surface")
    }

    // MARK: - Streamer: park + reconnect

    /// A transfer failure while the owner's transport is paused must not
    /// surface `onStreamError`; unpausing performs the parked reconnect,
    /// whose failure (nothing listens on the port) then surfaces through the
    /// ordinary playing-time path. Connection-refused on loopback stands in
    /// for the paused-idle request timeout — both arrive as a failed task.
    func testStreamerParksFailureWhilePausedAndReconnectsOnUnpause() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        // Port 9 (discard) — nothing listens on loopback, so the connect is
        // refused deterministically and fast.
        let streamer = DSPTrackStreamer(
            url: URL(string: "http://127.0.0.1:9/track.flac")!,
            authHeader: nil,
            playerNode: node
        )
        defer { streamer.cancel() }

        var parkedPhaseErrors = 0
        streamer.onStreamError = { _ in parkedPhaseErrors += 1 }

        streamer.setTransportPaused(true)
        streamer.start()

        // Give the refused connect ample time to land while paused.
        let parkDeadline = Date().addingTimeInterval(2)
        while Date() < parkDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(parkedPhaseErrors, 0, "a failure while paused must park, not surface")

        let surfaced = expectation(description: "reconnect failure surfaces once unpaused")
        streamer.onStreamError = { _ in surfaced.fulfill() }
        streamer.setTransportPaused(false)

        wait(for: [surfaced], timeout: 10)
        XCTAssertEqual(parkedPhaseErrors, 0)
    }
}
