import Foundation
import XCTest

@testable import Lyrebird
import LyrebirdAudio

/// Coverage for the debug panel snapshot helpers (#448).
///
/// Tested here: `hashUserId` (deterministic, length, hex-only), `jsonString`
/// serialization shape (required keys, no raw user id), and the
/// `DebugSnapshot` value-type defaults (zero-value snapshot is safe to display).
final class DebugPanelTests: XCTestCase {

    // MARK: - hashUserId

    func test_hashUserId_returnsFourByteHexPrefix() {
        let result = DebugSnapshot.hashUserId("abc123")
        // 4 bytes → 8 hex characters.
        XCTAssertEqual(result.count, 8, "hashUserId should return exactly 8 hex characters")
        XCTAssert(result.allSatisfy { $0.isHexDigit }, "hashUserId result should be all hex digits")
    }

    func test_hashUserId_isDeterministic() {
        let a = DebugSnapshot.hashUserId("some-user-id-42")
        let b = DebugSnapshot.hashUserId("some-user-id-42")
        XCTAssertEqual(a, b, "hashUserId must return the same result for the same input")
    }

    func test_hashUserId_differentInputsProduceDifferentHashes() {
        let a = DebugSnapshot.hashUserId("user-1")
        let b = DebugSnapshot.hashUserId("user-2")
        XCTAssertNotEqual(a, b, "Different user ids should produce different hashes")
    }

    func test_hashUserId_emptyStringDoesNotCrash() {
        let result = DebugSnapshot.hashUserId("")
        XCTAssertEqual(result.count, 8, "hashUserId for empty string should still return 8 chars")
    }

    // MARK: - jsonString

    func test_jsonString_containsRequiredTopLevelKeys() throws {
        var snap = DebugSnapshot()
        snap.capturedAt = Date()
        snap.session.serverURL = "https://music.example.com"
        snap.session.userId = "deadbeef"
        snap.session.username = "alice"
        snap.session.deviceId = "device-1"
        snap.player.playbackState = "playing"
        snap.player.positionSeconds = 42.0
        snap.player.volume = 0.8
        snap.queue.userAddedCount = 3
        snap.queue.autoQueueCount = 7
        snap.network.isOnline = true
        snap.network.qualityHint = "unmetered"
        snap.logs.lines = ["2026-01-01T00:00:00Z [app] something happened"]

        let json = snap.jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(parsed["capturedAt"])
        XCTAssertNotNil(parsed["session"])
        XCTAssertNotNil(parsed["player"])
        XCTAssertNotNil(parsed["queue"])
        XCTAssertNotNil(parsed["cache"])
        XCTAssertNotNil(parsed["flags"])
        XCTAssertNotNil(parsed["network"])
        XCTAssertNotNil(parsed["logs"])
        XCTAssertNotNil(parsed["appVersion"])
        XCTAssertNotNil(parsed["osVersion"])
    }

    func test_jsonString_sessionContainsHashedUserIdNotRaw() throws {
        var snap = DebugSnapshot()
        let rawId = "my-secret-user-id-12345678"
        snap.session.userId = DebugSnapshot.hashUserId(rawId)
        snap.session.username = "bob"

        let json = snap.jsonString()

        // The raw user id must not appear anywhere in the output.
        XCTAssertFalse(json.contains(rawId),
                       "Raw user id must never appear in the JSON bundle")
        // The 8-char hash should be present.
        XCTAssertTrue(json.contains(DebugSnapshot.hashUserId(rawId)),
                      "Hashed user id should be in the JSON bundle")
    }

