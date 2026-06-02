import AppKit
import LyrebirdCore
import Observation
import SwiftUI

/// AppKit delegate for the SwiftUI app. Hosts platform plumbing that has no
/// first-class `Scene` equivalent:
///
/// - **Dock menu** (`applicationDockMenu`) — right-click / long-press on
///   the Dock icon surfaces Play/Pause, Next, Previous, and a live list
///   of recent albums so a user can jump back into something without
///   bringing the window forward. See issues #16 / #17.
/// - **Dock tile** — replaces the stock app icon with the current album
///   art wrapped in a thin progress ring (filling in real time) plus a
///   pause overlay while paused, via `DockTileController`. Falls back to a
///   "▶" text badge as a lightweight signal when no track is loaded yet.
///   Restores the stock icon on quit.
/// - **Window tabbing** — opts the app into macOS' automatic window-tab
///   behaviour so `WindowGroup`'s extra windows show up as tabs under the
///   Window menu. See issue #27.
/// - **Sleep / wake hooks** — pauses playback when the system goes to
///   sleep and nudges the core to reconnect on wake so a discovered
///   server doesn't sit on a stale socket. See issue #323.
///
/// The delegate is wired in via `@NSApplicationDelegateAdaptor` from
/// `LyrebirdApp`. It publishes itself on `AppDelegate.shared` right after
/// `applicationDidFinishLaunching` so the SwiftUI side can hand over the
/// live `AppModel` pointer via `bind(appModel:)`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Weak shared pointer so views (that hold a strong reference to the
    /// `AppModel`) can drive the delegate without creating a retain cycle.
    static weak var shared: AppDelegate?

    /// The live app model. Injected from SwiftUI once the scene mounts —
    /// see `bind(appModel:)`. `nil` during the brief gap between
    /// `applicationDidFinishLaunching` and the first `WindowGroup` body
    /// evaluation; the menu / sleep / wake handlers degrade gracefully.
    private weak var appModel: AppModel?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Debounce token for wake-triggered reconnect probes. Cancelled and
    /// replaced on each wake event so rapid lid-open/close cycles (which
    /// fire multiple `didWakeNotification`s in quick succession) only
    /// result in a single probe hitting the server.
    private var wakeProbeTask: Task<Void, Never>?

    /// Long-lived observation loop that tracks `AppModel.status.state` changes
    /// and keeps the dock badge in sync. Started in `bind(appModel:)` and
    /// cancelled in `applicationWillTerminate`. See #322.
    private var dockBadgeTask: Task<Void, Never>?

    /// Owns the custom Dock tile (album art + progress ring + pause overlay).
    /// Throttles its own `display()` calls to ≤1 Hz.
    private let dockTile = DockTileController()

    /// How long to wait after a wake event before probing the server.
    /// 2 s gives the NIC time to associate and the OS time to re-establish
    /// a DHCP / Wi-Fi link before we attempt TCP to the Jellyfin endpoint.
    private let wakeDebounceNanos: UInt64 = 2_000_000_000

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Window tabbing. With this set, `WindowGroup`'s New Window /
        // ⌘N produces a tab instead of a separate floating window on
        // screens that support tabbing. See #27.
        NSWindow.allowsAutomaticWindowTabbing = true

        // Sleep → pause. A laptop that closes its lid shouldn't keep
        // streaming through headphones after wake. See #323.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        // Wake → reconnect. Resume any network-bound work the core
        // needs to re-establish; the audio stream itself stays paused
        // so the user gets a clean resume.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeProbeTask?.cancel()
        dockBadgeTask?.cancel()
        // Drop the custom tile so the Dock shows the stock icon after quit.
        dockTile.uninstall()
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let hasTrack = appModel?.status.currentTrack != nil
        let isPlaying = appModel?.status.state == .playing

        let playPauseItem = NSMenuItem(
            title: isPlaying ? "Pause" : "Play",
            action: #selector(dockTogglePlayPause(_:)),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        playPauseItem.isEnabled = hasTrack
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(
            title: "Next",
            action: #selector(dockSkipNext(_:)),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = hasTrack
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(
            title: "Previous",
            action: #selector(dockSkipPrevious(_:)),
            keyEquivalent: ""
        )
        previousItem.target = self
        previousItem.isEnabled = hasTrack
        menu.addItem(previousItem)

        // Recent albums. Use `jumpBackIn` (the home screen's "last played"
        // shelf) as the source of truth so the dock menu and the window
        // stay in sync. Cap at six so the dock menu stays compact even
        // for heavy listeners.
        if let recent = appModel?.jumpBackIn, !recent.isEmpty {
            menu.addItem(NSMenuItem.separator())

            let header = NSMenuItem(title: "Recent Albums", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for album in recent.prefix(6) {
                let item = NSMenuItem(
                    title: album.name,
                    action: #selector(dockPlayRecentAlbum(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = album.id
                item.toolTip = "\(album.name) — \(album.artistName)"
                menu.addItem(item)
            }
        }

        return menu
    }

    // MARK: - Binding

    /// Hand the delegate a live reference to the `AppModel`. Called once
    /// from the root SwiftUI view as soon as the scene mounts. Idempotent;
    /// re-binding replaces the previous pointer.
    ///
    /// Also (re-)starts the `dockBadgeTask` observation loop so the Dock
    /// badge always reflects the current playback state. See #322.
    @MainActor
    func bind(appModel: AppModel) {
        self.appModel = appModel
        dockBadgeTask?.cancel()
        dockBadgeTask = startDockBadgeObserver(model: appModel)
        // Paint the tile immediately so a session that resumes already-playing
        // shows its art on launch rather than waiting for the first transition.
        refreshDockTile()
    }

    /// Returns a `Task` that loops indefinitely, using `withObservationTracking`
    /// to watch `model.status.state` and refresh the Dock tile whenever
    /// playback starts / pauses / stops. The task is fully cooperative — it
    /// suspends between state changes and does not spin. Per-second progress
    /// updates ride the existing 1 s status poll via `refreshDockTile()`; this
    /// loop only catches the discrete play/pause/stop transitions so the ring
    /// flips its overlay the moment state changes rather than on the next tick.
    @MainActor
    private func startDockBadgeObserver(model: AppModel) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Only `status.state` is read inside the tracking closure, so the
                // loop wakes solely on playback-state transitions rather than on
                // every status mutation (position ticks, queue edits, etc.).
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = model.status.state
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                self?.refreshDockTile()
            }
        }
    }

    /// Rebuild the Dock tile from the current player status. Idempotent and
    /// cheap: the `DockTileController` throttles its own `display()` to ≤1 Hz
    /// and skips redundant redraws, so this is safe to call from both the
    /// state-change observer and the 1 s status poll.
    ///
    /// While a track is loaded the controller installs the custom album-art +
    /// progress-ring tile; when nothing is loaded it tears the tile down and
    /// we fall back to the lightweight "▶" text badge so the user still has a
    /// playing signal during the brief gap before the first track resolves.
    @MainActor
    func refreshDockTile() {
        guard let model = appModel else { return }
        let status = model.status
        let hasTrack = status.currentTrack != nil

        if hasTrack, let track = status.currentTrack {
            // No text badge competes with the custom tile.
            NSApp.dockTile.badgeLabel = nil
            dockTile.update(
                hasTrack: true,
                isPaused: status.state == .paused,
                position: status.positionSeconds,
                duration: status.durationSeconds,
                artworkURL: model.imageURL(
                    for: track.albumId ?? track.id,
                    tag: track.imageTag,
                    maxWidth: 256
                ),
                seed: track.name
            )
        } else {
            dockTile.update(
                hasTrack: false,
                isPaused: false,
                position: 0,
                duration: 0,
                artworkURL: nil,
                seed: DockTileSnapshot.placeholderSeed
            )
            NSApp.dockTile.badgeLabel = status.state == .playing ? "▶" : nil
        }
    }

    // MARK: - Sleep / wake

    private func handleSleep() {
        Task { @MainActor [weak self] in
            self?.appModel?.audio.pause()
        }
    }

    private func handleWake() {
        // Cancel any in-flight probe from a previous wake event so
        // a rapid lid-open/close cycle doesn't pile up parallel requests.
        wakeProbeTask?.cancel()
        wakeProbeTask = Task { @MainActor [weak self] in
            // Brief hold: give the NIC time to re-associate before probing.
            try? await Task.sleep(nanoseconds: self?.wakeDebounceNanos ?? 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.appModel?.reconnectIfNeeded()
        }
    }

    // MARK: - Dock menu actions

    @objc private func dockTogglePlayPause(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.togglePlayPause()
        }
    }

    @objc private func dockSkipNext(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.skipNext()
        }
    }

    @objc private func dockSkipPrevious(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.skipPrevious()
        }
    }

    @objc private func dockPlayRecentAlbum(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            guard let model = self?.appModel else { return }
            if let album = model.jumpBackIn.first(where: { $0.id == id }) {
                model.play(album: album)
            }
        }
    }
}

