import AppKit

/// Posts VoiceOver announcements for app-driven events that happen away from
/// the user's current focus — the canonical example being a track change
/// triggered by autoplay or a media key, where the player bar isn't where
/// VoiceOver is reading (#342).
///
/// `.announcementRequested` is the AppKit notification that maps to
/// `AccessibilityNotification.Announcement`: VoiceOver speaks the message
/// without moving or interrupting the user's focus context, unlike a
/// `.layoutChanged` / focus move which would yank them out of whatever
/// they were navigating. The `.high` priority level ensures playback
/// announcements aren't dropped when VoiceOver is mid-utterance, while
/// still deferring to the user's own navigation speech.
enum AccessibilityAnnouncer {
    /// Speaks `message` via VoiceOver as a high-priority announcement.
    ///
    /// No-ops on an empty string so callers don't have to guard. The post
    /// is addressed to the main window (the element VoiceOver associates
    /// announcements with); when there is no main window — e.g. during
    /// teardown — the announcement is simply not delivered, which is the
    /// correct behavior.
    @MainActor
    static func announce(_ message: String) {
        guard !message.isEmpty, let window = NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
