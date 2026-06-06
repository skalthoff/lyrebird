import AppKit
import Foundation
@preconcurrency import LyrebirdCore

/// Mini Player window control, queue-end autoplay toggle, and full-window restore.
extension AppModel {
    /// Toggle the Mini Player window. Wired to the ⌘⌥P menu command; flipping
    /// the flag is enough — `LyrebirdApp` translates the change into the
    /// matching `openWindow` / `dismissWindow` call for the `mini-player`
    /// scene.
    func toggleMiniPlayer() {
        isMiniPlayerVisible.toggle()
    }

    /// Set + persist the always-on-top preference. `MiniPlayerWindowConfigurator`
    /// reads `miniPlayerAlwaysOnTop` and re-applies the window level on change.
    func setMiniPlayerAlwaysOnTop(_ on: Bool) {
        miniPlayerAlwaysOnTop = on
        UserDefaults.standard.set(on, forKey: AppModel.miniPlayerAlwaysOnTopKey)
    }

    /// Resolve the persisted autoplay flag, defaulting to `true` when the key
    /// has never been written. `UserDefaults.bool(forKey:)` returns `false`
    /// for a missing key, which would silently invert this feature's "default
    /// on" contract, so we probe for the object first.
    static func autoplayWhenQueueEndsDefault() -> Bool {
        guard UserDefaults.standard.object(forKey: autoplayWhenQueueEndsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoplayWhenQueueEndsKey)
    }

    /// Set + persist the autoplay-at-queue-end preference. Wired to the queue
    /// header toggle; `handleTrackEnded` reads `autoplayWhenQueueEnds` when
    /// the queue runs dry to decide whether to extend with an Instant Mix or
    /// stop.
    func setAutoplayWhenQueueEnds(_ on: Bool) {
        autoplayWhenQueueEnds = on
        UserDefaults.standard.set(on, forKey: AppModel.autoplayWhenQueueEndsKey)
    }

    /// Close the Mini Player and bring the full window forward, honouring the
    /// "closing returns to full window" contract. Used by the mini player's
    /// settings-menu and hover "return" affordances. Clearing the flag lets
    /// `LyrebirdApp` dismiss the scene; activating the app raises the main
    /// `WindowGroup` window back to the foreground.
    func returnToFullWindow() {
        isMiniPlayerVisible = false
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Drill the **main** window to a detail `Route` from the detached Mini
    /// Player, raising the full window first so the navigation is visible.
    ///
    /// The Mini Player floats in its own borderless window (optionally
    /// always-on-top), so a bare `navigate(to:)` would push onto the main
    /// window's `NavigationStack` while that window stays buried behind
    /// everything else — the user would tap album art and see nothing move.
    /// Activating the app raises the main `WindowGroup` window back to the
    /// foreground the same way `returnToFullWindow` does, *then* we drill.
    /// Unlike `returnToFullWindow` this intentionally leaves
    /// `isMiniPlayerVisible` untouched: clicking through to a detail page is
    /// not a request to dismiss the mini player, so an always-on-top widget
    /// keeps floating over the now-foregrounded detail view (the Apple Music /
    /// Spotify mini-widget contract).
    ///
    /// Routing through one seam (rather than letting `MiniPlayerView` poke
    /// `navPath` + `NSApp` itself) keeps the activate-then-navigate ordering in
    /// a single testable place and matches `openLyrics` / `navigate(to:)`.
    func openInMainWindowFromMiniPlayer(_ route: Route) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        navigate(to: route)
    }
}
