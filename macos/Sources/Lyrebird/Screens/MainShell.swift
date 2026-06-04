import SwiftUI

/// The three top-level regions Switch Control's "Group items" scan steps
/// through, in scan order. `MainShell`'s `.accessibilityLabel` modifiers and
/// the grouping tests both read these raw values, so the acceptance criteria
/// stay a single source of truth instead of duplicated string literals.
enum SwitchControlGroup: String, CaseIterable {
    case sidebar = "Sidebar"
    case content = "Content"
    case playerBar = "Player Bar"
}

struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives `NavigationSplitView`'s sidebar visibility so the toolbar
    /// `Toggle Sidebar` item has somewhere to write. SwiftUI animates the
    /// column collapse / reveal for us when this changes. Seeded from
    /// `persistedSidebarRaw` / the Appearance preference on first appearance
    /// and mirrored back into `@SceneStorage` so the layout survives a
    /// relaunch — see `restoreWindowState()` and `WindowStateStore` (#10).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Auto-hide bookkeeping (#318). Tracks whether the current collapse was
    /// width-driven so it (and only it) is eligible for auto-restore when the
    /// window widens again. `userDidOverride` mirrors the persisted flag below
    /// so the reducer can read both in one value.
    @State private var sidebarAutoHide = SidebarAutoHide.State()

    /// Persisted manual-override flag (#318). Set once the user clicks the
    /// `Toggle Sidebar` toolbar button, after which width-driven auto-hide
    /// stops overriding their choice. Survives relaunch via `@AppStorage`.
    @AppStorage(SidebarDefaults.userDidOverrideAutoHideKey)
    private var userDidOverrideAutoHide: Bool = false

    /// Persisted main-window content state (#10). The OS already restores the
    /// window's size/position via `WindowGroup` (#17); these three reach the
    /// things it can't — the last-viewed tab, the sidebar column visibility,
    /// and the queue inspector — via `@SceneStorage` so each is keyed to the
    /// window scene rather than leaking globally across windows. All decode /
    /// fallback logic lives in the testable `WindowStateStore`; these hold
    /// only the stable raw strings.
    @SceneStorage(WindowStateKeys.screen) private var persistedScreenRaw: String = ""
    @SceneStorage(WindowStateKeys.sidebar) private var persistedSidebarRaw: String = ""
    @SceneStorage(WindowStateKeys.inspector) private var persistedInspectorRaw: String = ""

    /// The Appearance pane's `Sidebar` preference (`PreferencesAppearance`).
    /// Read here so a window with no persisted per-scene visibility yet opens
    /// honouring the user's chosen default — wiring the previously UI-only
    /// `AppearanceSidebar` enum into real behaviour (#10).
    @AppStorage(AppearanceKeys.sidebar) private var sidebarPreferenceRaw: String = AppearanceSidebar.visible.rawValue

    /// First-run feature-tour flag (#113). `false` until the coach-mark tour
    /// has been shown once; flipped `true` when it closes (either path). The
    /// key is owned by `FeatureTourSeenStore`, so this `@AppStorage` and the
    /// store read/write the same on-disk bool. Distinct from
    /// `hasCompletedOnboarding`: that gates the *connect* flow, this gates the
    /// post-connect *teaching* overlay.
    @AppStorage(FeatureTourSeenStore.seenKey) private var hasSeenFeatureTour: Bool = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Native two-column shell (#1, #4). The sidebar lives in the
            // OS-managed column so users get the standard show/hide
            // affordance + draggable separator for free; the detail column
            // wraps the active root tab in a `NavigationStack` driven by
            // `model.navPath`. `model.screen` is the active root tab and
            // drives `mainContent`; drill destinations (album / artist /
            // playlist / nowPlaying) live as `Route` entries on `navPath`
            // and render via the `.navigationDestination` handler below.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // Tab order (#334): sidebar gets first focus, then the
                // detail column, then the queue inspector / player bar.
                Sidebar()
                    // Switch Control "Group items" grouping. Wrapping the
                    // whole rail in a single labelled container lets Switch
                    // Control scan "Sidebar" as one top-level group and
                    // descend on demand, instead of stepping through every
                    // nav row, stat row, and playlist one at a time.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(SwitchControlGroup.sidebar.rawValue)
                    // Sort priority must be applied AFTER the grouping
                    // container so it lands on the container itself, not the
                    // wrapped child. Otherwise the #334 tab-traversal order
                    // (sidebar first) is read off the inner element and the
                    // container falls back to default priority.
                    .accessibilitySortPriority(100)
                    // Drag-resizable sidebar (#318). The 252pt design width is
                    // the ideal; users can drag the separator between a 200pt
                    // floor (brand mark + nav rows stay legible) and a 360pt
                    // ceiling (so the rail can't swallow the detail column).
                    .navigationSplitViewColumnWidth(min: 200, ideal: 252, max: 360)
            } detail: {
                HStack(spacing: 0) {
                    NavigationStack(path: $model.navPath) {
                        contentColumn
                            // Drill destinations dispatch on `Route` so the
                            // active root tab (driven by `model.screen` and
                            // rendered inside `contentColumn`) stays in
                            // place while the user pushes album / artist /
                            // playlist / nowPlaying detail pages on top.
                            .navigationDestination(for: AppModel.Route.self) { route in
                                routeDestination(for: route)
                            }
                            // Native unified toolbar (#3 / #343). NavigationStack
                            // owns built-in back navigation (swipe, ⌘[ and ⌘←),
                            // so we surface a sidebar toggle and a global search
                            // field rather than re-implementing the back button.
                            // Every item carries `.accessibilityLabel` so
                            // VoiceOver / Voice Control can target them.
                            .toolbar {
                                ToolbarItem(placement: .navigation) {
                                    Button {
                                        toggleSidebarManually()
                                    } label: {
                                        Image(systemName: "sidebar.left")
                                    }
                                    .help("Toggle Sidebar")
                                    .accessibilityLabel("Toggle Sidebar")
                                }

                                ToolbarItem(placement: .principal) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(Theme.ink2)
                                        TextField("Search", text: $model.searchPageQuery)
                                            .textFieldStyle(.plain)
                                            .font(Theme.font(13, weight: .medium))
                                            .foregroundStyle(Theme.ink)
                                            .frame(maxWidth: 280)
                                            .onSubmit {
                                                // Hand off to the Search page so
                                                // `runFullSearch` and the existing
                                                // results UI light up. ⌘F still
                                                // routes through `focusSearch()`.
                                                model.selectTab(.search)
                                                Task { await model.runFullSearch(query: model.searchPageQuery, scope: model.activeSearchScope) }
                                            }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Theme.border, lineWidth: 1)
                                    )
                                    .cornerRadius(6)
                                    .accessibilityLabel("Search")
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Switch Control "Group items" grouping. The active page
                    // + its toolbar scan as one "Content" group so Switch
                    // Control offers Sidebar / Content / Player Bar as the
                    // three top-level groups, then descends into the page
                    // body (track list / grid) on demand.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(SwitchControlGroup.content.rawValue)
                    // Sort priority must be applied AFTER the grouping
                    // container so it lands on the container, keeping the
                    // #334 tab order (content second, after the sidebar).
                    .accessibilitySortPriority(90)

                    // Right-side Queue Inspector (#79). Hidden by default;
                    // toggled by Cmd+Opt+Q or a future PlayerBar button
                    // (BATCH-07b). Kept at 320pt so it doesn't crowd the
                    // detail column on a 13" laptop but is wide enough for
                    // readable track titles. Mounted inside the detail
                    // column rather than promoted to a 3-column
                    // NavigationSplitView so the diff stays minimal.
                    if model.isQueueInspectorOpen {
                        Divider().background(Theme.border)
                        QueueInspector()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .accessibilitySortPriority(70)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.isQueueInspectorOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Persistent player bar comes last in the tab traversal so
            // Tab / Shift+Tab lands in the main content first. See #334.
            // Anchored outside the NavigationSplitView so it spans the full
            // window width (sidebar + detail) like the previous custom
            // shell did.
            PlayerBar()
                // Switch Control "Group items" grouping. PlayerBar already
                // wraps itself in a single labelled container
                // (.accessibilityElement(children: .contain) +
                // .accessibilityLabel("Playback controls")), so we must NOT
                // add a second container here — doing so nests two groups and
                // makes Switch Control's group scan descend through an empty
                // outer "Player Bar" group before reaching the transport. The
                // sort priority is the only thing the shell needs to set,
                // pinning the player bar last in the #334 tab order.
                .accessibilitySortPriority(50)
        }
        .background(Theme.bg)
        // Width-driven sidebar auto-hide (#318). A zero-cost GeometryReader in
        // the background reports the shell's width; `onChange` runs the pure
        // `SidebarAutoHide` reducer to collapse the rail on narrow windows and
        // restore it when they widen. The reducer no-ops once the user has
        // manually toggled the sidebar, so auto-hide never fights an explicit
        // choice. Driven off the *outer* VStack so the measured width spans the
        // whole window (sidebar + detail), matching the threshold's intent.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { applySidebarAutoHide(width: proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        applySidebarAutoHide(width: newWidth)
                    }
            }
        )
        // Restore the persisted window content state once, on first
        // appearance of the shell (#10). `WindowStateStore` owns the decode +
        // fallback rules; here we just apply the resolved values. Runs after
        // the scene mounts so `@SceneStorage` has rehydrated.
        .onAppear { restoreWindowState() }
        // Persist the last-viewed tab whenever it changes so the next launch
        // lands where the user left off.
        .onChange(of: model.screen) { _, newScreen in
            persistedScreenRaw = newScreen.persistedRawValue
        }
        // Persist the sidebar column visibility on every change — the toolbar
        // toggle, the native separator drag/collapse, and ⌘⌃S all write
        // `columnVisibility`, so observing it here captures every path. Also
        // mirror the showing/hidden state into `AppModel` so the View ▸ "Show
        // Sidebar" menu item renders an accurate checkmark (audit L251).
        .onChange(of: columnVisibility) { _, newValue in
            persistedSidebarRaw = newValue.persistedRawValue
            model.isSidebarVisible = (newValue != .detailOnly)
        }
        // View ▸ "Show Sidebar" (⌘⌥S) routes through `AppModel` because the menu
        // can't reach this view's private `columnVisibility`. Each request bumps
        // a counter; run the same manual-toggle path the toolbar button uses so
        // the auto-hide override bookkeeping stays consistent (audit L251).
        .onChange(of: model.sidebarToggleRequest) { _, _ in
            toggleSidebarManually()
        }
        // Persist the queue inspector visibility (#79 surface) so it reopens
        // with the window if the user left it open.
        .onChange(of: model.isQueueInspectorOpen) { _, isOpen in
            persistedInspectorRaw = isOpen ? "true" : "false"
        }
        // Announce track changes to VoiceOver (#342). Keyed on the track id
        // so it fires for user skips and autoplay alike but not for
        // non-identity status churn (position / volume polls). The stop
        // transition (id -> nil) is intentionally ignored — there is no new
        // track to announce. Debounce + non-interrupting posting live in
        // `AppModel.announceTrackChange`.
        .onChange(of: model.status.currentTrack?.id) { _, newId in
            guard newId != nil, let track = model.status.currentTrack else { return }
            model.announceTrackChange(to: track)
        }
        // Cmd+Opt+Q toggles the queue inspector (#79). The shortcut now lives
        // on the View ▸ "Show Queue" menu `Toggle` (audit L251), so the former
        // hidden 1×1 button that also bound ⌘⌥Q has been removed to avoid a
        // duplicate key-equivalent registration racing the menu item.
        // First-run feature tour (coach marks) — see #113. Auto-appears once
        // on the first launch after connect (`!hasSeenFeatureTour`) and can be
        // replayed any time via Help ▸ "Show Tour"
        // (`model.isFeatureTourPresented`). `MainShell` only renders for a live
        // session, so the tour can never collide with the connect onboarding.
        // The overlay persists the seen flag itself on close; we clear the
        // explicit re-open flag here so a second Help invocation re-triggers.
        .overlay {
            if shouldShowFeatureTour {
                FeatureTourOverlay(onClose: {
                    model.isFeatureTourPresented = false
                })
                .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: shouldShowFeatureTour
        )
        // Auth-expired prompt — see #303. One-shot modal; on "Sign in" we
        // drop the stored token and clear the session so `RootView` routes
        // back to `LoginView`, which prefills the remembered server URL and
        // username so the user only needs to re-enter their password.
        .sheet(isPresented: $model.authExpired) {
            AuthExpiredSheet {
                model.forgetToken()
                model.session = nil
                model.authExpired = false
            }
        }
        // Track-info modal — read-only metadata sheet driven by
        // `AppModel.trackInfoSubject`. Any screen can call
        // `model.showTrackInfo(track:)` (notably `TrackContextMenu`'s
        // "Get Info" item and the global ⌘I shortcut) and the sheet is
        // mounted here so it works regardless of which screen is active.
        // See #95.
        .sheet(item: $model.trackInfoSubject) { track in
            TrackInfoSheet(track: track) {
                model.trackInfoSubject = nil
            }
        }
        // Instant Mix seed-picker — search/pick a track, album, artist, or
        // genre to seed a radio station (#327). Driven by
        // `AppModel.isShowingInstantMixPicker`; summoned from the View ▸
        // "New Instant Mix…" menu command (⌘⌥M). Mounted here so it floats
        // over whichever screen is active.
        .sheet(isPresented: $model.isShowingInstantMixPicker) {
            InstantMixSheet(model: model)
        }
        // Playlist-delete confirmation — see #98 / #131. Triggered from
        // `PlaylistContextMenu` via `AppModel.confirmDelete(playlist:)`.
        .confirmationDialog(
            model.playlistPendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: .init(
                get: { model.playlistPendingDelete != nil },
                set: { if !$0 { model.cancelDeletePending() } }
            ),
            titleVisibility: .visible,
            presenting: model.playlistPendingDelete
        ) { _ in
            Button("common.delete", role: .destructive) { model.performDeletePending() }
            Button("common.cancel", role: .cancel) { model.cancelDeletePending() }
        } message: { playlist in
            // Playlist name is user data — interpolate without attempting to
            // localize it. The surrounding "This will permanently delete … "
            // scaffolding lives in the catalog under `playlist.delete.message`;
            // we prepend the name in quotes so the dialog still echoes which
            // playlist is about to be deleted, then show the localized
            // explainer on the next line.
            Text(verbatim: "\u{201C}\(playlist.name)\u{201D}\n")
                + Text("playlist.delete.message")
        }
    }

    /// Whether the feature-tour overlay should be on screen right now (#113).
    /// True on the very first launch after connect (the persisted seen flag is
    /// still `false`) or whenever the user explicitly re-opens it from
    /// Help ▸ "Show Tour". Either path renders the same `FeatureTourOverlay`,
    /// which records the seen flag when it closes.
    private var shouldShowFeatureTour: Bool {
        !hasSeenFeatureTour || model.isFeatureTourPresented
    }

    /// Toolbar `Toggle Sidebar` handler (#318). Flips `columnVisibility` and
    /// records that the user has taken explicit control, so width-driven
    /// auto-hide stops overriding their choice. The override is persisted via
    /// `@AppStorage` so the rail stays where they put it across relaunches.
    private func toggleSidebarManually() {
        columnVisibility = (columnVisibility == .all) ? .detailOnly : .all
        sidebarAutoHide = SidebarAutoHide.registeringManualToggle(sidebarAutoHide)
        userDidOverrideAutoHide = true
    }

    /// Runs the pure `SidebarAutoHide` reducer for the latest window `width`
    /// and applies its decision (#318). Seeds the reducer's `userDidOverride`
    /// from the persisted `@AppStorage` flag so a manual choice from a prior
    /// launch is honoured. Only assigns `columnVisibility` when the reducer
    /// asks for a transition, so a redundant write never stomps an in-flight
    /// collapse / reveal animation.
    private func applySidebarAutoHide(width: CGFloat) {
        var state = sidebarAutoHide
        state.userDidOverride = userDidOverrideAutoHide
        let decision = SidebarAutoHide.decide(
            width: width,
            visibility: columnVisibility,
            state: state
        )
        sidebarAutoHide = decision.state
        if let newVisibility = decision.visibility, newVisibility != columnVisibility {
            columnVisibility = newVisibility
        }
    }

    /// Apply the persisted window content state on first appearance (#10).
    /// Pulls the resolved values out of `WindowStateStore` (which encapsulates
    /// every fallback rule, including the Appearance `Sidebar` preference) and
    /// writes them into the live state. Idempotent and cheap: re-running it
    /// would just re-apply the same values, but `.onAppear` only fires it once
    /// per shell mount.
    ///
    /// Restoring the tab routes through `selectTab(_:)` rather than assigning
    /// `model.screen` directly so any drill stack from a stale launch is
    /// cleared — the user should land on the tab root, not a half-restored
    /// detail page whose subject may no longer exist.
    private func restoreWindowState() {
        let restoredScreen = WindowStateStore.restoredScreen(persistedRaw: persistedScreenRaw)
        if model.screen != restoredScreen {
            model.selectTab(restoredScreen)
        }

        columnVisibility = WindowStateStore.initialSidebarVisibility(
            persistedRaw: persistedSidebarRaw,
            preferenceRaw: sidebarPreferenceRaw
        )
        // Seed the menu mirror so View ▸ "Show Sidebar" shows the right
        // checkmark from the first frame (audit L251).
        model.isSidebarVisible = (columnVisibility != .detailOnly)

        let restoredInspector = WindowStateStore.restoredInspectorVisible(persistedRaw: persistedInspectorRaw)
        if model.isQueueInspectorOpen != restoredInspector {
            model.isQueueInspectorOpen = restoredInspector
        }
    }

    /// Routes a `Route` value pushed onto `navPath` to the matching screen.
    /// In practice only the drill cases (album / artist / playlist /
    /// nowPlaying) are pushed — root-tab cases are kept on `Route` for
    /// future deep-linking and render the same view as `mainContent`.
    @ViewBuilder
    private func routeDestination(for route: AppModel.Route) -> some View {
        switch route {
        case .home:
            HomeView()
        case .discover:
            DiscoverView()
        case .radio:
            RadioView()
        case .library:
            LibraryView()
        case .favorites:
            FavoritesView()
        case .search:
            SearchView()
        case .settings:
            // Settings have a dedicated `Settings` scene in `LyrebirdApp`
            // and aren't a destination inside the main shell. Kept here so
            // the switch is exhaustive over `Route`.
            EmptyView()
        case .album(let id):
            AlbumDetailView(albumID: id)
        case .artist(let id):
            ArtistDetailView(artistID: id)
        case .playlist(let id):
            PlaylistView(playlistID: id)
        case .genre(let g):
            GenreDetailView(genre: g)
        case .nowPlaying:
            NowPlayingView()
        case .fullQueue:
            FullQueueView()
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(spacing: 0) {
            // Logical tab order inside the content column (#334):
            // mainContent receives focus before the breadcrumb/top bar.
            // Without the explicit sort priority, SwiftUI would walk the
            // view tree top-to-bottom and hit the breadcrumbs first, which
            // pushes the user through non-primary chrome before the page
            // body.
            topBar
                .accessibilitySortPriority(70)
            if !model.network.isOnline {
                OfflineBanner(onRetry: { model.retryNetwork() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Only surface the server-unreachable banner when the system is
            // actually online — otherwise the offline banner already explains
            // why requests are failing and stacking both would be noisy.
            if model.network.isOnline && !model.serverReachability.isServerReachable {
                ServerUnreachableBanner(onRetry: { model.retryServer() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Screen swaps should be instant when Reduce Motion is on.
                // Otherwise, keep SwiftUI's default implicit behavior.
                .animation(reduceMotion ? nil : .default, value: model.screen)
                .accessibilitySortPriority(80)
        }
        .animation(.easeInOut(duration: 0.2), value: model.network.isOnline)
        .animation(.easeInOut(duration: 0.2), value: model.serverReachability.isServerReachable)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.screen {
        case .home:
            HomeView()
        case .library:
            LibraryView()
        case .favorites:
            FavoritesView()
        case .discover:
            DiscoverView()
        case .radio:
            RadioView()
        case .search:
            SearchView()
        case .settings:
            // Settings have a dedicated `Settings` scene in `LyrebirdApp`
            // and aren't a destination inside the main shell. Falling
            // through to Library keeps the detail column populated if
            // `screen` is somehow `.settings` while the Settings scene is
            // closed.
            LibraryView()
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack {
            Breadcrumbs(segments: breadcrumbSegments) { idx in
                navigate(toBreadcrumbDepth: idx)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(Theme.bgAlt.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// Builds the breadcrumb trail for the current screen. The root segment is
    /// always "Lyrebird"; subsequent segments describe where in the app the
    /// user has navigated. Drill destinations live on `navPath`; root tabs
    /// live on `model.screen`.
    private var breadcrumbSegments: [String] {
        var segments: [String] = ["Lyrebird"]
        // Root tab segment. Settings is exposed via the dedicated scene and
        // not breadcrumbed.
        switch model.screen {
        case .home: segments.append("Home")
        case .discover: segments.append("Discover")
        case .radio: segments.append("Radio")
        case .library: segments.append("Library")
        case .favorites: segments.append("Favorites")
        case .search: segments.append("Search")
        case .settings: segments.append("Settings")
        }

        // Drill segments. The current top of `navPath` is what's actually
        // rendered; we anchor the trail at "Library > <section>" because
        // every drill destination today is reachable from the Library
        // hierarchy regardless of which root tab launched it.
        switch model.navPath.last {
        case .album(let id)?:
            if model.screen != .library { segments.append("Library") }
            segments.append("Albums")
            if let name = model.breadcrumbAlbumName(id: id) {
                segments.append(name)
            } else {
                // Ellipsis is more informative than a section-name-matching
                // literal fallback ("Albums > Album") that reads like a bug.
                segments.append("…")
            }
        case .artist(let id)?:
            if model.screen != .library { segments.append("Library") }
            segments.append("Artists")
            if let name = model.breadcrumbArtistName(id: id) {
                segments.append(name)
            } else {
                segments.append("…")
            }
        case .playlist(let id)?:
            if model.screen != .library { segments.append("Library") }
            segments.append("Playlists")
            if let playlist = model.playlist(id: id) {
                segments.append(playlist.name)
            } else {
                segments.append("…")
            }
        case .genre(let g)?:
            if model.screen != .library { segments.append("Library") }
            segments.append("Genres")
            segments.append(g.name)
        case .nowPlaying?:
            segments.append("Now Playing")
        case .fullQueue?:
            segments.append("Play Queue")
        case .home?, .discover?, .radio?, .library?, .favorites?, .search?, .settings?, nil:
            break
        }
        return segments
    }

    /// Handles a tap on a breadcrumb segment at `idx`. Navigation is driven
    /// by the current screen and `navPath`, so the component stays agnostic
    /// of label strings (no brittle title matching). Index 0 is the root
    /// ("Lyrebird") and clears the drill stack while staying on the current
    /// tab. For nested screens, intermediate indices pop back to the current
    /// tab root; the final index is the current location and is a no-op.
    private func navigate(toBreadcrumbDepth idx: Int) {
        // Index 0 is the root ("Lyrebird") — clear the drill stack and stay
        // on whichever tab the user is already on.
        guard idx > 0 else {
            model.navPath = []
            model.selectTab(model.screen)
            return
        }

        // No drill on the stack: the trail is ["Lyrebird", <tab>] and the
        // only navigable index (0) was handled above. Higher indices are
        // the current location.
        guard !model.navPath.isEmpty else { return }

        // Drill on the stack: trail is ["Lyrebird", "<tab>", "<section>",
        // <name>]. idx 1 = tab root and idx 2 = the section both pop the
        // drill; idx 3 is the current location.
        if idx < 3 {
            model.selectTab(model.screen)
        }
    }
}
