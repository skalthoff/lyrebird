import AVFoundation
import XCTest
@testable import LyrebirdAudio
import LyrebirdCore

/// Recovery / failure-handling behaviour for `AudioEngine`, covering the
/// 2.0-polish audit findings:
///   * L752 — in-place stall recovery must NOT reset the retry budget.
///   * L863/L879 — a transient item failure retries the current track up to
///     `maxAutoRetries` before skipping, matching the stall path.
///   * L974 — the give-up branch quiesces the player + heartbeat.
///   * L1031 — `invalidURL` errors must not leak the `api_key` token.
///
/// All tests build a real (un-authed) core against a throwaway data dir, the
/// same pattern as `AudioEnginePreloadTests`. None touch the network: the
/// failure paths under test are driven through DEBUG test seams with a bare
/// `AVQueuePlayer` and synthesized errors.
@MainActor
final class AudioEngineRecoveryTests: XCTestCase {
    private func makeEngine() throws -> AudioEngine {
        let dir = NSTemporaryDirectory() + "lyrebird-recovery-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "recovery-test"))
        let engine = AudioEngine(core: core)
        engine.installEmptyPlayerForTesting()
        return engine
    }

    private func transientError() -> NSError {
        // -1005 == NSURLErrorNetworkConnectionLost — one of the transient codes
        // the item-failure path recovers from.
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
    }

    // MARK: - L752: stall recovery preserves the retry budget

    /// An in-place stall recovery (`replaceCurrentItem`) fires the
    /// `currentItem` KVO observer, which on a *genuine* queue advance resets
    /// `stallRetryCount`. The recovery flag must suppress that reset, otherwise
    /// a permanently-stalled stream would retry forever and never surface
    /// "Couldn't play, tap to retry." We seed a non-zero count, run a
    /// recovery, and assert the count is preserved (not clobbered to 0).
    func testStallRecoveryDoesNotResetRetryBudget() throws {
        let engine = try makeEngine()
        let url = URL(string: "https://example.invalid/stream")!
        engine.setCurrentStreamURLForTesting(url)

        // Drive two transient failures: each increments the shared budget and
        // recovers in place. After two, the count must read 2 — proving the
        // recovery's currentItem KVO change did not reset it.
        engine.handleItemFailureForTesting(transientError())
        engine.handleItemFailureForTesting(transientError())

        // The KVO observer marshals its (suppressed) reset through a Task hop;
        // give the main run loop a turn so any erroneous reset would have
        // landed before we assert.
        let drained = expectation(description: "run loop drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(
            engine.stallRetryCountForTesting,
            2,
            "an in-place recovery must not reset the stall retry budget (#439)"
        )
    }

    // MARK: - L863/L879: transient item failure retries before skipping

    /// A single transient item failure must NOT immediately skip the track.
    /// Within the retry budget it recovers in place (fires
    /// `audioEngineDidStall` / `audioEngineDidRecover`) and leaves the queue
    /// alone — `onTrackEnded` must not fire yet.
    func testTransientFailureRetriesInsteadOfSkippingOnFirstError() throws {
        let engine = try makeEngine()
        let spy = RecoveryDelegateSpy()
        engine.delegate = spy
        engine.setCurrentStreamURLForTesting(URL(string: "https://example.invalid/stream")!)

        var trackEndedFired = false
        engine.onTrackEnded = { trackEndedFired = true }

        engine.handleItemFailureForTesting(transientError())

        XCTAssertFalse(trackEndedFired, "a transient blip must retry, not skip, on the first error")
        XCTAssertEqual(spy.didStallCount, 1, "the retry must surface a stall indicator")
        XCTAssertEqual(spy.didRecoverCount, 1, "the in-place rebuild must fire didRecover")
        XCTAssertEqual(spy.transientErrorCount, 0, "no terminal skip while retries remain")
    }

    /// Once the shared retry budget (`maxAutoRetries`) is exhausted, the next
    /// transient failure skips: it surfaces the transient indicator and
    /// advances the queue via `onTrackEnded`, rather than wedging on the dead
    /// item. maxAutoRetries == 2, so the 3rd failure is the one that skips.
    func testTransientFailureSkipsAfterRetriesExhausted() throws {
        let engine = try makeEngine()
        let spy = RecoveryDelegateSpy()
        engine.delegate = spy
        engine.setCurrentStreamURLForTesting(URL(string: "https://example.invalid/stream")!)

        var trackEndedCount = 0
        engine.onTrackEnded = { trackEndedCount += 1 }

        // Failures 1 and 2 recover in place (within budget).
        engine.handleItemFailureForTesting(transientError())
        engine.handleItemFailureForTesting(transientError())
        XCTAssertEqual(trackEndedCount, 0, "still within retry budget after two failures")

        // Failure 3 exhausts the budget — skip.
        engine.handleItemFailureForTesting(transientError())

        XCTAssertEqual(trackEndedCount, 1, "the queue must advance once retries are spent")
        XCTAssertEqual(spy.transientErrorCount, 1, "the terminal skip surfaces the transient toast")
    }

