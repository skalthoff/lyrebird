import AppKit

/// Manages the optional menu-bar `NSStatusItem` for Jellify.
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

    /// Show or hide the menu-bar icon. Safe to call repeatedly with the
    /// same value — it checks current state before creating / destroying
    /// the status item.
    func setVisible(_ visible: Bool) {
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
                    accessibilityDescription: "Jellify"
                )
                button.image?.isTemplate = true
                button.toolTip = "Jellify"
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