// MARK: - AppModel sleep/wake shim

extension AppModel {
    /// Called by the AppDelegate after the system wakes from sleep. Probes
    /// `GET /System/Info/Public` (via `core.probeServer`) against the stored
    /// server URL to verify the connection is still healthy:
    ///
    /// - **401 / not authenticated**: `probeServer` hits the unauthenticated
    ///   `/System/Info/Public`, so token revocation during sleep is detected
    ///   not here but by the authenticated `refreshJumpBackIn` /
    ///   `refreshRecentlyPlayed` / `refreshRecentlyAdded` calls below, which
    ///   surface the re-auth sheet via their own `handleAuthError`. The
    ///   `LyrebirdError` auth-variant catch here is a guard for any future
    ///   authenticated probe.
    /// - **Network / 5xx error**: the server is temporarily unreachable;
    ///   `serverReachability.noteFailure()` updates the unreachable banner.
    /// - **Success**: `serverReachability.noteSuccess()` clears any stale
    ///   failure window and schedules a lightweight home refresh so the
    ///   carousels are up-to-date after a long sleep.
    ///
    /// No-ops when there is no active session — nothing to reconnect.
    @MainActor
    @objc func reconnectIfNeeded() {
        guard session != nil, !serverURL.isEmpty else { return }
        let url = serverURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // `probeServer` hits `/System/Info/Public` — lightweight,
                // unauthenticated, sufficient to confirm TCP + HTTP health.
                _ = try await Task.detached(priority: .utility) { [core] in
                    try core.probeServer(url: url)
                }.value
                // Server answered — clear any stale failure window and
                // refresh the home shelves so stale data doesn't sit on
                // screen after a long sleep.
                serverReachability.noteSuccess()
                await refreshJumpBackIn()
                await refreshRecentlyPlayed()
                await refreshRecentlyAdded()
            } catch {
                switch error as? LyrebirdError {
                case .NotAuthenticated, .Auth, .AuthExpired:
                    markAuthExpired()
                default:
                    if ServerReachability.shouldCount(error: error) {
                        serverReachability.noteFailure()
                    }
                }
            }
        }
    }
}
