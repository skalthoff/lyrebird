import Foundation

/// Pure decision for whether the menu-bar Now Playing extra should be in the
/// menu bar, given the persistent "Show in menu bar" (General) toggle and the
/// transient "Show in menu bar while playing" (Notifications) state.
///
/// The persistent toggle always wins, so a playing→stopped transition never
/// hides an icon the user pinned. Factored out so the persistent-vs-transient
/// precedence can be unit-tested without realizing a live `MenuBarExtra`
/// (which requires a window-server connection).
///
/// Consumed by `LyrebirdApp`'s `MenuBarExtra(isInserted:)` binding — the
/// single menu-bar implementation since the `NSStatusItem`-based
/// `MenuBarController` was retired (#984).
enum MenuBarVisibility {
    /// `true` when the menu-bar extra should be on screen.
    ///
    /// - Parameters:
    ///   - playing: the transient input — the "Show in menu bar while
    ///     playing" preference AND'd with live playback state by the caller.
    ///   - persistent: the "Show in menu bar" (General) preference.
    static func resolve(playing: Bool, persistent: Bool) -> Bool {
        playing || persistent
    }
}
