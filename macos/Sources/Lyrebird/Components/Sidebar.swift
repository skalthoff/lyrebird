import SwiftUI
@preconcurrency import LyrebirdCore

/// Left-rail navigation + user library summary.
///
/// BATCH-06b (#71 / #75): the "Your Library" block now surfaces the user's
/// playlists inline, with a ⌘N shortcut that drops a fresh row into edit
/// mode, a right-click context menu for rename / duplicate / delete, and a
/// confirmation dialog for destructive delete. All of the wiring lives on
/// `AppModel` (see `sidebarEditingPlaylistId`, `beginNewPlaylist`,
/// `commitSidebarPlaylistEdit`, etc.) so the view stays compact.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    // Contrast-adaptive accent for the active-tab / active-playlist icon
    // foregrounds. Lifts to `accentHot` under Increase Contrast so the
    // accent-tinted glyphs clear 4.5:1 (#888). The 3pt active-tab indicator
    // rail is decorative and keeps the base token.
    @Environment(\.accessibleTheme) private var a11yTheme
    // Dynamic Type size drives row reflow (#338): at the accessibility text
    // sizes the nav / stat / playlist labels would otherwise elide to an
    // unreadable single-line ellipsis, so we let them wrap to a second line.
    // The line-limit decision is factored into the pure `DynamicTypeReflow`
    // helper (shared with `PlayerBar`) so the threshold is unit-tested.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The playlist row currently hovered by the pointer. Used to reveal
    /// the subtle trailing affordances (copying spinner slot); `nil` when
    /// nothing is hovered.
    @State private var hoveredPlaylistId: String?

    // User-toggleable "Your Library" sections. Each defaults to on so
    // the sidebar looks unchanged until the user hides a row in
    // Preferences → Library. Keys live in `LibraryDefaults`.
    @AppStorage(LibraryDefaults.sidebarShowFavoritesKey) private var showFavorites = true
    @AppStorage(LibraryDefaults.sidebarShowAlbumsKey) private var showAlbums = true
    @AppStorage(LibraryDefaults.sidebarShowArtistsKey) private var showArtists = true
    @AppStorage(LibraryDefaults.sidebarShowPlaylistsKey) private var showPlaylists = true

    /// Max lines a nav / stat / playlist label may use at the current text
    /// size (#338): `1` at body sizes (these are short nav nouns by design),
    /// `2` once Dynamic Type reaches the accessibility range so a scaled-up
    /// label wraps gracefully instead of eliding mid-word. `hasContextLabel`
    /// is irrelevant to the sidebar, so we pass `false`.
    private var labelLineLimit: Int {
        DynamicTypeReflow.decide(
            dynamicTypeSize: dynamicTypeSize,
            hasContextLabel: false
        ).sidebarLabelLineLimit
    }
    // #317: collapse state + manual drag-reorder for the Playlists section.
    // `playlistsCollapsed` hides the rows behind the header's disclosure
    // chevron; `playlistOrderRaw` is a CSV of playlist ids that the live list
    // is sorted by (see `PlaylistSidebarOrder`). Both persist via @AppStorage.
    @AppStorage(LibraryDefaults.sidebarPlaylistsCollapsedKey) private var playlistsCollapsed = false
    @AppStorage(LibraryDefaults.sidebarPlaylistOrderKey) private var playlistOrderRaw = ""

    // Disclosure-chevron rotation + row reveal honour Reduce Motion, matching
    // the rest of the component library (e.g. AmbientWash, ArtistCard).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Theme.teal, Theme.primary], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    // Emoji rendered verbatim — a jellyfish is a jellyfish in
                    // every locale; no catalog entry needed.
                    .overlay(Text(verbatim: "🪼").font(.system(size: 16)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("app.name")
                        .font(Theme.font(15, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                    Text("app.subtitle.desktop")
                        .font(Theme.font(9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(1.5)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            // Reserve clearance for the traffic-light controls floating
            // over the sidebar — `.windowStyle(.hiddenTitleBar)` lets our
            // content flow into the title-bar strip, so without this top
            // padding the brand mark would render directly under
            // close / minimize / zoom on a window that doesn't carve out
            // a dedicated title-bar strip.
            .padding(.top, 28)
            .padding(.bottom, 12)

            // Primary nav
            VStack(alignment: .leading, spacing: 2) {
                navItem("house", label: "sidebar.nav.home", screen: .home)
                navItem("music.note.list", label: "sidebar.nav.library", screen: .library)
                navItem("sparkles", label: "sidebar.nav.discover", screen: .discover)
                navItem("dot.radiowaves.left.and.right", label: "sidebar.nav.radio", screen: .radio)
                navItem("magnifyingglass", label: "sidebar.nav.search", screen: .search)
            }
            .padding(.horizontal, 10)

            // Stats header. Keep the aggregate "Albums / Artists / Playlists"
            // summary rows above the playlist list so the count glance stays
            // in place; the playlist list lives as its own section below.
            // The whole "Your Library" stats block is hidden when the
            // user has switched every section off, so the header doesn't
            // float over an empty gap.
            if showFavorites || showAlbums || showArtists || showPlaylists {
                sectionHeader("sidebar.section.your_library")
                VStack(alignment: .leading, spacing: 2) {
                    if showFavorites { favoritesRow }
                    if showAlbums {
                        libRow("square.stack", label: "sidebar.stats.albums", count: model.albumsTotal, tab: .albums)
                    }
                    if showArtists {
                        libRow("person.crop.circle", label: "sidebar.stats.artists", count: model.artistsTotal, tab: .artists)
                    }
                    if showPlaylists {
                        libRow("music.note.list", label: "sidebar.stats.playlists", count: UInt32(model.playlists.count), tab: .playlists)
                    }
                }
                .padding(.horizontal, 10)
            }

            // Playlist list — scrolls independently if the user has a long
            // library. Capped to a reasonable chunk of sidebar height so
            // the server footer stays anchored at the bottom. Hidden with the
            // Playlists section toggle.
            if showPlaylists {
                playlistsSection
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            // Smart playlists (#77 / #238). A distinct, rule-driven section
            // below the regular playlists. Always shown (even empty) so the
            // "New Smart Playlist…" affordance is discoverable; the section
            // is compact and self-contained.
            smartPlaylistsSection
                .padding(.horizontal, 10)
                .padding(.top, 6)

            Spacer(minLength: 0)

            // Server footer
            HStack(spacing: 10) {
                // Status dot + status line reflect *actual* reachability, not
                // a hard-coded "Connected". A live session whose server has
                // gone dark (5xx / refused / timeout, per `ServerReachability`)
                // or a torn-down session reads as disconnected with a muted
                // dot, so the footer can't claim a healthy link during an
                // outage. The album count uses `albumsTotal` (the real library
                // size) rather than `albums.count` (only the pages loaded so
                // far). See `SidebarServerStatus`.
                let status = SidebarServerStatus.decide(
                    hasSession: model.session != nil,
                    isReachable: model.serverReachability.isServerReachable
                )
                let connected = status == .connected
                Circle()
                    .fill(connected ? Theme.teal : Theme.ink3)
                    .frame(width: 8, height: 8)
                    .shadow(color: connected ? Theme.teal.opacity(0.7) : .clear, radius: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.session?.server.name ?? "—")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Group {
                        if connected {
                            Text("sidebar.server.connected \(Int(model.albumsTotal))")
                        } else {
                            Text("sidebar.server.disconnected")
                        }
                    }
                    .font(Theme.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button { model.logout() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Sign out")
                .accessibilityLabel("Sign out")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Divider().background(Theme.border), alignment: .top)
        }
        .frame(width: 252)
        // Translucent Apple-Music-style sidebar material. The `.sidebar`
        // material + `.behindWindow` blending lets the desktop wallpaper
        // tint through while preserving the brand backdrop on top. See
        // issues #9 / #10 / #28.
        .background(
            VisualEffectView(material: .sidebar)
                .overlay(Theme.bgAlt.opacity(0.55))
        )
        // The ⌘N keyboard shortcut lives on the File → "New Playlist"
        // menu item declared in `LyrebirdApp.LyrebirdCommands` so it's
        // discoverable via the menu bar. The "+" button in the playlist
        // list header drives the same action from the sidebar itself.
    }

    // MARK: - Playlist list section

    @ViewBuilder
    private var playlistsSection: some View {
        let editingNew = model.sidebarEditingPlaylistId == AppModel.sidebarNewPlaylistSentinel
        // Sort the live playlists by the persisted manual order. New playlists
        // append; deleted ones prune — see `PlaylistSidebarOrder`.
        let orderedPlaylists = PlaylistSidebarOrder.order(
            model.playlists,
            by: PlaylistSidebarOrder.decode(playlistOrderRaw),
            id: \.id
        )
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // #317: header is a disclosure toggle. Clicking the chevron /
                // label collapses the rows while keeping the header in place.
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        playlistsCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(playlistsCollapsed ? 0 : 90))
                            .frame(width: 10)
                        Text("PLAYLISTS")
                            .font(Theme.font(10, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                            .tracking(1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playlists")
                .accessibilityValue(playlistsCollapsed ? "Collapsed" : "Expanded")
                .accessibilityHint("Show or hide your playlists")
                .accessibilityAddTraits(.isButton)

                Spacer()
                Button { model.beginNewPlaylist() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("New Playlist (⌘N)")
                .disabled(model.session == nil)
                .accessibilityLabel("New Playlist")
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)

            if !playlistsCollapsed {
                // A `List` (rather than a ScrollView+VStack) is what unlocks
                // SwiftUI's native `.onMove` drag-reorder. It's styled down to
                // match the rest of the sidebar: plain rows, no separators, a
                // clear background so the sidebar material shows through.
                List {
                    // In-progress new-playlist row, shown at the top so the
                    // user sees where the new item will land. Not movable.
                    if editingNew {
                        newPlaylistEditRow
                            .listRowSidebarStyling()
                            .moveDisabled(true)
                    }
                    ForEach(orderedPlaylists, id: \.id) { playlist in
                        playlistRow(playlist)
                            .listRowSidebarStyling()
                    }
                    .onMove { source, destination in
                        moveSidebarPlaylists(
                            displayed: orderedPlaylists,
                            from: source,
                            to: destination
                        )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                // Reasonable ceiling so a user with hundreds of playlists
                // doesn't push the server footer off-screen. Scroll handles
                // the overflow.
                .frame(maxHeight: 280)
            }
        }
        // #585: Allow space-bar input in the inline rename / new-playlist
        // TextField even while the global Play/Pause ⎵ shortcut is active.
        .spaceKeyGuardForTextField()
    }

    /// Fold a `.onMove` from the Playlists list into the persisted order
    /// (#317). `displayed` is the already-sorted list the user sees, so the
    /// move offsets line up; we re-encode the whole arrangement to AppStorage.
    /// Pure list math — no server round-trip (see `PlaylistSidebarOrder`).
    private func moveSidebarPlaylists(displayed: [Playlist], from source: IndexSet, to destination: Int) {
        let next = PlaylistSidebarOrder.applyingMove(
            displayedIds: displayed.map(\.id),
            source: source,
            destination: destination
        )
        playlistOrderRaw = PlaylistSidebarOrder.encode(next)
    }

    // MARK: - Smart playlists section (#77 / #238)

    @ViewBuilder
    private var smartPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("SMART PLAYLISTS")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1.5)
                Spacer()
                Button { model.createSmartPlaylist() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("New Smart Playlist")
                .accessibilityLabel("New Smart Playlist")
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)

            if model.smartPlaylists.playlists.isEmpty {
                // Discoverable empty-state row: a single tappable "New Smart
                // Playlist…" entry, matching the issue's ask for a create
                // affordance in the sidebar.
                Button { model.createSmartPlaylist() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 18)
                        Text("New Smart Playlist…")
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(labelLineLimit)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Smart Playlist")
            } else {
                ForEach(model.smartPlaylists.playlists) { playlist in
                    smartPlaylistRow(playlist)
                }
            }
        }
    }

    /// A single smart-playlist row. Mirrors `playlistRow` styling but uses a
    /// distinct gear glyph so smart (rule-driven) playlists read differently
    /// from server playlists. Right-click offers delete; tap navigates.
    @ViewBuilder
    private func smartPlaylistRow(_ playlist: SmartPlaylist) -> some View {
        let isActiveScreen: Bool = {
            if case .smartPlaylist(let id) = model.navPath.last { return id == playlist.id }
            return false
        }()

        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(isActiveScreen ? a11yTheme.accent : Theme.ink2)
                .frame(width: 18)
            Text(playlist.name)
                .font(Theme.font(12, weight: isActiveScreen ? .bold : .medium))
                .foregroundStyle(isActiveScreen ? Theme.ink : Theme.ink2)
                .lineLimit(labelLineLimit)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveScreen ? Theme.surface2 : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.goToSmartPlaylist(playlist) }
        .contextMenu {
            Button { model.goToSmartPlaylist(playlist) } label: {
                Label("Open", systemImage: "arrow.forward")
            }
            Divider()
            Button(role: .destructive) {
                model.smartPlaylists.remove(id: playlist.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(playlist.name)
        .accessibilityAddTraits(isActiveScreen ? .isSelected : [])
    }

    // MARK: - Playlist row (display + inline edit)

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        let isEditing = model.sidebarEditingPlaylistId == playlist.id
        let isActiveScreen: Bool = {
            if case .playlist(let id) = model.navPath.last { return id == playlist.id }
            return false
        }()
        let isCopying = model.sidebarCopyingPlaylistIds.contains(playlist.id)
        let isHovering = hoveredPlaylistId == playlist.id

        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(isActiveScreen ? a11yTheme.accent : Theme.ink2)
                .frame(width: 18)

            if isEditing {
                // #590: Use a dedicated subview so SwiftUI treats the
                // TextField as a stable identity across parent re-renders
                // (e.g. when the playlists array updates mid-rename). The
                // `.id` pin below further anchors it to the editing session.
                SidebarInlineEditField(initialText: playlist.name)
                    .id("rename-\(playlist.id)")
            } else {
                Text(playlist.name)
                    .font(Theme.font(12, weight: isActiveScreen ? .bold : .medium))
                    .foregroundStyle(isActiveScreen ? Theme.ink : Theme.ink2)
                    // #338: a long playlist name elides on one line at body
                    // sizes but is allowed a second line at accessibility
                    // sizes before tail-eliding, so it stays readable.
                    .lineLimit(labelLineLimit)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isCopying {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.ink3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActiveScreen
                        ? Theme.surface2
                        : (isHovering ? Theme.rowHover : .clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredPlaylistId = hovering ? playlist.id : (hoveredPlaylistId == playlist.id ? nil : hoveredPlaylistId)
        }
        .onTapGesture {
            // Tap on a non-editing row navigates. Tapping on a row in edit
            // mode is intercepted by the TextField itself; this branch is a
            // guard for the rare case the gesture fires before the field
            // takes focus.
            guard !isEditing else { return }
            model.goToPlaylist(playlist)
        }
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .accessibilityLabel(playlist.name)
        .accessibilityAddTraits(isActiveScreen ? .isSelected : [])
    }

    // MARK: - Inline edit TextField (shared by Cmd+N and Rename)

    @ViewBuilder
    private var newPlaylistEditRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(a11yTheme.accent)
                .frame(width: 18)
            // #590: stable subview identity for the new-playlist field too.
            SidebarInlineEditField(initialText: "")
                .id("rename-\(AppModel.sidebarNewPlaylistSentinel)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func navItem(_ icon: String, label: LocalizedStringKey, screen: AppModel.Screen) -> some View {
        let active = model.screen == screen && model.navPath.isEmpty
        Button { model.selectTab(screen) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(active ? a11yTheme.accent : Theme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(label)
                    .font(Theme.font(13, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                    // #338: wrap to a second line at accessibility sizes
                    // instead of eliding; one line at body sizes by design.
                    .lineLimit(labelLineLimit)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver announces a simple "Home" / "Library" / "Search" and,
        // for the currently selected tab, adds the "selected" trait so the
        // user hears which one they're on without parsing visual chrome.
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    /// Sidebar entry for the dedicated Favorites surface. Mirrors libRow
    /// visually but routes to `.favorites` (its own root tab) instead of
    /// the Library with a tab pre-selected.
    @ViewBuilder
    private var favoritesRow: some View {
        // Favorites is its own root tab (`.favorites`), so it's "active" under
        // the same rule every `navItem` uses: the tab is selected and we're at
        // the tab root (no drill pushed). Without this the row was the only nav
        // entry that gave no selected-state feedback — no accent, no selection
        // background/bar, and no `.isSelected` VoiceOver trait. Mirrors
        // `navItem`'s active treatment so the two read identically.
        let active = model.screen == .favorites && model.navPath.isEmpty
        Button {
            model.selectTab(.favorites)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "heart")
                    .foregroundStyle(active ? a11yTheme.accent : Theme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("sidebar.stats.favorites")
                    .font(Theme.font(13, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                    .lineLimit(labelLineLimit)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("sidebar.stats.favorites")
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func libRow(
        _ icon: String,
        label: LocalizedStringKey,
        count: UInt32?,
        tab: LibraryTab
    ) -> some View {
        Button {
            // Set the requested library tab before flipping the screen so the
            // Library view reads the right chip on its first render. See
            // `AppModel.libraryTab`.
            model.libraryTab = tab
            model.selectTab(.library)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(label)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    // #338: wrap rather than elide at accessibility sizes.
                    .lineLimit(labelLineLimit)
                Spacer(minLength: 8)
                if let c = count {
                    Text("\(c)")
                        .font(Theme.font(10, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        // The count is a short numeral; keep it on one line so
                        // it never wraps under the label, even when the label
                        // itself wraps to two lines.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Combine icon + label + count into one VoiceOver utterance so the
        // row reads as "Albums, 42" rather than three separate fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        // The header reads as uppercase in the rendered frame via the heavy
        // tracking + smallcap feel; we no longer force `.uppercased()` here
        // because doing so would mangle non-Latin scripts (Arabic, CJK)
        // that have no case distinction. The catalog entries already ship
        // the English label in uppercase.
        Text(title)
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

// MARK: - #317: List-row chrome reset for the reorderable Playlists list

private extension View {
    /// Strip a `List` row's default insets / background / separator so a
    /// playlist row drawn inside the reorderable `List` renders identically to
    /// the previous ScrollView+VStack layout. The row already paints its own
    /// 1pt vertical spacing and rounded hover/active background, so the List
    /// must contribute nothing but the drag affordance.
    func listRowSidebarStyling() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 1, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - #590: Stable inline-rename TextField subview
//
// Extracted from `Sidebar` so SwiftUI maintains its view identity across
// parent re-renders (e.g. when `model.playlists` updates while a rename is
// in progress). When the logic lived as a `@ViewBuilder` method on `Sidebar`,
// any change to the playlists array could cause the ForEach to rebuild
// the row's subtree, dismounting the TextField mid-edit and silently
// discarding the draft. As a separate `struct`, SwiftUI treats it as a
// stable node and preserves its `@FocusState` across parent refreshes.
//
// The `.id("rename-\(playlistId)")` modifier in `playlistRow` pins the
// view's identity to the edit session so a rename of playlist A doesn't
// accidentally re-use a previously mounted field for playlist B.
private struct SidebarInlineEditField: View {
    @Environment(AppModel.self) private var model
    let initialText: String

    @FocusState private var isFocused: Bool

    /// Set the instant `onSubmit` (Return) fires so the focus-loss that Return
    /// triggers can't run the blur branch as a *second* commit. Without this,
    /// pressing Return launched `commitSidebarPlaylistEdit()` and then the
    /// resign-first-responder flipped `isFocused` to `false` synchronously —
    /// before that first (async) commit Task had cleared
    /// `sidebarEditingPlaylistId` — so the `onChange` branch saw a still-live
    /// edit session and committed again. For a new playlist that meant two
    /// `createPlaylist` round-trips and two server rows. See #71 / #75 / #590.
    @State private var committed = false

    var body: some View {
        @Bindable var model = model
        TextField("Playlist name", text: $model.sidebarEditingDraft)
            .textFieldStyle(.plain)
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .focused($isFocused)
            .onAppear {
                // Seed the draft with the passed-in initial text so existing
                // playlists open their rename field prefilled. New-row case
                // passes "" and should stay empty.
                if !initialText.isEmpty && model.sidebarEditingDraft.isEmpty {
                    model.sidebarEditingDraft = initialText
                }
                // Defer focus by a tick so the field has mounted.
                DispatchQueue.main.async { isFocused = true }
            }
            .onSubmit {
                committed = true
                Task { await model.commitSidebarPlaylistEdit() }
            }
            .onExitCommand {
                model.cancelSidebarPlaylistEdit()
            }
            .onChange(of: isFocused) { _, focused in
                // #590: Only act on a genuine user-driven focus loss.
                // Skip when Return already committed this edit (the resulting
                // focus loss must not commit a second time), and when
                // `sidebarEditingPlaylistId` was already cleared by Escape,
                // commit, or a concurrent model update.
                guard !focused else { return }
                guard !committed else { return }
                guard model.sidebarEditingPlaylistId != nil else { return }
                let trimmed = model.sidebarEditingDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    model.cancelSidebarPlaylistEdit()
                } else {
                    Task { await model.commitSidebarPlaylistEdit() }
                }
            }
    }
}
