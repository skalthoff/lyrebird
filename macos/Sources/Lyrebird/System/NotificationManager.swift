import Foundation
import UserNotifications

/// Posts local "Now Playing" notifications via `UNUserNotificationCenter`
/// when the track changes, gated behind the user's Notifications preferences.
///
/// The three toggles live in `PreferencesNotifications` as `@AppStorage`
/// keys; this manager reads the same `UserDefaults` keys directly (it isn't a
/// `View`, so it can't use the property wrapper). Keeping the keys in one
/// place — `NotificationPreference` — keeps the pane and the manager from
/// drifting apart.
///
/// Authorization is requested lazily the first time the track-change toggle is
/// enabled (and again on launch if already enabled) so the user only sees the
/// system prompt when they opt in, never on a cold first launch.
final class NotificationManager {
    static let shared = NotificationManager()

    /// Tracks whether we've already asked the system for authorization this
    /// process lifetime so repeated track changes don't spam the request.
    private var didRequestAuthorization = false

    private init() {}

    // MARK: - Authorization

    /// Request notification authorization if the user has the track-change
    /// toggle enabled. Idempotent — the system only shows the prompt once per
    /// install regardless of how many times this is called.
    func requestAuthorizationIfNeeded() {
        guard NotificationPreference.trackChangeEnabled else { return }
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Log.app.notice("Notification authorization declined by user")
            }
        }
    }

    // MARK: - Posting

    /// Post a "Now Playing" notification for a newly started track, honoring
    /// the user's enable / sound preferences. No-ops when the track-change
    /// toggle is off. Safe to call on the MainActor — the actual delivery is
    /// handed to `UNUserNotificationCenter` asynchronously.
    func notifyTrackChange(title: String, artist: String?, album: String?) {
        guard NotificationManager.shouldNotify(enabled: NotificationPreference.trackChangeEnabled) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body = NotificationManager.subtitle(artist: artist, album: album) {
            content.body = body
        }
        content.sound = NotificationPreference.soundEnabled ? .default : nil

        // `nil` trigger delivers immediately. A stable identifier per track
        // change isn't needed; a fresh UUID keeps successive track
        // notifications from collapsing into one.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("Failed to post track-change notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pure helpers (unit-testable)

    /// Whether a track-change notification should be posted at all. Factored
    /// out of `notifyTrackChange` so the gate is verifiable without realizing a
    /// `UNUserNotificationCenter` (which a headless test run can't do).
    static func shouldNotify(enabled: Bool) -> Bool {
        enabled
    }

    /// Compose the notification subtitle from the optional artist / album.
    /// Prefers "Artist — Album", falls back to whichever is present, and
    /// returns `nil` when neither is usable so the body is never a bare dash.
    /// Pure so the composition rule can be unit-tested directly.
    static func subtitle(artist: String?, album: String?) -> String? {
        let parts = [artist, album].compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

/// Single source of truth for the Notifications preference keys, shared by the
/// `PreferencesNotifications` pane (`@AppStorage`) and `NotificationManager`
/// (raw `UserDefaults`). Keys are stable user-defaults strings so on-disk
/// preferences survive across launches.
enum NotificationPreference {
    static let trackChangeKey = "notifications.trackChange"
    static let soundKey = "notifications.sound"
    static let showInMenuBarWhilePlayingKey = "notifications.showInMenuBarWhilePlaying"

    static var trackChangeEnabled: Bool {
        UserDefaults.standard.bool(forKey: trackChangeKey)
    }

    static var soundEnabled: Bool {
        UserDefaults.standard.bool(forKey: soundKey)
    }

    static var showInMenuBarWhilePlaying: Bool {
        UserDefaults.standard.bool(forKey: showInMenuBarWhilePlayingKey)
    }
}
