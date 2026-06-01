import XCTest
@testable import LyrebirdAudio

/// Unit coverage for the Core Audio output-device enumeration + UID
/// resolution that backs the Preferences output-device picker.
///
/// These don't assume any particular device is present (CI runners may have
/// none): they verify the contract that holds regardless of hardware —
/// well-formed entries, stable UID round-trips, and the System-Default
/// fallback semantics.
final class AudioOutputDevicesTests: XCTestCase {
    func testEnumeratedDevicesAreWellFormed() {
        for device in AudioOutputDevices.outputDevices() {
            XCTAssertFalse(device.uid.isEmpty, "every output device must carry a non-empty UID")
            XCTAssertFalse(device.name.isEmpty, "every output device must carry a display name")
            XCTAssertEqual(device.id, device.uid, "Identifiable.id should alias the UID")
        }
    }

    func testEmptyUIDResolvesToSystemDefault() {
        // The empty UID is the "System Default" sentinel — it must never
        // resolve to a concrete device.
        XCTAssertNil(AudioOutputDevices.device(forUID: ""))
    }

    func testUnknownUIDResolvesToNil() {
        XCTAssertNil(AudioOutputDevices.device(forUID: "not-a-real-device-uid-\(UUID().uuidString)"))
    }

    func testEnumeratedDeviceRoundTripsThroughResolution() {
        guard let first = AudioOutputDevices.outputDevices().first else {
            // No output hardware on this runner — the round-trip is vacuous.
            return
        }
        let resolved = AudioOutputDevices.device(forUID: first.uid)
        XCTAssertEqual(resolved, first, "a known UID must resolve back to the same device")
    }

    func testExclusiveModeWithEmptyUIDIsNoOp() throws {
        // System Default can't be hogged — toggling exclusive mode without a
        // concrete device must be a harmless no-op rather than throwing.
        XCTAssertNoThrow(try AudioOutputDevices.setExclusiveMode(true, forUID: ""))
        XCTAssertNoThrow(try AudioOutputDevices.setExclusiveMode(false, forUID: ""))
    }
}