    func test_jsonString_isValidJSON() {
        let snap = DebugSnapshot()
        let json = snap.jsonString()
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data),
            "jsonString must always produce parseable JSON"
        )
    }

    func test_jsonString_zeroValueSnapshotDoesNotCrash() {
        // A default-initialised snapshot (e.g. before any refresh) must still
        // produce valid JSON — the panel can open before the first refresh fires.
        let snap = DebugSnapshot()
        let json = snap.jsonString()
        XCTAssertFalse(json.isEmpty)
    }

    func test_jsonString_logsArrayIsPresent() throws {
        var snap = DebugSnapshot()
        snap.logs.lines = ["line 1", "line 2"]

        let json = snap.jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let logs = try XCTUnwrap(parsed["logs"] as? [String])

        XCTAssertEqual(logs, ["line 1", "line 2"])
    }

    // MARK: - DebugSnapshot defaults

    func test_defaults_flagsSectionIsAllFalse() {
        let flags = DebugSnapshot.FlagsSection()
        XCTAssertFalse(flags.supportsDownloads)
        XCTAssertFalse(flags.supportsMarkPlayed)
        XCTAssertFalse(flags.supportsCrossfade)
        XCTAssertFalse(flags.supportsEngineDSP)
    }

    func test_defaults_networkSectionDefaultsToOnline() {
        let net = DebugSnapshot.NetworkSection()
        XCTAssertTrue(net.isOnline,
                      "Default network section should say online (optimistic default)")
    }

    func test_defaults_capturedAtIsEpoch() {
        let snap = DebugSnapshot()
        XCTAssertEqual(snap.capturedAt.timeIntervalSince1970, 0,
                       "capturedAt default must be epoch (indicates no refresh yet)")
    }
}

// MARK: - Access-log stream telemetry (#452)

/// The access-log pipeline: delegate hook → stored stats → snapshot fields →
/// panel formatting. The `AVPlayerItemNewAccessLogEntry` notification itself
/// can't be unit-driven (`AVPlayerItemAccessLogEvent` has no public
/// initializer), so the engine-side observer is verified manually; everything
/// downstream of the delegate is pinned here.
@MainActor
final class AccessLogTelemetryTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func stats(stalls: Int = 2) -> PlayerAccessLogStats {
        PlayerAccessLogStats(
            numberOfStalls: stalls,
            indicatedBitrate: 1_410_000,
            observedBitrate: 980_500,
            downloadOverdue: 1,
            serverAddress: "203.0.113.7"
        )
    }

    func testDelegateHookStoresStats() throws {
        let model = try AppModel()
        model.audioEngineDidUpdateAccessLog(stats())
        XCTAssertEqual(model.playerAccessLogStats?.numberOfStalls, 2)
        XCTAssertEqual(model.playerAccessLogStats?.serverAddress, "203.0.113.7")
    }

    func testStopClearsStats() throws {
        let model = try AppModel()
        model.audioEngineDidUpdateAccessLog(stats())
        model.stop()
        XCTAssertNil(model.playerAccessLogStats)
    }

    // `refreshDebugSnapshot` publishes its synchronous sections immediately
    // (the IO task only re-publishes with cache sizes + log tail later), so
    // the access-log fields are assertable right after the call.

    func testSnapshotCarriesAccessLogFields() throws {
        let model = try AppModel()
        model.audioEngineDidUpdateAccessLog(stats(stalls: 5))
        model.refreshDebugSnapshot()
        let p = model.debugSnapshot.player
        XCTAssertEqual(p.accessLogStalls, 5)
        XCTAssertEqual(p.accessLogIndicatedBitrate, 1_410_000)
        XCTAssertEqual(p.accessLogObservedBitrate, 980_500)
        XCTAssertEqual(p.accessLogDownloadOverdue, 1)
        XCTAssertEqual(p.accessLogServerAddress, "203.0.113.7")
    }

    func testSnapshotFieldsNilBeforeFirstEntry() throws {
        let model = try AppModel()
        model.refreshDebugSnapshot()
        XCTAssertNil(model.debugSnapshot.player.accessLogStalls)
        XCTAssertNil(model.debugSnapshot.player.accessLogServerAddress)
    }

    func testBitrateFormatting() {
        XCTAssertEqual(DebugPanelView.formatBitrate(1_410_000), "1.41 Mbps")
        XCTAssertEqual(DebugPanelView.formatBitrate(nil), "—")
        // AVFoundation reports a negative observedBitrate when it has no
        // estimate — render as "no data", not a negative rate.
        XCTAssertEqual(DebugPanelView.formatBitrate(-1), "—")
    }
}
