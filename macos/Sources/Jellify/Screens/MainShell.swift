import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Native two-column shell (#1, #4). The sidebar lives in the
            // OS-managed column so users get the standard show/hide
            // affordance + draggable separator for free; the detail column
            // wraps the existing screen switch in a `NavigationStack` driven
            // by `model.navPath`. `model.screen` remains the source of truth
            // for which root view renders during B2 — `navPath` is empty in
            // production until B3 migrates the call sites that still write
            // `model.screen` over to `model.navPath.append(...)`.
            NavigationSplitView {
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
                            // Stub destinations during B2 — the path is
                            // empty in production because every navigation
                            // currently goes through `model.screen`. B3
                            // wires real call sites and these handlers
                            // dispatch on `Route` instead of `Screen`.
                            .navigationDestination(for: AppModel.Route.self) { route in
                                routeDestination(for: route)
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
    /// During B2 the path is always empty in production because navigation
    /// still writes `model.screen`; these handlers exist so the
    /// `NavigationStack` is wired and ready for B3 to migrate the call
    /// sites. Each case mirrors the equivalent `model.screen` arm in
    /// `mainContent` so the eventual cutover is mechanical.
    @ViewBuilder
    private func routeDestination(for route: AppModel.Route) -> some View {
        switch route {
        case .home:
            HomeView()
        case .discover:
            DiscoverView()
        case .library:
            LibraryView()
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
        case .discover:
            DiscoverView()
        case .search:
            SearchView()
        case .album(let id):
            AlbumDetailView(albumID: id)
        case .artist(let id):
            ArtistDetailView(artistID: id)
        case .playlist(let id):
            PlaylistView(playlistID: id)
        case .nowPlaying:
            NowPlayingView()
        default:
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
    /// user has navigated.
    private var breadcrumbSegments: [String] {
        var segments: [String] = ["Jellify"]
        switch model.screen {
        case .home:
            segments.append("Home")
        case .discover:
            segments.append("Discover")
        case .library:
            segments.append("Library")
        case .search:
            segments.append("Search")
        case .album(let id):
            segments.append("Library")
            segments.append("Albums")
            if let album = model.albums.first(where: { $0.id == id }) {
                segments.append(album.name)
            } else {
                // Ellipsis is more informative than a section-name-matching
                // literal fallback ("Albums > Album") that reads like a bug.
                segments.append("…")
            }
        case .artist(let id):
            segments.append("Library")
            segments.append("Artists")
            if let artist = model.artists.first(where: { $0.id == id }) {
                segments.append(artist.name)
            } else {
                segments.append("…")
            }
        case .playlist(let id):
            segments.append("Library")
            segments.append("Playlists")
            if let playlist = model.playlist(id: id) {
                segments.append(playlist.name)
            } else {
                segments.append("…")
            }
        case .nowPlaying:
            segments.append("Now Playing")
        case .settings:
            segments.append("Settings")
        }
        return segments
    }

    /// Handles a tap on a breadcrumb segment at `idx`. Navigation is driven by
    /// the current `model.screen` and the tapped index, so the component stays
    /// agnostic of label strings (no brittle title matching). Index 0 is the
    /// root ("Jellify") and always returns to the library. For nested screens
    /// (e.g. album/artist/playlist detail), intermediate indices pop to the
    /// library; the final index is the current location and is a no-op.
    private func navigate(toBreadcrumbDepth idx: Int) {
        // Index 0 is always the root and pops to library.
        guard idx > 0 else {
            model.screen = .library
            return
        }

        switch model.screen {
        case .home, .discover, .library, .search, .settings, .nowPlaying:
            // Shape: ["Jellify", <current>] — only the final index, which is
            // the current location and non-navigable. Nothing to do.
            break
        case .album, .artist, .playlist:
            // Shape: ["Jellify", "Library", "<Albums|Artists|Playlists>", <name>].
            // idx 1 = "Library" and idx 2 = the section both pop to library;
            // idx 3 is the current location and is a no-op.
            if idx < 3 {
                model.screen = .library
            }
        }
    }
}