    /// With no recoverable URL captured there's nothing to rebuild, so a
    /// transient failure skips immediately rather than charging the budget.
    func testTransientFailureWithoutStreamURLSkipsImmediately() throws {
        let engine = try makeEngine()
        let spy = RecoveryDelegateSpy()
        engine.delegate = spy
        engine.setCurrentStreamURLForTesting(nil)

        var trackEndedFired = false
        engine.onTrackEnded = { trackEndedFired = true }

        engine.handleItemFailureForTesting(transientError())

        XCTAssertTrue(trackEndedFired, "no URL to rebuild from means skip straight to the advance")
        XCTAssertEqual(spy.transientErrorCount, 1)
        XCTAssertEqual(spy.didStallCount, 0, "no retry attempted without a URL")
    }

    /// A non-transient error (e.g. a 403) must be left to the blind 5s stall
    /// watchdog — `handleItemFailure` ignores it entirely, so neither a retry
    /// nor a skip happens here.
    func testNonTransientFailureIsIgnoredByItemFailurePath() throws {
        let engine = try makeEngine()
        let spy = RecoveryDelegateSpy()
        engine.delegate = spy
        engine.setCurrentStreamURLForTesting(URL(string: "https://example.invalid/stream")!)

        var trackEndedFired = false
        engine.onTrackEnded = { trackEndedFired = true }

        // -11800 is a generic AVFoundation error, not in the transient set.
        engine.handleItemFailureForTesting(NSError(domain: "CoreMediaErrorDomain", code: -11800))

        XCTAssertFalse(trackEndedFired)
        XCTAssertEqual(spy.didStallCount, 0)
        XCTAssertEqual(spy.transientErrorCount, 0)
        XCTAssertEqual(engine.stallRetryCountForTesting, 0, "non-transient errors don't charge the budget")
    }

    // MARK: - L974: give-up branch quiesces

    /// When the retry budget is exhausted, the give-up path must pause the
    /// player, cancel the watchdog, and notify the delegate so the UI/server
    /// reflect the failed state instead of a player wedged in
    /// `.waitingToPlayAtSpecifiedRate`.
    func testTerminalFailureQuiescesPlayerAndNotifies() throws {
        let engine = try makeEngine()
        let spy = RecoveryDelegateSpy()
        engine.delegate = spy

        engine.failTerminallyForTesting()

        XCTAssertFalse(engine.hasPendingStallWatchdogForTesting, "watchdog must be cancelled on give-up")
        XCTAssertEqual(spy.didFailCount, 1, "the terminal failure must reach the delegate")
        XCTAssertEqual(spy.lastFailMessage, "Couldn't play, tap to retry.")
    }

    // MARK: - L1031: invalidURL redaction

    /// `AudioEngineError.invalidURL.errorDescription` must never echo the raw
    /// stream URL, which carries the Jellyfin access token as `api_key`.
    func testInvalidURLErrorRedactsAccessToken() {
        let raw = "https://music.example.com/Audio/abc123/universal?api_key=SECRET_TOKEN_VALUE&container=mp3"
        let description = AudioEngineError.invalidURL(raw).errorDescription ?? ""

        XCTAssertFalse(description.contains("SECRET_TOKEN_VALUE"), "the api_key token must not leak into the description")
        XCTAssertFalse(description.contains("api_key"), "the query string must be stripped entirely")
        XCTAssertFalse(description.contains("?"), "everything from the query onward must be dropped")
        // The path should still be there for diagnostics.
        XCTAssertTrue(description.contains("/Audio/abc123/universal"), "the path should survive for diagnostics")
    }

    /// A string that won't parse as a URL falls back to a fully redacted
    /// placeholder rather than echoing the input.
    func testInvalidURLErrorRedactsUnparseableString() {
        // A control character makes URLComponents(string:) return nil.
        let raw = "ht\u{0001}tp://broken?api_key=SECRET"
        let description = AudioEngineError.invalidURL(raw).errorDescription ?? ""

        XCTAssertFalse(description.contains("SECRET"))
        XCTAssertTrue(description.contains("<redacted>"))
    }
}

@MainActor
private final class RecoveryDelegateSpy: AudioEngineDelegate {
    var didStallCount = 0
    var didRecoverCount = 0
    var didFailCount = 0
    var transientErrorCount = 0
    var lastFailMessage: String?

    func audioEngineDidStall() { didStallCount += 1 }
    func audioEngineDidRecover() { didRecoverCount += 1 }
    func audioEngineDidFail(_ message: String) {
        didFailCount += 1
        lastFailMessage = message
    }
    func audioEngineDidEncounterTransientError(_ message: String) { transientErrorCount += 1 }
}
