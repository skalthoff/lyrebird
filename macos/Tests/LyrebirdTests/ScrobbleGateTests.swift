import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the scrobble *trigger gate* (#46) — the pure decision layer
/// that decides when to fire a ListenBrainz `playing_now` versus a durable
/// `single` listen. The actual POST lives in the Rust core and is exercised by
/// the Rust wiremock tests; here we pin the once-each, threshold-gated, and
/// disabled-state behaviour without any networking by injecting the threshold
/// predicate and the clock.
final class ScrobbleGateTests: XCTestCase {

    private func makeTrack(id: String, name: String = "Song", runtimeTicks: UInt64 = 1_800_000_000) -> Track {
        Track(
            id: id,
            name: name,
            albumId: nil,
            albumName: "Album",
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: runtimeTicks,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    /// Threshold predicate that flips at a fixed position, so the tests don't
    /// depend on the real half/four-minute rule (that lives in the Rust tests).
    private func thresholdAt(_ at: Double) -> (Double, Double) -> Bool {
        { position, _ in position >= at }
    }

    // MARK: - playing_now

    func testNewTrackFiresPlayingNowOnce() {
        var gate = ScrobbleGate()
        let track = makeTrack(id: "a")

        // First sighting -> playing_now.
        let first = gate.noteTrack(
            track, position: 0, duration: 180, enabled: true, now: 1000,
            thresholdReached: thresholdAt(90))
        XCTAssertEqual(first, .nowPlaying(track))

        // Subsequent ticks for the same track (below threshold) -> nothing.
        let second = gate.noteTrack(
            track, position: 5, duration: 180, enabled: true, now: 1005,
            thresholdReached: thresholdAt(90))
        XCTAssertEqual(second, .none)
    }

    // MARK: - single (durable) listen

    func testListenSubmittedOnceWhenThresholdCrossed() {
        var gate = ScrobbleGate()
        let track = makeTrack(id: "a")

        // Start the track at t=1000 — captures the start time.
        _ = gate.noteTrack(
            track, position: 0, duration: 180, enabled: true, now: 1000,
            thresholdReached: thresholdAt(90))

        // Below threshold -> nothing.
        XCTAssertEqual(
            gate.noteTrack(track, position: 89, duration: 180, enabled: true, now: 1089,
                thresholdReached: thresholdAt(90)),
            .none)

        // Crossing the threshold -> one listen, keyed to the START time (1000),
        // not the crossing time (1090).
        XCTAssertEqual(
            gate.noteTrack(track, position: 90, duration: 180, enabled: true, now: 1090,
                thresholdReached: thresholdAt(90)),
            .submitListen(track, listenedAt: 1000))

        // Already submitted -> no duplicate on later ticks.
        XCTAssertEqual(
            gate.noteTrack(track, position: 120, duration: 180, enabled: true, now: 1120,
                thresholdReached: thresholdAt(90)),
            .none)
    }

    // MARK: - disabled state

    func testDisabledNeverFiresButStillTracks() {
        var gate = ScrobbleGate()
        let track = makeTrack(id: "a")

        // Scrobbling off: no playing_now even on a fresh track.
        XCTAssertEqual(
            gate.noteTrack(track, position: 0, duration: 180, enabled: false, now: 1000,
                thresholdReached: thresholdAt(90)),
            .none)
        // Off: no listen even past the threshold.
        XCTAssertEqual(
            gate.noteTrack(track, position: 120, duration: 180, enabled: false, now: 1120,
                thresholdReached: thresholdAt(90)),
            .none)
    }

    /// Enabling mid-track must not retro-fire a `playing_now` for the track that
    /// was already current while disabled — the gate already knows its id.
    func testEnablingMidTrackDoesNotReplayPlayingNow() {
        var gate = ScrobbleGate()
        let track = makeTrack(id: "a")

        _ = gate.noteTrack(track, position: 0, duration: 180, enabled: false, now: 1000,
            thresholdReached: thresholdAt(90))
        // Now enabled, same track, still below threshold -> nothing (no
        // late playing_now).
        XCTAssertEqual(
            gate.noteTrack(track, position: 10, duration: 180, enabled: true, now: 1010,
                thresholdReached: thresholdAt(90)),
            .none)
    }

    // MARK: - track changes / reset

    func testTrackChangeResetsAndFiresFreshPlayingNow() {
        var gate = ScrobbleGate()
        let a = makeTrack(id: "a")
        let b = makeTrack(id: "b")

        _ = gate.noteTrack(a, position: 0, duration: 180, enabled: true, now: 1000,
            thresholdReached: thresholdAt(90))
        // Scrobble A.
        _ = gate.noteTrack(a, position: 90, duration: 180, enabled: true, now: 1090,
            thresholdReached: thresholdAt(90))

        // Switch to B -> fresh playing_now, new start time.
        XCTAssertEqual(
            gate.noteTrack(b, position: 0, duration: 180, enabled: true, now: 2000,
                thresholdReached: thresholdAt(90)),
            .nowPlaying(b))
        // B can then earn its own listen, keyed to B's start (2000).
        XCTAssertEqual(
            gate.noteTrack(b, position: 90, duration: 180, enabled: true, now: 2090,
                thresholdReached: thresholdAt(90)),
            .submitListen(b, listenedAt: 2000))
    }

    func testNilTrackResetsState() {
        var gate = ScrobbleGate()
        let a = makeTrack(id: "a")

        _ = gate.noteTrack(a, position: 0, duration: 180, enabled: true, now: 1000,
            thresholdReached: thresholdAt(90))
        // Playback stops.
        XCTAssertEqual(
            gate.noteTrack(nil, position: 0, duration: 0, enabled: true, now: 1010,
                thresholdReached: thresholdAt(90)),
            .none)
        // Re-starting the SAME track id after a stop fires a fresh playing_now
        // (the gate forgot it), so a replay is scrobbled as a new listen.
        XCTAssertEqual(
            gate.noteTrack(a, position: 0, duration: 180, enabled: true, now: 1020,
                thresholdReached: thresholdAt(90)),
            .nowPlaying(a))
    }

    func testEmptyTrackIdTreatedAsNoTrack() {
        var gate = ScrobbleGate()
        let empty = makeTrack(id: "")
        XCTAssertEqual(
            gate.noteTrack(empty, position: 0, duration: 180, enabled: true, now: 1000,
                thresholdReached: thresholdAt(90)),
            .none)
    }
}
