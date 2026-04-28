import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives `NavigationSplitView`'s sidebar visibility so the toolbar
    /// `Toggle Sidebar` item has somewhere to write. SwiftUI animates the
    /// column collapse / reveal for us when this changes.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                    .accessibilitySortPriority(100)
                    // Pin the sidebar to the existing 252pt design width so
                    // NavigationSplitView's auto-sizing doesn't expand the
                    // column past what the brand mark + nav rows assume.
                    .navigationSplitViewColumnWidth(252)
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
                                        columnVisibility = (columnVisibility == .all)
                                            ? .detailOnly
                                            : .all
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
                .accessibilitySortPriority(50)
        }
        .background(Theme.bg)
        // Cmd+Opt+Q toggles the queue inspector (#79). Hung off a zero-sized
        // hidden button so the shortcut is global to `MainShell` without
        // requiring a visible chrome affordance — the visible toggle will
        // land in PlayerBar in BATCH-07b. `.hidden()` alone is not enough
        // (SwiftUI elides hidden buttons from the responder chain), so the
        // button has a 1×1 clear frame that stays non-interactive.
        .background(
            Button("menu.view.toggle_queue") { model.toggleQueueInspector() }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
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
        case .library:
            LibraryView()
        case .favorites:
            FavoritesView()
        case .search:
            SearchView()
        case .settings:
            // Settings have a dedicated `Settings` scene in `JellifyApp`
            // and aren't a destination inside the main shell. Kept here so
            // the switch is exhaustive over `Route`.
            EmptyView()
        case .album(let id):
            AlbumDetailView(albumID: id)
        case .artist(let id):
            ArtistDetailView(artistID: id)
        case .playlist(let id):
            PlaylistView(playlistID: id)
        case .nowPlaying:
            NowPlayingView()
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
        case .search:
            SearchView()
        case .settings:
            // Settings have a dedicated `Settings` scene in `JellifyApp`
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
    /// always "Jellify"; subsequent segments describe where in the app the
    /// user has navigated. Drill destinations live on `navPath`; root tabs
    /// live on `model.screen`.
    private var breadcrumbSegments: [String] {
        var segments: [String] = ["Jellify"]
        // Root tab segment. Settings is exposed via the dedicated scene and
        // not breadcrumbed.
        switch model.screen {
        case .home: segments.append("Home")
        case .discover: segments.append("Discover")
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
            if let album = model.albums.first(where: { $0.id == id }) {
                segments.append(album.name)
            } else {
                // Ellipsis is more informative than a section-name-matching
                // literal fallback ("Albums > Album") that reads like a bug.
                segments.append("…")
            }
        case .artist(let id)?:
            if model.screen != .library { segments.append("Library") }
            segments.append("Artists")
            if let artist = model.artists.first(where: { $0.id == id }) {
                segments.append(artist.name)
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
        case .nowPlaying?:
            segments.append("Now Playing")
        case .home?, .discover?, .library?, .favorites?, .search?, .settings?, nil:
            break
        }
        return segments
    }

    /// Handles a tap on a breadcrumb segment at `idx`. Navigation is driven
    /// by the current screen and `navPath`, so the component stays agnostic
    /// of label strings (no brittle title matching). Index 0 is the root
    /// ("Jellify") and clears the drill stack while staying on the current
    /// tab. For nested screens, intermediate indices pop back to the current
    /// tab root; the final index is the current location and is a no-op.
    private func navigate(toBreadcrumbDepth idx: Int) {
        // Index 0 is the root ("Jellify") — clear the drill stack and stay
        // on whichever tab the user is already on.
        guard idx > 0 else {
            model.navPath = []
            model.selectTab(model.screen)
            return
        }

        // No drill on the stack: the trail is ["Jellify", <tab>] and the
        // only navigable index (0) was handled above. Higher indices are
        // the current location.
        guard !model.navPath.isEmpty else { return }

        // Drill on the stack: trail is ["Jellify", "<tab>", "<section>",
        // <name>]. idx 1 = tab root and idx 2 = the section both pop the
        // drill; idx 3 is the current location.
        if idx < 3 {
            model.selectTab(model.screen)
        }
    }
}
