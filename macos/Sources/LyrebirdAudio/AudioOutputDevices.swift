import CoreAudio
import Foundation
import os

private let deviceLog = Logger(subsystem: "org.lyrebird.desktop", category: "audio-output")

/// A selectable Core Audio output device.
///
/// `uid` is the stable, persistable identifier (`kAudioDevicePropertyDeviceUID`)
/// — it survives reboots and reconnects, unlike the transient `AudioDeviceID`.
/// We persist `uid` and resolve it back to a live `AudioDeviceID` at playback
/// time so a device that's currently unplugged simply falls back to the system
/// default instead of breaking playback.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    /// `kAudioDevicePropertyDeviceUID` — stable across reboots/reconnects.
    public let uid: String
    /// Human-readable name (`kAudioObjectPropertyName`).
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Core Audio output-device enumeration + UID→`AudioDeviceID` resolution.
///
/// macOS has no `AVAudioSession` (that's iOS-only — see the note in
/// `AudioEngine.swift`). Output routing is done by enumerating the system's
/// audio devices through the HAL and pinning `AVPlayer.audioOutputDeviceUniqueID`
/// to the chosen device's UID. This enum is the single home for the HAL plumbing
/// so both the engine and the Preferences picker share one implementation.
public enum AudioOutputDevices {
    /// `AppStorage` key for the persisted output-device UID. Empty / absent
    /// means "Follow system default", which is the graceful fallback whenever
    /// the saved device is missing (unplugged headphones, removed interface).
    public static let preferenceKey = "audio.outputDeviceUID"

    /// Enumerate all devices that expose at least one output stream. The
    /// system default is intentionally *not* injected as a synthetic entry —
    /// the UI presents a "System Default" option mapped to an empty UID, and
    /// the engine treats an empty/unknown UID as "let CoreAudio decide".
    ///
    /// Runs synchronously; callers on the main actor should hop off it
    /// (`Task.detached`) since the HAL property reads can block briefly while
    /// the audio server is busy. See CLAUDE.md "Runtime gaps" #2.
    public static func outputDevices() -> [AudioOutputDevice] {
        guard let deviceIDs = allDeviceIDs() else { return [] }
        var result: [AudioOutputDevice] = []
        for deviceID in deviceIDs {
            guard hasOutputStreams(deviceID) else { continue }
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
            result.append(AudioOutputDevice(uid: uid, name: name))
        }
        return result
    }

    /// Resolve a persisted device UID to a live device, returning `nil` when
    /// the device is no longer present (so the caller falls back to the system
    /// default). An empty UID always resolves to `nil` ("System Default").
    public static func device(forUID uid: String) -> AudioOutputDevice? {
        guard !uid.isEmpty else { return nil }
        return outputDevices().first { $0.uid == uid }
    }

    /// `AppStorage` key for the exclusive-mode (hog) preference. Off by
    /// default — hog mode is an opt-in audiophile feature, not a sane default
    /// (it silences every other app on the machine for the duration).
    public static let exclusiveModePreferenceKey = "audio.exclusiveMode"

    /// Acquire or release exclusive (hog) access to the device identified by
    /// `uid`. Exclusive mode hands the device to this process so the
    /// hardware can run at the stream's native sample rate without the system
    /// mixer's resampling — the "bit-perfect"/lossless path audiophiles want.
    ///
    /// Throws on failure rather than swallowing — the caller surfaces the
    /// error and reverts the toggle (the optimistic-UI-without-echo anti-
    /// pattern in CLAUDE.md). Returns silently when `uid` is empty (System
    /// Default can't be hogged) so toggling exclusive mode without a concrete
    /// device selection is a harmless no-op.
    public static func setExclusiveMode(_ enabled: Bool, forUID uid: String) throws {
        guard !uid.isEmpty else { return }
        guard let deviceID = deviceID(forUID: uid) else {
            throw AudioOutputDeviceError.deviceUnavailable
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Hog mode is a `pid_t`: our PID to claim it, -1 to release it.
        var pid: pid_t = enabled ? getpid() : -1
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid
        )
        guard status == noErr else {
            deviceLog.error("setExclusiveMode(\(enabled)) failed for \(uid, privacy: .public): \(status)")
            throw AudioOutputDeviceError.hogModeFailed(status)
        }
    }

    /// Resolve a UID to a transient `AudioDeviceID` (for property writes that
    /// the UID-based API can't reach, e.g. hog mode).
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let ids = allDeviceIDs() else { return nil }
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - HAL plumbing

    private static func allDeviceIDs() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            if status != noErr {
                deviceLog.error("AudioObjectGetPropertyDataSize(devices) failed: \(status)")
            }
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else {
            deviceLog.error("AudioObjectGetPropertyData(devices) failed: \(status)")
            return nil
        }
        return ids
    }

    /// `true` when the device exposes at least one output stream — i.e. it's
    /// something you can route audio *to* (excludes pure-input devices like a
    /// USB microphone).
    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// Failures surfaced by the output-device routing layer.
public enum AudioOutputDeviceError: LocalizedError {
    /// The persisted device UID no longer maps to a present device.
    case deviceUnavailable
    /// A Core Audio `AudioObjectSetPropertyData` call failed; carries the
    /// raw `OSStatus` for diagnostics.
    case hogModeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "That output device isn't available right now."
        case .hogModeFailed:
            return "Couldn't switch the device to exclusive mode. Another app may be using it."
        }
    }
}
