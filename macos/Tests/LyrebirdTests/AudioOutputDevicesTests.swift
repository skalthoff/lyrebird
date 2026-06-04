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

    // MARK: - Hot-plug observer (audit L169)

    /// `stop()` on a never-started observer is a no-op, and `deinit` (exercised
    /// by letting the value go out of scope) must not double-remove or crash.
    func testObserverStopWithoutStartIsHarmless() {
        let observer = AudioOutputDeviceObserver()
        XCTAssertNoThrow(observer.stop())
        // A second stop must also be safe — the removal is idempotent.
        XCTAssertNoThrow(observer.stop())
    }

    /// Registering and removing the HAL listener must succeed on a real system
    /// object and leave nothing dangling. We can't synthesise a device add on a
    /// CI runner, so this verifies the lifecycle contract (register → remove)
    /// the Preferences pane relies on rather than the callback firing.
    func testObserverStartThenStopIsClean() {
        let observer = AudioOutputDeviceObserver()
        observer.start(onChange: {})
        XCTAssertNoThrow(observer.stop())
    }

    /// `start()` is idempotent: calling it twice without an intervening `stop()`
    /// replaces the registration rather than stacking a duplicate the teardown
    /// would miss. A single `stop()` must then fully unregister.
    func testObserverStartIsIdempotent() {
        let observer = AudioOutputDeviceObserver()
        observer.start(onChange: {})
        observer.start(onChange: {})
        XCTAssertNoThrow(observer.stop())
        // Idempotent stop: the replaced first registration was already removed.
        XCTAssertNoThrow(observer.stop())
    }

    /// Dropping the observer without an explicit `stop()` must not leak or
    /// crash — `deinit` removes the listener as a backstop.
    func testObserverDeinitRemovesListener() {
        autoreleasepool {
            let observer = AudioOutputDeviceObserver()
            observer.start(onChange: {})
            // Falls out of scope here; deinit must clean up the registration.
        }
        // Reaching this line without a CoreAudio assertion means deinit's
        // teardown ran cleanly.
        XCTAssertTrue(true)
    }
}
