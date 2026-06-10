import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LyrebirdApp: App {
    /// The live view model, or the error that prevented its construction.
    /// `AppModel()` boots the Rust core, which can fail on a corrupt local
    /// database. Rather than `fatalError` (which bricks the app on a
    /// recoverable problem), we hold the failure and render a dedicated
    /// recovery scene with "Reset Local Data" / "Export Diagnostics"
    /// affordances. See `CoreInitFailureView` (audit L31).
    @State private var modelResult: Result<AppModel, Error>

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

    /// Persisted brand-theme preset from the Appearance pane (#405). Read here
    /// so a theme switch re-keys every window's content `.id` (`themeRaw`),
    /// forcing the re-render that re-reads `Theme.primary` / `Theme.accent`
    /// from the newly-selected `ThemePreset`. `Theme.currentPreset` resolves the
    /// actual colours; this property exists only to drive that refresh.
    @AppStorage(AppearanceKeys.theme) private var themeRaw: String = AppearanceTheme.purple.rawValue

    /// Persistent "Show in menu bar" (Settings ▸ General). Read here because
    /// the `MenuBarExtra(isInserted:)` binding — the single owner of menu-bar
    /// presence since `MenuBarController` was retired (#984) — resolves
    /// visibility from this toggle plus the transient while-playing input.
    @AppStorage(PreferencesGeneral.showInMenuBarKey)
    private var showInMenuBar: Bool = false

    /// Transient "Show in menu bar while playing" (Settings ▸ Notifications).
    /// AND'd with live playback state before feeding `MenuBarVisibility.resolve`.
    @AppStorage(NotificationPreference.showInMenuBarWhilePlayingKey)
    private var showInMenuBarWhilePlaying: Bool = false

    init() {
        FontRegistration.register()
        // Load runtime feature flags from flags.json before constructing the
        // model so flag values are readable immediately.
        Task { @MainActor in FeatureFlags.shared.loadFromDisk() }
        // Capture success or failure instead of crashing. A failed core init
        // (e.g. a corrupt on-disk DB) is recoverable, so the body renders
        // `CoreInitFailureView` rather than calling `fatalError`.
        _modelResult = State(wrappedValue: Result { try AppModel() })
    }

    private var preferredColorScheme: ColorScheme? {
        (AppearanceMode(rawValue: modeRaw) ?? .dark).preferredColorScheme
    }

    /// The successfully-constructed model, or `nil` if core init failed.
    /// `SceneBuilder` can't branch (no `buildEither`), so rather than swap whole
    /// scene trees we keep one flat tree: the primary window branches *in its
    /// View body* between the app shell and the recovery screen, and the
    /// model-backed secondary windows / commands guard on this optional. See
    /// audit L31.
    private var model: AppModel? {
        if case .success(let m) = modelResult { return m }
        return nil
    }

    /// The error from a failed `AppModel()` / core construction, if any.
    private var initError: Error? {
        if case .failure(let e) = modelResult { return e }
        return nil
    }

    var body: some Scene {
        // Read playback state eagerly so the scene body registers an
        // Observation dependency on it — the menu-bar extra's `isInserted`
        // binding below must re-resolve when playback starts or stops, not
        // only when one of the two `@AppStorage` toggles moves.
        let isPlaying = model?.status.state == .playing

        // Primary window. The scene is always declared; only its *content*
        // branches — the full shell when the core came up, or the recovery
        // screen (reset / diagnostics) when it didn't, replacing the old
        // `fatalError`. Keeping the scenes unconditional (and guarding inside
        // their View/Commands closures, which can branch) sidesteps
        // `SceneBuilder`'s lack of conditional support. See `CoreInitFailureView`
        // (audit L31).
        // Primary window group, given an explicit id so File ▸ "New Window"
        // (#11) can summon another instance via `openWindow(id:)`. A
        // `WindowGroup` already supports multiple concurrent windows — every
        // instance mounts the same `RootView` against the shared `AppModel`, so
        // a second window shares playback / queue / library automatically. The
        // id is the *only* change needed to re-enable that; see
        // `MainWindowScene` and the New Window command in `LyrebirdCommands`.
        WindowGroup("Lyrebird", id: MainWindowScene.id) {
            primaryWindowContent
                // Re-key on the brand-theme preset so a Theme switch tears down
                // and rebuilds the tree, re-reading `Theme.primary`/`accent`
                // from the new preset (#405). RootView's `.task`s guard re-entry,
                // so the rebuild is safe.
                .id(themeRaw)
        }
        .defaultSize(width: 1280, height: 820)
        // Hide the system title bar so the sidebar runs edge-to-edge under the
        // traffic lights. `.hiddenTitleBar` flips `titlebarAppearsTransparent`
        // and adds `.fullSizeContentView`, letting content flow into the
        // title-bar strip; the unified toolbar style keeps `.toolbar {}` content
        // in the right strip.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // The app menus only make sense with a live model; on the failure
            // path they're omitted and the recovery window keeps the standard
            // system menus. `CommandsBuilder` supports this `if let`.
            if let model {
                LyrebirdCommands(model: model, updater: updater)
            }
        }

        // Native Preferences scene. macOS wires up ⌘, and the menu item for
        // free. On macOS 14+ `WindowGroup` + `Settings` handle size/position
        // persistence, so we don't persist a frame manually. See #17.
        Settings {
            if let model {
                PreferencesView()
                    .environment(model)
                    .preferredColorScheme(preferredColorScheme)
            }
        }
        .windowResizability(.contentSize)

        // Detached Mini Player. A single-instance `Window` (not a `WindowGroup`)
        // so ⌘⌥P toggles exactly one mini player rather than spawning
        // duplicates. The borderless / vibrancy / rounded / always-on-top chrome
        // is applied by `MiniPlayerView`'s embedded
        // `MiniPlayerWindowConfigurator` since `Scene` modifiers can't reach
        // those `NSWindow` knobs. `.contentSize` honours the 280–480pt band.
        Window("mini_player.window.title", id: MiniPlayerScene.id) {
            if let model {
                MiniPlayerView()
                    .environment(model)
                    .preferredColorScheme(preferredColorScheme)
                    .id(themeRaw)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 120)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)

        // Keyboard Shortcuts help window. A single-instance `Window` so Help >
        // Keyboard Shortcuts / ⌘? toggles exactly one panel. It renders the
        // static `AppShortcuts.all` catalog, so it stays useful even signed out
        // and on the core-init failure path (no `AppModel` needed).
        Window("shortcuts.window.title", id: AppShortcuts.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(preferredColorScheme)
                .id(themeRaw)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentSize)

        // Debug panel (#448). A single-instance `Window` opened via ⌘⇧D so
        // it toggles rather than spawning duplicates. Requires a live `AppModel`
        // to snapshot state; guards on `model` so the window stays inert on the
        // core-init failure path. `RootView` bridges `model.isDebugPanelOpen` to
        // the actual `openWindow` / `dismissWindow` call site.
        Window("Debug Panel", id: AppModel.debugPanelWindowID) {
            if let model {
                DebugPanelView()
                    .environment(model)
                    .preferredColorScheme(preferredColorScheme)
            }
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentSize)

        // Dedicated About window (#25). `AboutView` reads version / credits from
        // `AboutInfo` and the connected-server host from the live `AppModel`, so
        // it needs the model in its environment.
        Window("about.window.title", id: AboutView.windowID) {
            if let model {
                AboutView()
                    .environment(model)
                    .preferredColorScheme(preferredColorScheme)
                    .id(themeRaw)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Status-bar "Now Playing" extra. Stays reachable even when every
        // Lyrebird window is closed or the app is hidden. The `.window` style
        // renders artwork + a rich transport cluster; the label reflects play
        // state. "Open Lyrebird" routes through `returnToFullWindow`, which
        // activates the app and raises the main window.
        //
        // Presence is owned by `isInserted:` (#984): the persistent
        // Settings ▸ General toggle pins the icon; the Settings ▸ Notifications
        // "while playing" toggle surfaces it transiently during playback.
        // Precedence lives in `MenuBarVisibility.resolve` (unit-tested).
        // The system writes `false` through the binding when the user ⌘-drags
        // the icon out of the menu bar — honour that as "stop showing this"
        // by clearing both toggles, so the icon doesn't pop straight back in
        // on the next track. `true` writes are ignored: insertion is always
        // derived from the preferences, never forced from the menu-bar side.
        MenuBarExtra(isInserted: Binding(
            get: {
                MenuBarVisibility.resolve(
                    playing: showInMenuBarWhilePlaying && isPlaying,
                    persistent: showInMenuBar
                )
            },
            set: { inserted in
                guard !inserted else { return }
                showInMenuBar = false
                showInMenuBarWhilePlaying = false
            }
        )) {
            if let model {
                MenuBarNowPlaying()
                    .environment(model)
                    .preferredColorScheme(preferredColorScheme)
            }
        } label: {
            menuBarExtraLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// The primary window's content, branching on whether the core constructed.
    @ViewBuilder
    private var primaryWindowContent: some View {
        if let model {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(preferredColorScheme)
                .task { appDelegate.bind(appModel: model) }
                // Re-request notification authorization on launch if the user
                // already opted in, so track-change banners work without
                // re-toggling. No-ops when the preference is off.
                .task { NotificationManager.shared.requestAuthorizationIfNeeded() }
                // Publish the current window's `AppModel` as a focused scene
                // value so `@FocusedValue(\.appModel)` readers resolve against
                // whichever window is key. See `FocusedValueKey+AppModel`.
                .focusedSceneValue(\.appModel, model)
        } else if let initError {
            // Recoverable core-init failure: show the reset / diagnostics
            // recovery screen instead of crashing (audit L31).
            CoreInitFailureView(error: initError)
                .frame(minWidth: 480, minHeight: 420)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    /// Label for the status-bar extra. Falls back to the plain "playing" glyph
    /// on the failure path so the menu-bar item still has a sensible label.
    @ViewBuilder
    private var menuBarExtraLabel: some View {
        if let model {
            MenuBarNowPlayingLabel()
                .environment(model)
        } else {
            Image(systemName: "music.note")
        }
    }
}

/// Scene identity for the detached Mini Player window. Centralised so
/// the scene declaration and the `openWindow` / `dismissWindow` call sites in
/// `RootView` agree on the id.
enum MiniPlayerScene {
    static let id = "mini-player"
}

/// Scene identity for the primary app window's `WindowGroup` (#11). Giving the
/// group an explicit id lets the File ▸ "New Window" command summon another
/// instance via `openWindow(id:)`. `WindowGroup` natively supports any number
/// of live windows; the only reason a second one couldn't be opened before was
/// that `CommandGroup(replacing: .newItem)` repurposed ⌘N for "New Playlist"
/// and dropped SwiftUI's default New Window item along with it. Every window
/// mounts the same `RootView` against the shared singleton `AppModel`, so
/// playback, queue, and the library stay unified across windows by
/// construction — see `LyrebirdCommands` for the (shared-state) navigation
/// caveat.
enum MainWindowScene {
    static let id = "main"
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
/// Navigation overrides hang off the standard `.sidebar` group; **View** gets
/// additive entries so system defaults (Show Tab Bar, Enter Full Screen) stay
/// intact. **File** replaces `.newItem` to bind ⌘N to New Playlist, then adds
/// an explicit New Window command (⌘⇧N) since replacing `.newItem` also drops
/// SwiftUI's default New Window item — see the File section below and #11.
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
        // MARK: App menu — About Lyrebird (#25)
        //
        // Replace the stock AppKit about box with our branded About window.
        // `replacing: .appInfo` keeps the item in its standard top-of-app-menu
        // position; the button summons the single-instance `Window(id:)` scene
        // declared below. The sibling `after: .appInfo` group (Check for
        // Updates…) still anchors right beneath it.
        CommandGroup(replacing: .appInfo) {
            Button("menu.app.about") {
                openWindow(id: AboutView.windowID)
            }
        }

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
            .appShortcut("file.new_playlist", model: model,
                         default: KeyboardShortcut("n", modifiers: .command))
            .disabled(model.session == nil)
        }

        // MARK: File — New Window (⌘⇧N, #11)
        //
        // Re-enables SwiftUI's multiple-window support, which was lost when the
        // group above replaced `.newItem` (and with it the default New Window
        // item) to repurpose ⌘N for New Playlist. Rather than restore the
        // stock item — which would steal ⌘N back — we add an explicit New
        // Window command on ⌘⇧N and summon another instance of the primary
        // `WindowGroup` by id. Each new window mounts the same `RootView`
        // against the shared singleton `AppModel`, so playback / queue /
        // library are unified across windows.
        // Navigation (the active tab + drill stack) is also shared today —
        // both windows mirror `model.screen` / `model.navPath`; see the type
        // doc on `MainWindowScene` and the navigation note in this file's
        // header. Sidebar width / queue-inspector visibility remain per-window
        // because they're `@SceneStorage`-backed (#10).
        //
        // Placed `after: .newItem` so it sits directly beneath New Playlist in
        // the File menu without disturbing that group.
        CommandGroup(after: .newItem) {
            Button("menu.file.new_window") {
                openWindow(id: MainWindowScene.id)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // MARK: - View menu additions (sidebar + queue inspector + full screen)
        //
        // SwiftUI already provides Enter Full Screen (⌘⌃F) via the default
        // windowing commands. We append optional panel toggles next to the
        // built-in items so the user can cycle between the full shell and a
        // more focused view.
        CommandGroup(after: .sidebar) {
            Divider()

            // Show Sidebar (⌘⌥S). A `Toggle` so AppKit draws a checkmark
            // tracking the real rail state. `MainShell` owns the
            // `NavigationSplitView` column visibility (and the width-driven
            // auto-hide reducer), so the menu mirrors its state via
            // `model.isSidebarVisible` and drives changes through
            // `requestSidebarToggle()`, which `MainShell` observes and routes to
            // its existing `toggleSidebarManually()`. See audit L251.
            Toggle("menu.view.show_sidebar", isOn: Binding(
                get: { model.isSidebarVisible },
                set: { _ in model.requestSidebarToggle() }
            ))
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.session == nil)

            // Show Queue (⌘⌥Q). Toggles the right-side Queue Inspector (#79),
            // checkmark tracking `isQueueInspectorOpen`. This menu item owns the
            // ⌘⌥Q shortcut; `MainShell` no longer needs its hidden duplicate.
            // See audit L251.
            Toggle("menu.view.show_queue", isOn: Binding(
                get: { model.isQueueInspectorOpen },
                set: { _ in model.toggleQueueInspector() }
            ))
            .keyboardShortcut("q", modifiers: [.command, .option])
            .disabled(model.session == nil)

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
            .appShortcut("nav.home", model: model,
                         default: KeyboardShortcut("1", modifiers: .command))
            .disabled(model.session == nil)

            Button("menu.nav.library") {
                model.selectTab(.library)
            }
            .appShortcut("nav.library", model: model,
                         default: KeyboardShortcut("2", modifiers: .command))
            .disabled(model.session == nil)

            Button("menu.nav.search") {
                model.selectTab(.search)
            }
            .appShortcut("nav.search", model: model,
                         default: KeyboardShortcut("3", modifiers: .command))
            .disabled(model.session == nil)

            Divider()

            // ⌘F is context-sensitive. On a detail view that owns an
            // in-content search bar (Artist / Playlist) it focuses that
            // *scoped* filter; everywhere else it falls through to the global
            // Search surface. `requestFind()` routes between the two.
            Button("menu.nav.find") {
                model.requestFind()
            }
            .appShortcut("nav.find", model: model,
                         default: KeyboardShortcut("f", modifiers: .command))
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
            .appShortcut("nav.now_playing", model: model,
                         default: KeyboardShortcut("l", modifiers: .command))
            .disabled(model.session == nil)

            // ⌘U opens the full-page Play Queue view and toggles back when
            // pressed again (same reversible-drill feel as ⌘L Now Playing).
            // See #81.
            Button("menu.nav.play_queue") {
                model.toggleFullQueue()
            }
            .appShortcut("nav.play_queue", model: model,
                         default: KeyboardShortcut("u", modifiers: .command))
            .disabled(model.session == nil)

            // Command Palette (#305). Full-screen ⌘K overlay with library
            // search + static action verbs. Toggling the flag here and
            // letting `RootView` mount the overlay keeps the palette
            // independent of whichever screen is currently focused.
            Button("menu.nav.command_palette") {
                model.isCommandPaletteOpen.toggle()
            }
            .appShortcut("nav.command_palette", model: model,
                         default: KeyboardShortcut("k", modifiers: .command))
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
                // Drive to the value SwiftUI requests rather than blindly
                // toggling, so the action can't desync from the checkbox state
                // (audit L365). `RootView.onChange(of: isMiniPlayerVisible)`
                // opens / closes the window from the flag, so setting it is
                // sufficient.
                set: { model.isMiniPlayerVisible = $0 }
            ))
            .appShortcut("view.mini_player", model: model,
                         default: KeyboardShortcut("p", modifiers: [.command, .option]))
            .disabled(model.session == nil)
        }

        // MARK: - Playback menu (#6)
        //
        // Every transport affordance has a keyboard equivalent here so the
        // whole app is usable from the home row. Media keys (F7/F8/F9) and
        // Bluetooth AVRCP events hit the same `AppModel` methods via
        // `MediaSession` — see file header for why they aren't re-registered.
        CommandMenu("menu.playback") {
            // Play / Pause. The bare-Space shortcut is intentionally NOT bound
            // as a menu key equivalent: SwiftUI registers `CommandMenu`
            // shortcuts as `NSMenuItem` key equivalents, which fire ahead of the
            // first responder and so swallowed Space even while a text field was
            // focused (audit L383). The ⎵ binding now lives on an app-wide
            // `NSEvent` monitor (`RootView.playPauseSpaceMonitor`) that passes
            // the event through to focused text editors. The menu item itself
            // stays (clickable, and showing the Play/Pause state) — the label
            // notes ⎵ so the shortcut is still discoverable.
            Button(playPauseLabelKey) {
                model.togglePlayPause()
            }
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.next") {
                model.skipNext()
            }
            .appShortcut("playback.next", model: model,
                         default: KeyboardShortcut(.rightArrow, modifiers: .command))
            .disabled(model.status.currentTrack == nil)

            Button("menu.playback.previous") {
                model.skipPrevious()
            }
            .appShortcut("playback.previous", model: model,
                         default: KeyboardShortcut(.leftArrow, modifiers: .command))
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.volume_up") {
                let next = min(1.0, model.status.volume + 0.05)
                model.setVolume(next)
            }
            .appShortcut("playback.volume_up", model: model,
                         default: KeyboardShortcut(.upArrow, modifiers: .command))

            Button("menu.playback.volume_down") {
                let next = max(0.0, model.status.volume - 0.05)
                model.setVolume(next)
            }
            .appShortcut("playback.volume_down", model: model,
                         default: KeyboardShortcut(.downArrow, modifiers: .command))

            Divider()

            Button("menu.playback.seek_forward") {
                model.seek(by: 10)
            }
            .appShortcut("playback.seek_forward", model: model,
                         default: KeyboardShortcut(.rightArrow, modifiers: [.command, .shift]))
            .disabled(model.status.currentTrack == nil)

            Button("menu.playback.seek_back") {
                model.seek(by: -10)
            }
            .appShortcut("playback.seek_back", model: model,
                         default: KeyboardShortcut(.leftArrow, modifiers: [.command, .shift]))
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("menu.playback.stop") {
                model.stop()
            }
            .appShortcut("playback.stop", model: model,
                         default: KeyboardShortcut(".", modifiers: .command))
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
        // `NSApp.keyWindow` is not an `@Observable` value, so gating
        // `.disabled` on it left the items' enabled state stale — SwiftUI never
        // re-evaluated the body on `didBecomeKey` / `didResignKey` (audit L453).
        // `tileCurrentWindow` already guards on `NSApp.keyWindow` and is a safe
        // no-op when there is none, so the gate is dropped entirely.
        CommandGroup(after: .windowArrangement) {
            Button("menu.window.tile_left") {
                tileCurrentWindow(edge: .left)
            }
            .appShortcut("window.tile_left", model: model,
                         default: KeyboardShortcut(.leftArrow, modifiers: [.control, .option, .command]))

            Button("menu.window.tile_right") {
                tileCurrentWindow(edge: .right)
            }
            .appShortcut("window.tile_right", model: model,
                         default: KeyboardShortcut(.rightArrow, modifiers: [.control, .option, .command]))
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

            // Debug Panel (#448). Hidden affordance — not localised, not in
            // the main menu flow — so ordinary users don't stumble on it.
            // Power users and contributors discover it via ⌘⇧D. Disabled when
            // signed out (the panel only makes sense with a live model/session).
            Button("Debug Panel") {
                openWindow(id: AppModel.debugPanelWindowID)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.session == nil)
        }

        // Note: ⌘, (Preferences), ⌘Q (Quit), Hide / Hide Others / Services,
        // Cut / Copy / Paste / Undo / Redo / Select All, Close Window (⌘W),
        // Minimize (⌘M), Zoom, Enter Full Screen (⌘⌃F), Bring All to Front,
        // and the app's About box are all provided automatically by SwiftUI +
        // AppKit when a `Settings` scene and `WindowGroup` are declared. We
        // intentionally DON'T replace those groups — overriding them would mean
        // losing the system-standard behavior (e.g. AppKit's responder-chain
        // text editing actions). New Window is the exception: replacing
        // `.newItem` for New Playlist (⌘N) drops the stock New Window item, so
        // it's re-added explicitly on ⌘⇧N in the File section above (#11).
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
        .task {
            // Start AirPlay / Bluetooth route scanning so `RouteDetector.shared`
            // can auto-hide the picker when no alternate destinations are nearby.
            // Enabling it here (rather than at `AVRouteDetector` allocation time)
            // defers the radio scan until the app's root view is mounted and the
            // main run-loop is live, matching the lifecycle contract in the
            // AVFoundation docs. The singleton retains detection for the app
            // lifetime; there is no corresponding disable call.
            RouteDetector.shared.isEnabled = true
        }
        // App-wide bare-Space Play/Pause (audit L383). Installed here on the
        // always-mounted root so it covers every screen, and routed through a
        // first-responder check so Space still types into focused text fields
        // instead of toggling playback. Replaces the old menu-level ⎵ shortcut.
        .playPauseSpaceMonitor(
            { model.togglePlayPause() },
            hasCurrentTrack: { model.status.currentTrack != nil }
        )
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
            guard let window = note.object as? NSWindow else { return }
            let id = window.identifier?.rawValue
            if model.isMiniPlayerVisible, id == MiniPlayerScene.id {
                model.isMiniPlayerVisible = false
            }
            // Sync the debug panel flag when its window closes on its own.
            if model.isDebugPanelOpen, id == AppModel.debugPanelWindowID {
                model.isDebugPanelOpen = false
            }
        }
        // Bridge the debug panel flag to the actual scene, matching the
        // mini player bridge above. Opening triggers a snapshot refresh via
        // `DebugPanelView.onAppear`.
        .onChange(of: model.isDebugPanelOpen) { _, open in
            if open {
                openWindow(id: AppModel.debugPanelWindowID)
            } else {
                dismissWindow(id: AppModel.debugPanelWindowID)
            }
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
