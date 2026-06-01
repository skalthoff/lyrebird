import AppKit

/// Manages the optional menu-bar `NSStatusItem` for Lyrebird.
///
/// The controller is a singleton owned for the lifetime of the process.
/// Callers drive visibility through `setVisible(_:)`. When the status item
/// is visible it shows a fixed music-note template image; a richer
/// mini-player popover can be attached here in a follow-up once the
/// mini-player surface lands (see #567).
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?

    private init() {}

    /// Tracks whether the persistent "Show in menu bar" (General) preference
    /// is on. When true the icon stays visible regardless of playback. When
    /// false, the "Show in menu bar while playing" (Notifications) preference
    /// can still show it transiently — see `setVisibleWhilePlaying(_:)`.
    private var persistentVisible = false

    /// Tracks the latest transient "Show in menu bar while playing" state so a
    /// later change to the persistent toggle re-resolves against it (and vice
    /// versa) rather than dropping one of the two inputs.
    private var playingVisible = false

    /// Show or hide the menu-bar icon for the persistent General preference.
    /// Safe to call repeatedly with the same value — it checks current state
    /// before creating / destroying the status item.
    func setVisible(_ visible: Bool) {
        persistentVisible = visible
        applyVisibility(MenuBarController.resolveVisibility(
            playing: playingVisible,
            persistent: visible
        ))
    }

    /// Drive transient menu-bar visibility from playback state for the
    /// "Show in menu bar while playing" preference. When `playing` is
    /// true the icon appears; when playback stops it's removed *unless* the
    /// persistent General toggle is keeping it on. Idempotent.
    func setVisibleWhilePlaying(_ playing: Bool) {
        playingVisible = playing
        // Never hide an icon the user pinned via the persistent toggle.
        applyVisibility(MenuBarController.resolveVisibility(
            playing: playing,
            persistent: persistentVisible
        ))
    }

    /// Pure decision for whether the menu-bar icon should be on screen, given
    /// the persistent "Show in menu bar" toggle and the transient "while
    /// playing" state. The persistent toggle always wins, so a playing→stopped
    /// transition never hides an icon the user pinned. Factored out so the
    /// persistent-vs-transient precedence can be unit-tested without realizing
    /// a live `NSStatusItem` (which requires a window-server connection).
    static func resolveVisibility(playing: Bool, persistent: Bool) -> Bool {
        playing || persistent
    }

    /// Update the menu-bar button's tooltip with the current track so hovering
    /// the icon shows what's playing. Passing `nil` resets to the app name.
    func setNowPlaying(_ title: String?) {
        statusItem?.button?.toolTip = title.map { "Lyrebird — \($0)" } ?? "Lyrebird"
    }

    /// Create or destroy the `NSStatusItem` to match `visible`.
    private func applyVisibility(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.squareLength
            )
            if let button = item.button {
                // `"music.note"` is available on macOS 11+. The template
                // rendering mode lets AppKit invert the icon for light /
                // dark menu bars automatically.
                button.image = NSImage(
                    systemSymbolName: "music.note",
                    accessibilityDescription: "Lyrebird"
                )
                button.image?.isTemplate = true
                button.toolTip = "Lyrebird"
            }
            statusItem = item
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }
}
