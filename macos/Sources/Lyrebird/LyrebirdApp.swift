import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LyrebirdApp: App {
    @State private var model: AppModel

    /// Sparkle 2 auto-update handle. Owned here so the controller's
    /// scheduled-update timer starts at launch and the "Check for Updates…"
    /// menu item can bind to it. No-ops in builds without a real signing key.
    @StateObject private var updater = Updater()

    /// AppKit delegate for the dock menu, sleep / wake observers, and
    /// window-tabbing opt-in. SwiftUI's `Scene` protocol can't express any
    /// of those, so we bridge through the delegate adaptor and hand the
    /// live `AppModel` over once the scene mounts. See `AppDelegate.swift`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Persisted color-scheme mode from the Appearance pane (#263). Read here
    /// so the entire window tree (including the Preferences scene) honours the
    /// user's choice. `oled` resolves to `.dark` until the true-black surface
    /// wash lands alongside the theme engine in #405.
    @AppStorage(AppearanceKeys.mode) private var modeRaw: String = AppearanceMode.dark.rawValue

    init() {
        FontRegistration.register()
        do {
            _model = State(wrappedValue: try AppModel())
        } catch {
            fatalError("Failed to initialize Lyrebird core: \(error)")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        (AppearanceMode(rawValue: modeRaw) ?? .dark).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup("Lyrebird") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(preferredColorScheme)
                .task { appDelegate.bind(appModel: model) }
                // Re-request notification authorization on launch if the user
                // already opted in, so track-change banners work without
                // re-toggling. No-ops when the preference is off.
                .task { NotificationManager.shared.requestAuthorizationIfNeeded() }
                // Publish the current window's `AppModel` as a focused
                // scene value so `@FocusedValue(\.appModel)` readers
                // (e.g. future menu commands that live outside the
                // WindowGroup body) can resolve against whichever window
                // is key. Single-window apps only need this to be ready
                // for a multi-window future. See `FocusedValueKey+AppModel`.
                .focusedSceneValue(\.appModel, model)
        }
        .defaultSize(width: 1280, height: 820)
        // Hide the system title bar so the sidebar runs edge-to-edge
        // under the traffic lights (Apple Music / Music for Classical /
        // Reeder / Spark layout). `.hiddenTitleBar` flips
        // `titlebarAppearsTransparent` and adds `.fullSizeContentView`
        // to the window's `styleMask`, letting our content flow into
        // the title-bar strip. The unified toolbar style stays in place
        // so any `.toolbar {}` content still lands in the right strip.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            LyrebirdCommands(model: model, updater: updater)
        }

        // Native Preferences scene. macOS wires up ⌘, and menu item for free.
        // Window restoration: on macOS 14+ `WindowGroup` + `Settings`
        // handle size/position persistence for us, so we intentionally do
        // not register a `SceneStorage` or persist a frame manually. See #17.
        Settings {
            PreferencesView()
                .environment(model)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowResizability(.contentSize)

        // Detached Mini Player. A dedicated single-instance `Window`
        // (not a `WindowGroup`) so ⌘⌥P toggles exactly one mini player rather
        // than spawning duplicates. The window's borderless / vibrancy /
        // rounded / always-on-top chrome is applied by `MiniPlayerView`'s
        // embedded `MiniPlayerWindowConfigurator` since `Scene` modifiers
        // can't reach those `NSWindow` knobs. `.contentSize` resizability
        // honours the view's 280–480pt width band.
        Window("mini_player.window.title", id: MiniPlayerScene.id) {
            MiniPlayerView()
                .environment(model)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 120)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)

        // Keyboard Shortcuts help window. A dedicated single-instance
        // `Window` (not a `WindowGroup`) so Help > Keyboard Shortcuts / ⌘?
        // toggles exactly one panel rather than spawning duplicates. It renders
        // the `AppShortcuts.all` catalog — the same map the menu bar mirrors —
        // as a searchable two-column list. No `AppModel` needed: the catalog is
        // static data, so the window stays open and useful even signed out.
        Window("shortcuts.window.title", id: AppShortcuts.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentSize)

        // Status-bar "Now Playing" extra. A `MenuBarExtra` lives in the system
        // menu bar, so this transport surface stays reachable even when every
        // Lyrebird window is closed or the app is hidden. The `.window`
        // style lets the panel render artwork + a rich transport cluster rather
        // than a flat text menu; the label reflects play state at a glance.
        // Clicking "Open Lyrebird" routes through `returnToFullWindow`, which
        // activates the app and raises the main window.
        MenuBarExtra {
            MenuBarNowPlaying()
                .environment(model)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            MenuBarNowPlayingLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Scene identity for the detached Mini Player window. Centralised so
/// the scene declaration and the `openWindow` / `dismissWindow` call sites in
/// `RootView` agree on the id.
enum MiniPlayerScene {
    static let id = "mini-player"
}

// MARK: - FocusedValue plumbing
//
// SwiftUI `FocusedValues` expose per-scene state to commands and menus
// that live outside the view hierarchy. Registering an `AppModel` key
// here lets us add menu items in the future (e.g. a Now-Playing MenuBar
// extra) that talk to the correct window's model without us having to
// thread a singleton through.
private struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

/// Full macOS menu bar. See issues #5 (menu structure), #6 (Playback menu),
/// #7 (tab & find shortcuts), #8 (media keys — doc-only; routed through
/// `MediaSession`/`MPRemoteCommandCenter`, see #29/#31), #104 (global shortcut
/// map), and #105 (list arrow navigation; rows own the actual key handlers).
///
/// The transport commands live under a dedicated **Playback** `CommandMenu`
/// that slots in between View and Window per macOS HIG (see e.g. Music.app).
/// Navigation overrides hang off the standard `.sidebar` group; **File** and
/// **View** get additive entries so system defaults (New Window from
/// `WindowGroup`, Show Tab Bar, Enter Full Screen) stay intact.
///
/// Every Button disables itself when the underlying action isn't meaningful
/// (e.g. skipping next while no track is loaded or switching tabs while
/// signed out), so the menu's enabled state is a cheap visual map of what's
/// currently actionable.
///
/// Media keys (F7/F8/F9) and Bluetooth/AVRCP transport are intentionally NOT
/// registered here — `MediaSession` already owns the single
/// `MPRemoteCommandCenter` registration (introduced in #527) and routes those
/// events through `MediaSessionDelegate` into the same `togglePlayPause()` /
/// `skipNext()` / `skipPrevious()` entry points this menu uses. Double-binding
/// would race the two registrations. See `MediaSession.configureRemoteCommands`.
struct LyrebirdCommands: Commands {
    @Bindable var model: AppModel
    @ObservedObject var updater: Updater

    /// Opens the Keyboard Shortcuts help scene. `@Environment(\.openWindow)`
    /// resolves inside a `Commands` body on macOS 14+, letting the Help menu
    /// item summon the single-instance `Window(id: AppShortcuts.windowID)`.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // MARK: App menu — Check for Updates… (Sparkle, #864)
        //
        // Standard Sparkle placement: just after the "About Lyrebird" item in
        // the app menu. The item disables itself while a check is in flight (or
        // when Sparkle is inactive in unsigned/dev builds).
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updater: updater)
        }

        // MARK: File (⌘N for New Playlist)
        //
        // Replaces SwiftUI's default "New Window" item so ⌘N creates a
        // playlist (matching Spotify / Apple Music conventions) rather
        // than spawning a duplicate app window. Wired into
        // `AppModel.beginNewPlaylist`, which flips the sidebar into edit
        // mode on a fresh placeholder row. See BATCH-06b / #71.
        CommandGroup(replacing: .newItem) {
            Button("menu.file.new_playlist") {
                model.selectTab(.library)
                model.beginNewPlaylist()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.session == nil)
        }

        // MARK: - View menu additions (sidebar + queue inspector + full screen)
        //
        // SwiftUI already provides Enter Full Screen (⌘⌃F) via the default
        // windowing commands. We append optional panel toggles next to the
        // built-in items so the user can cycle between the full shell and a
        // more focused view.
        CommandGroup(after: .sidebar) {
            Divider()

            Button("menu.view.show_sidebar") {
                // TODO(#5): bind to a published `isSidebarVisible` flag on
                // AppModel and have `MainShell` conditionally mount `Sidebar()`.
                // The menu item is reserved now so the shortcut exists.
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(true)

            Button("menu.view.show_queue") {
                // TODO(#272): the queue drawer lands with BATCH-07's rich
                // inspector. Menu item reserved so ⌘⌥Q resolves to something
                // discoverable once the panel exists.
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
            .disabled(true)

            Divider()

            // MARK: Tab shortcuts (#7)
            //
            // The sidebar currently has three top-level destinations:
            // Home, Library, Search. `model.screen` is the source of truth
            // and re-assigning it triggers the same `MainShell` animation
            // as clicking the sidebar.
            Button("menu.nav.home") {
                model.selectTab(.home)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(model.session == nil)

            Button("menu.nav.library") {
                model.selectTab(.library)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(model.session == nil)

            Button("menu.nav.search") {
                model.selectTab(.search)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(model.session == nil)

            Divider()

            // ⌘F is context-sensitive. On a detail view that owns an
            // in-content search bar (Artist / Playlist) it focuses that
            // *scoped* filter; everywhere else it falls through to the global
            // Search surface. `requestFind()` routes between the two.
            Button("menu.nav.find") {
                model.requestFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.session == nil)

            // ⌘⇧F always jumps to the full global Search surface and focuses
            // its field, regardless of which detail view is on screen.
            // `focusSearch()` sets both the legacy `requestSearchFocus`
            // one-shot and the `isSearchFieldFocused` mirror. See #7 / #104.
            Button("menu.nav.find_global") {
                model.focusSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            // ⌘L jumps to the full Now Playing view and toggles back to the
            // previous screen when pressed again (matches Music.app feel).
            // See #89 / #6 and the Playback menu's mirror shortcut.
            Button("menu.nav.now_playing") {
                toggleNowPlaying()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.session == nil)

            // ⌘U opens the full-page Play Queue view and toggles back when
            // pressed again (same reversible-drill feel as ⌘L Now Playing).
            // See #81.
            Button("menu.nav.play_queue") {
                model.toggleFullQueue()
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(model.session == nil)

            // Command Palette (#305). Full-screen ⌘K overlay with library
            // search + static action verbs. Toggling the flag here and
            // letting `RootView` mount the overlay keeps the palette
            // independent of whichever screen is currently focused.
            Button("menu.nav.command_palette") {
                model.isCommandPaletteOpen.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.session == nil)

            // New Instant Mix… (#327). Opens the seed-picker sheet so the
            // user can search for and pick any track / album / artist /
            // genre to seed a radio station, rather than relying on the
            // implicit "currently playing" seed the Discover/Home CTAs use.
            // ⌘⌥M keeps it adjacent to ⌘K's palette in the home-row cluster.
            Button("menu.nav.instant_mix") {
                model.presentInstantMixPicker()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(model.session == nil)

            Divider()

            // Mini Player. ⌘⌥P toggles the detached, borderless
            // transport window. A `Toggle` (not a `Button`) bound to
            // `isMiniPlayerVisible` so AppKit draws a checkmark next to the
            // item whenever the window is open — a `CommandMenu` `Button`
            // can't render that state. Flipping the bound flag is enough:
            // `RootView` observes `isMiniPlayerVisible` and drives the
            // matching `openWindow` / `dismissWindow("mini-player")` call,
            // and the ⌘W / Window > Close path syncs the flag back via the
            // window's `willCloseNotification` observer (see `RootView`).
            Toggle("menu.view.mini_player", isOn: Binding(
                get: { model.isMiniPlayerVisible },
                set: { _ in model.toggleMiniPlayer() }
            ))
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(model.session == nil)
        }

        // MARK: - Playback menu (#6)
        //
        // Every transport affordance has a keyboard equivalent here so the
        // whole app is usable from the home row. Media keys (F7/F8/F9) and
        // Bluetooth AVRCP events hit the same `AppModel` methods via
        // `MediaSession` — see file header for why they aren't re-registered.
        CommandMenu("menu.playback") {
            Button(playPauseLabelKey) {
                model.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.next") {
                model.skipNext()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(model.status.currentTrack == nil)

            Button("menu.playback.previous") {
                model.skipPrevious()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.volume_up") {
                let next = min(1.0, model.status.volume + 0.05)
                model.setVolume(next)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("menu.playback.volume_down") {
                let next = max(0.0, model.status.volume - 0.05)
                model.setVolume(next)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("menu.playback.seek_forward") {
                model.seek(by: 10)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(model.status.currentTrack == nil)

            Button("menu.playback.seek_back") {
                model.seek(by: -10)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.stop") {
                model.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model.status.currentTrack == nil)

            Button("menu.nav.now_playing") {
                toggleNowPlaying()
            }
            .disabled(model.session == nil)
        }

        // MARK: - Window menu additions
        //
        // SwiftUI's default Window menu already ships Minimize (⌘M), Zoom,
        // Bring All to Front, and (on macOS 14+) the tiling entries. We add
        // an explicit Tile Window action so the command is discoverable
        // even when the system hasn't surfaced the OS-level tiling item.
        CommandGroup(after: .windowArrangement) {
            Button("menu.window.tile_left") {
                tileCurrentWindow(edge: .left)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.control, .option, .command])
            .disabled(NSApp.keyWindow == nil)

            Button("menu.window.tile_right") {
                tileCurrentWindow(edge: .right)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.control, .option, .command])
            .disabled(NSApp.keyWindow == nil)
        }

        // MARK: - Help menu (replace default "Lyrebird Help" placeholder)
        //
        // SwiftUI's default "Help" menu points at an empty Apple-help book.
        // We redirect it to the repo's issue tracker so the menu item
        // actually leads somewhere useful.
        CommandGroup(replacing: .help) {
            Button("menu.help.lyrebird") {
                if let url = URL(string: "https://github.com/skalthoff/lyrebird-desktop") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            // Keyboard Shortcuts help window. ⌘? — on US layouts that's
            // ⌘⇧/, which is what SwiftUI binds when you ask for "?" with the
            // command modifier, matching Doppler's "Keyboard Shortcuts" item.
            Button("menu.help.keyboard_shortcuts") {
                openWindow(id: AppShortcuts.windowID)
            }
            .keyboardShortcut("?", modifiers: .command)

            // Re-open the first-run feature tour (coach marks) on demand
            // (#113). Disabled while signed out — the tour points at the main
            // shell's affordances, which only exist once the user is in.
            // `MainShell` observes `model.isFeatureTourPresented` and mounts
            // the overlay.
            Button("menu.help.show_tour") {
                model.presentFeatureTour()
            }
            .disabled(model.session == nil)

            Divider()

            // Export Diagnostic Bundle… (#455). Writes a sanitized .zip of
            // recent logs + non-secret metadata for bug reports. All shaping
            // and redaction lives in `DiagnosticBundle`; this is just the
            // save-panel hop.
            Button("menu.help.export_diagnostics") {
                exportDiagnosticBundle()
            }
        }

        // Note: ⌘, (Preferences), ⌘Q (Quit), Hide / Hide Others / Services,
        // Cut / Copy / Paste / Undo / Redo / Select All, New Window (⌘N),
        // Close Window (⌘W), Minimize (⌘M), Zoom, Enter Full Screen (⌘⌃F),
        // Bring All to Front, and the app's About box are all provided
        // automatically by SwiftUI + AppKit when a `Settings` scene and
        // `WindowGroup` are declared. We intentionally DON'T replace those
        // groups — overriding them would mean losing the system-standard
        // behavior (e.g. AppKit's responder-chain text editing actions).
    }

    /// Catalog key for the Play / Pause toggle in the Playback menu. Returned
    /// as `LocalizedStringKey` so SwiftUI looks up the translation from
    /// `Localizable.xcstrings` rather than rendering the literal key.
    private var playPauseLabelKey: LocalizedStringKey {
        model.status.state == .playing ? "menu.playback.pause" : "menu.playback.play"
    }

    /// Toggle behaviour for the "Go to Now Playing" menu item: first press
    /// navigates to the full player, second press pops back. Shared between
    /// the View / Library ⌘L entry and the Playback ⌘L mirror so either
    /// menu gesture does the same thing. See #89.
    private func toggleNowPlaying() {
        // The full player is a drill destination on `navPath`. If it's the
        // top of the stack already, pop it; otherwise push it.
        if model.isShowingNowPlaying {
            model.navPath.removeLast()
        } else {
            model.navPath.append(AppModel.Route.nowPlaying)
        }
    }

    /// Present a save panel and write a sanitized diagnostic `.zip` (#455).
    /// Reads version/build from the bundle and the (host-redacted) server URL
    /// from the live `AppModel`; everything else — log collection, the
    /// settings allowlist, and redaction — is handled by `DiagnosticBundle`.
    /// Surfaces a failure via `model.errorMessage` rather than a swallowed
    /// `try?`, matching the playlist-mutation error contract.
    private func exportDiagnosticBundle() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0 (dev)"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Bundle"
        panel.nameFieldStringValue = "Lyrebird-Diagnostics-\(DiagnosticBundle.filenameStamp(Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DiagnosticBundle.export(
                to: url,
                version: version,
                build: build,
                serverURL: model.serverURL
            )
        } catch {
            model.errorMessage = "Could not export diagnostic bundle: \(error.localizedDescription)"
        }
    }

    /// Tile the current key window to the left or right half of its screen.
    /// Uses plain AppKit frame math rather than the 14+ tiling APIs so the
    /// command works on `.macOS(.v14)` without the Stage-Manager-dependent
    /// `NSWindow.tileWindow(_:)` path. If no key window is available this
    /// is a no-op.
    private enum TileEdge { case left, right }
    private func tileCurrentWindow(edge: TileEdge) {
        guard
            let window = NSApp.keyWindow,
            let screen = window.screen ?? NSScreen.main
        else { return }
        let vf = screen.visibleFrame
        let halfWidth = floor(vf.width / 2)
        let originX: CGFloat = edge == .left ? vf.minX : vf.minX + halfWidth
        let newFrame = NSRect(x: originX, y: vf.minY, width: halfWidth, height: vf.height)
        window.setFrame(newFrame, display: true, animate: true)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Open / dismiss the detached Mini Player scene. These environment
    // actions are only resolvable inside a `View` body, so `RootView` (which
    // is always mounted) owns the bridge from `model.isMiniPlayerVisible` to
    // the actual window. The ⌘⌥P command and the mini player's own "return"
    // affordances only flip the flag; the `.onChange` below performs the
    // window operation.
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Sticky "first-launch is done" flag. On a fresh install this is
    /// `false` and the app lands on `OnboardingView`. After the user either
    /// completes the flow or taps "Skip, explore offline" it becomes
    /// `true` permanently so subsequent signed-out launches go straight
    /// to `LoginView`. See #291 / #292 / #293.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        Group {
            if model.isRestoringSession {
                // One-shot loading state on cold start while the core attempts
                // to rehydrate a session from persisted settings + keychain.
                // We don't want to briefly flash `LoginView` on every launch
                // just because the restore hasn't completed yet.
                RestoreLoadingView()
            } else if !hasCompletedOnboarding {
                // First launch. `OnboardingView` owns the flow across all
                // three steps; it flips `hasCompletedOnboarding` itself once
                // the user either lands in the sync step and hits Continue
                // to Home, or skips offline from the connect step. Keeping
                // `OnboardingView` mounted *even after* a successful login
                // matters: the first-sync step needs to stay on screen
                // while the library is fetching, which happens against a
                // live `model.session`.
                OnboardingView()
            } else if model.session == nil {
                LoginView()
            } else {
                MainShell()
            }
        }
        .background(Theme.bg)
        // Full-screen chrome handling (#20). Mounted as an invisible
        // background bridge so it reaches the host `NSWindow` and auto-hides
        // the unified toolbar + menu bar on enter / restores the
        // hidden-title-bar layout on exit — neither of which has a `Scene`
        // hook. All decision logic lives in the testable `FullScreenChrome`
        // reducer; this only installs the AppKit observers. See
        // `FullScreenChromeController`.
        .background(FullScreenChromeObserver())
        // Login <-> main shell swap (and restore-loading <-> either) is
        // instant under Reduce Motion.
        .animation(reduceMotion ? nil : .default, value: model.session != nil)
        .animation(reduceMotion ? nil : .default, value: model.isRestoringSession)
        .animation(reduceMotion ? nil : .default, value: hasCompletedOnboarding)
        // Command Palette (#305). Owned at the root so the overlay
        // floats above every screen — Home, Library, Now Playing, and
        // any modal sheet. The palette itself pulls `AppModel` out of
        // the environment to drive search + action dispatch.
        .overlay {
            if model.isCommandPaletteOpen && model.session != nil {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.isCommandPaletteOpen)
        .task {
            // Kick off session restore exactly once, on the first appearance
            // of the root view. `attemptRestoreSession` guards against
            // re-entry, so a `.task` firing on every scene rebuild is safe.
            await model.attemptRestoreSession()
        }
        // Bridge the Mini Player flag to the actual scene. Driving the
        // window from a single `@Observable` flag keeps the ⌘⌥P checkmark,
        // the settings-menu "return", and the open window from ever drifting
        // apart.
        .onChange(of: model.isMiniPlayerVisible) { _, visible in
            if visible {
                openWindow(id: MiniPlayerScene.id)
            } else {
                dismissWindow(id: MiniPlayerScene.id)
            }
        }
        // Sign-out should never leave a mini player floating over LoginView.
        .onChange(of: model.session == nil) { _, signedOut in
            if signedOut, model.isMiniPlayerVisible {
                model.isMiniPlayerVisible = false
            }
        }
        // Keep the flag honest when the window closes on its own. The
        // mini player is a chromeless `Window`, but AppKit still routes ⌘W /
        // Window > Close through its automatic Close-Window responder, which
        // orders the window out *without* touching `isMiniPlayerVisible`. Left
        // unsynced the menu Toggle would stay checked and the next ⌘⌥P would
        // try to `dismissWindow` an already-closed scene (a no-op), so the
        // user has to press it twice to reopen. Observe `willCloseNotification`,
        // match the mini-player window by the scene id SwiftUI stamps onto
        // `NSWindow.identifier`, and clear the flag — but only when the model
        // still thinks it's visible, so a model-initiated `dismissWindow`
        // (which already cleared the flag) doesn't recurse.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard
                model.isMiniPlayerVisible,
                let window = note.object as? NSWindow,
                window.identifier?.rawValue == MiniPlayerScene.id
            else { return }
            model.isMiniPlayerVisible = false
        }
    }
}

/// Minimal cold-start splash shown while the core rehydrates a persisted
/// session in the background. Kept lightweight on purpose — the restore pass
/// completes on a userInitiated Task and this view exists solely to avoid a
/// LoginView flash on every launch for a signed-in user.
private struct RestoreLoadingView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("app.name")
                    .font(Theme.font(40, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.ink3)
            }
        }
    }
}
