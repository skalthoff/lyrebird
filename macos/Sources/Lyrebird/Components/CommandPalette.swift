import SwiftUI
@preconcurrency import LyrebirdCore

/// ⌘K command palette — Spotlight-style launcher for library search + static
/// verbs. Owns its own `@FocusState` for the search field, a `@State` selection
/// index, and an 80ms debounce on library search so the FFI isn't pounded on
/// every keystroke. Lives at the root so the overlay sits above every screen;
/// dim scrim behind the centered 640pt column keeps the rest of the UI legible
/// and hints at the modal nature of the palette.
///
/// Issues: #305 (shell + ⌘K), #306 (library results), #307 (actions), #309
/// (keyboard-only UX). #308 (recent + pinned) is a follow-up.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model

    /// Raw text in the search field. The effective query is `trimmed`, which
    /// drops whitespace so a stray space doesn't fire a network round-trip.
    @State private var query: String = ""

    /// Debounced mirror of `query`. Published 80ms after the last keystroke
    /// so library-search round-trips don't fire on every character. The empty
    /// state is shown immediately (no debounce) so the palette feels
    /// responsive when the user clears the field.
    @State private var debouncedQuery: String = ""

    /// Category filter activated by ⌘1..5. `.all` is the default; selecting
    /// a specific category narrows both library rows and action rows to that
    /// kind (`.actions` hides library rows, and vice-versa for the typed
    /// filters).
    @State private var category: Category = .all

    /// Index of the currently-highlighted row across the whole list (library
    /// results first, then actions). Used by ↑/↓ navigation and the ↩ commit
    /// path. Clamped to `[0, visibleRows.count)` whenever the list changes.
    @State private var selectedIndex: Int = 0

    /// Monotonic "run id" for the in-flight debounced search. Only the latest
    /// id writes back to `libraryResults`, so a slow response for a stale
    /// query can't overwrite a newer response.
    @State private var searchRunId: UInt64 = 0

    /// Palette-local mirror of `AppModel.search(...)`. Held here instead of
    /// on `AppModel.searchResults` so opening the palette doesn't clobber the
    /// user's state on the full `SearchView` — the two surfaces are backed by
    /// independent searches.
    @State private var libraryResults: SearchResults?

    /// In-flight flag driving the subtle header spinner while a debounced
    /// search is running. Pure UI polish — rows are still drawn from the
    /// last-known `libraryResults` underneath.
    @State private var isSearching: Bool = false

    @FocusState private var searchFocused: Bool

    /// Debounce window before a library search fires. 80ms is snappy enough
    /// to feel live while cutting the round-trip count on a burst of
    /// keystrokes by ~10x. Exposed as a constant so the integration test
    /// (if/when it lands) can reason about it.
    private let debounceMs: Int = 80

    /// Categories exposed by the ⌘1..5 quick filter. `.all` and `.actions`
    /// are obvious; the three typed variants narrow the library-search
    /// portion of the row stack to a single item kind so a user searching
    /// for "play" sees verb-actions, not the artist called Play.
    enum Category: Int, CaseIterable {
        case all
        case artists
        case albums
        case tracks
        case actions

        var label: String {
            switch self {
            case .all: return "All"
            case .artists: return "Artists"
            case .albums: return "Albums"
            case .tracks: return "Tracks"
            case .actions: return "Actions"
            }
        }
    }

    var body: some View {
        ZStack {
            // Dim scrim. A button so a click outside the column dismisses
            // the palette, matching Spotlight. `.plain` drops macOS's
            // default button chrome; the fill is the scrim itself.
            Button(action: close) {
                Color.black.opacity(0.76)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss command palette")

            VStack(spacing: 0) {
                paletteColumn
                Spacer()
            }
            .padding(.top, 120)
        }
        // #585: Route space-bar keypresses to the palette's search TextField
        // even while the global Play/Pause ⎵ shortcut is active.
        .spaceKeyGuardForTextField()
        .onAppear {
            // Autofocus the search input on present. The 0.01s defer
            // works around a SwiftUI quirk where `@FocusState` set on the
            // same frame as the view mount is sometimes dropped on first
            // render of an overlay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                searchFocused = true
            }
        }
        .onChange(of: query) { _, newValue in
            // Immediate empty-state handling — clearing the field should
            // snap the list back to the static actions without waiting
            // for the debounce timer.
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedQuery = ""
                libraryResults = nil
                isSearching = false
                selectedIndex = 0
                return
            }
            // Otherwise, schedule a debounced search run. The run-id gate
            // inside the async block means a second keystroke invalidates
            // the first.
            searchRunId &+= 1
            let myRunId = searchRunId
            isSearching = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
                guard myRunId == searchRunId else { return }
                debouncedQuery = trimmed
                await runLibrarySearch(query: trimmed, runId: myRunId)
            }
        }
        .onChange(of: category) { _, _ in
            // Category change can shrink the visible list — clamp the
            // selection so we don't point past the end.
            selectedIndex = min(selectedIndex, max(visibleRows.count - 1, 0))
        }
        .onChange(of: visibleRows.count) { _, newValue in
            selectedIndex = min(selectedIndex, max(newValue - 1, 0))
        }
    }

    // MARK: - Column

    private var paletteColumn: some View {
        VStack(spacing: 0) {
            searchInputRow
            categoryBar
            Divider().background(Theme.border)
            resultsScroll
            Divider().background(Theme.border)
            hintsRow
        }
        .frame(width: 640)
        .background(Theme.bgAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.35), radius: 40, x: 0, y: 20)
        .background(keyboardInterceptors)
    }

    private var searchInputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.ink2)
                .font(.system(size: 18, weight: .medium))
            TextField("Search library or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.font(18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onSubmit(commitSelection)
            if isSearching {
                ProgressView()
                    .tint(Theme.ink2)
                    .scaleEffect(0.6)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var categoryBar: some View {
        HStack(spacing: 6) {
            ForEach(Category.allCases, id: \.self) { cat in
                Button {
                    category = cat
                } label: {
                    Text(cat.label)
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(category == cat ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(category == cat ? Theme.surface2 : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(category == cat ? Theme.borderStrong : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var resultsScroll: some View {
        if visibleRows.isEmpty {
            VStack(spacing: 6) {
                Text("No matches")
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Text("Try a different query or ⌘1..5 to filter by category.")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleRows.enumerated()), id: \.offset) { idx, row in
                            PaletteRow(
                                row: row,
                                isSelected: idx == selectedIndex,
                                onActivate: { activate(at: idx) }
                            )
                            .id(idx)
                            .onTapGesture { activate(at: idx) }
                            .onHover { hovering in
                                if hovering { selectedIndex = idx }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, newValue in
                    // Keep the highlighted row in view as the user presses
                    // ↑/↓. Anchor to `.center` so the highlight doesn't
                    // glue itself to one edge as the list scrolls.
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var hintsRow: some View {
        HStack(spacing: 18) {
            hint("\u{2191}\u{2193}", "navigate")
            hint("\u{21A9}", "select")
            hint("\u{2318}\u{21A9}", "new window")
            hint("Esc", "close")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink2)
            Text(label)
                .font(Theme.font(10, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Row model

    /// Unified row shape driving the results list. Keeps library and action
    /// rows in one sortable collection so ↑/↓ / ↩ / `visibleRows.count` all
    /// work without branching on kind.
    enum Row: Hashable {
        case artist(Artist)
        case album(Album)
        case track(Track)
        case action(String) // PaletteAction.id

        func hash(into hasher: inout Hasher) {
            switch self {
            case .artist(let a): hasher.combine(0); hasher.combine(a.id)
            case .album(let a): hasher.combine(1); hasher.combine(a.id)
            case .track(let t): hasher.combine(2); hasher.combine(t.id)
            case .action(let id): hasher.combine(3); hasher.combine(id)
            }
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case (.artist(let a), .artist(let b)): return a.id == b.id
            case (.album(let a), .album(let b)): return a.id == b.id
            case (.track(let a), .track(let b)): return a.id == b.id
            case (.action(let a), .action(let b)): return a == b
            default: return false
            }
        }
    }

    /// Rows visible for the current query + category. Library results come
    /// first, actions trail — mirrors the grouping the task spec calls out.
    /// Recomputed on every render; cheap since the inputs are all local
    /// `@State`.
    private var visibleRows: [Row] {
        var rows: [Row] = []
        let libVisible = category == .all
            || category == .artists
            || category == .albums
            || category == .tracks
        let actionsVisible = category == .all || category == .actions

        if libVisible, let results = libraryResults {
            if category == .all || category == .artists {
                rows.append(contentsOf: results.artists.prefix(6).map(Row.artist))
            }
            if category == .all || category == .albums {
                rows.append(contentsOf: results.albums.prefix(6).map(Row.album))
            }
            if category == .all || category == .tracks {
                rows.append(contentsOf: results.tracks.prefix(6).map(Row.track))
            }
        }

        if actionsVisible {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for action in model.paletteActions {
                // Action matching is intentionally prefix-only so typing
                // "play" shows "Play" / "Play Next" but not unrelated
                // verbs. Empty query always shows the full list.
                if trimmed.isEmpty || actionTitleString(action).lowercased().hasPrefix(trimmed) {
                    rows.append(.action(action.id))
                }
            }
        }
        return rows
    }

    // MARK: - Actions

    private func runLibrarySearch(query: String, runId: UInt64) async {
        defer { if runId == searchRunId { isSearching = false } }
        do {
            let results = try await Task.detached(priority: .userInitiated) { [core = model.core] in
                try core.search(query: query, offset: 0, limit: 12)
            }.value
            guard runId == searchRunId else { return }
            libraryResults = results
        } catch {
            // Silent on error — the palette stays on the last-known results
            // (or empty state) rather than surfacing an error banner over
            // what is already an ephemeral overlay.
            guard runId == searchRunId else { return }
            libraryResults = nil
        }
    }

    private func activate(at index: Int) {
        guard visibleRows.indices.contains(index) else { return }
        selectedIndex = index
        commitSelection()
    }

    /// Commit the highlighted row. Each row kind fans out to the appropriate
    /// AppModel entry point, then closes the palette. Library rows navigate
    /// by default (the task's `↩ Play` hint is a simplification — "Play"
    /// reads well but the actual behavior is "go to detail" for artists /
    /// albums, "play" for tracks; matches the rest of the app's row
    /// semantics).
    private func commitSelection() {
        guard visibleRows.indices.contains(selectedIndex) else { return }
        let row = visibleRows[selectedIndex]
        switch row {
        case .artist(let artist):
            model.navigate(to: .artist(artist.id))
            close()
        case .album(let album):
            model.navigate(to: .album(album.id))
            close()
        case .track(let track):
            model.play(tracks: [track], startIndex: 0)
            close()
        case .action(let id):
            model.executePaletteAction(id: id)
            // executePaletteAction flips isCommandPaletteOpen itself, but
            // belt-and-suspenders: ensure close fires so the transition
            // animation kicks off even if the action closure errors out.
            close()
        }
    }

    private func close() {
        model.isCommandPaletteOpen = false
    }

    private func actionTitleString(_ action: AppModel.PaletteAction) -> String {
        // `LocalizedStringKey` doesn't expose its raw string directly. The
        // titles we ship are fixed English literals (no localization tables
        // registered yet), so bridging via `String(describing:)` retrieves
        // the underlying key string which is also the display string.
        // Swap for proper localization once a strings catalog lands.
        let mirror = Mirror(reflecting: action.title)
        for child in mirror.children {
            if child.label == "key", let key = child.value as? String {
                return key
            }
        }
        return ""
    }

    // MARK: - Keyboard

    /// Invisible button overlay that binds the palette's non-text shortcuts.
    /// Return is handled by the TextField's `.onSubmit`, and Esc is handled
    /// by the scrim button's `.cancelAction`; both are intentionally absent
    /// from this block so ⌘-Return and Esc reach one handler apiece rather
    /// than racing with the TextField. Arrow keys need this channel because
    /// SwiftUI's `onKeyPress` doesn't reach through a focused TextField on
    /// macOS 14 reliably. `.opacity(0)` + `.allowsHitTesting(false)` keep
    /// the buttons out of pointer events without disabling their shortcuts.
    @ViewBuilder
    private var keyboardInterceptors: some View {
        ZStack {
            Button("Down", action: { moveSelection(by: 1) })
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("Up", action: { moveSelection(by: -1) })
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("New Window", action: commitInNewWindow)
                .keyboardShortcut(.return, modifiers: .command)
            Button("All", action: { category = .all })
                .keyboardShortcut("1", modifiers: .command)
            Button("Artists", action: { category = .artists })
                .keyboardShortcut("2", modifiers: .command)
            Button("Albums", action: { category = .albums })
                .keyboardShortcut("3", modifiers: .command)
            Button("Tracks", action: { category = .tracks })
                .keyboardShortcut("4", modifiers: .command)
            Button("Actions", action: { category = .actions })
                .keyboardShortcut("5", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
        // These buttons exist purely to own keyboard shortcuts — the
        // actual visible list rows already expose themselves to VoiceOver.
        // Hiding prevents duplicate "Up" / "Down" announcements when
        // navigating the palette with assistive tech.
        .accessibilityHidden(true)
    }

    private func moveSelection(by delta: Int) {
        guard !visibleRows.isEmpty else { return }
        let next = selectedIndex + delta
        if next < 0 {
            selectedIndex = 0
        } else if next >= visibleRows.count {
            selectedIndex = visibleRows.count - 1
        } else {
            selectedIndex = next
        }
    }

    /// ⌘↩ placeholder — issue #309 calls out "open in new window" as a
    /// future affordance. For now it falls through to the standard commit
    /// so the keybinding lands on something and the user isn't stuck. Swap
    /// to the real per-row new-window dispatcher when that ships.
    private func commitInNewWindow() {
        // TODO(#309): wire a real "open in new window" path.
        commitSelection()
    }
}

// MARK: - Row

struct PaletteRow: View {
    let row: CommandPalette.Row
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let sub = secondaryText, !sub.isEmpty {
                    Text(sub)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Text("\u{21A9}")
                    .font(Theme.font(10, weight: .bold))
                Text(trailingHint)
                    .font(Theme.font(11, weight: .medium))
            }
            .foregroundStyle(Theme.ink3)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Theme.rowHover : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var iconName: String {
        switch row {
        case .artist: return "person"
        case .album: return "square.stack"
        case .track: return "music.note"
        case .action(let id):
            // Pulling the symbol off `paletteActions` in the parent and
            // passing it in would mean threading an extra parameter — the
            // id → symbol map below stays in one place so the row doesn't
            // need to reach back into AppModel.
            return PaletteRow.actionSymbolById[id] ?? "bolt"
        }
    }

    private var primaryText: String {
        switch row {
        case .artist(let a): return a.name
        case .album(let a): return a.name
        case .track(let t): return t.name
        case .action(let id): return PaletteRow.actionTitleById[id] ?? id
        }
    }

    private var secondaryText: String? {
        switch row {
        case .artist(let a):
            let albums = a.albumCount
            let songs = a.songCount
            if albums == 0 && songs == 0 { return "Artist" }
            return "Artist \u{00B7} \(albums) album\(albums == 1 ? "" : "s") \u{00B7} \(songs) song\(songs == 1 ? "" : "s")"
        case .album(let a):
            return "Album \u{00B7} \(a.artistName)"
        case .track(let t):
            if let album = t.albumName, !album.isEmpty {
                return "Track \u{00B7} \(t.artistName) \u{00B7} \(album)"
            }
            return "Track \u{00B7} \(t.artistName)"
        case .action:
            return "Action"
        }
    }

    private var trailingHint: String {
        switch row {
        case .track: return "Play"
        case .artist, .album: return "Open"
        case .action: return "Run"
        }
    }

    // Static maps so the row can label/icon itself without needing a
    // reference to `AppModel`. Kept in sync with `AppModel.paletteActions`
    // by hand — the set is small and stable. When the registry grows
    // faster, fold this back into a computed lookup off AppModel.
    static let actionTitleById: [String: String] = [
        "playback.play": "Play",
        "playback.pause": "Pause",
        "playback.playNext": "Play Next",
        "playback.addToQueue": "Add to Queue",
        "nav.library": "Go to Library",
        "nav.home": "Go to Home",
        "nav.discover": "Go to Discover",
        "nav.favorites": "Go to Favorites",
        "app.openPreferences": "Open Preferences",
        "playback.toggleShuffle": "Toggle Shuffle",
        "playback.toggleRepeat": "Toggle Repeat",
        "queue.clear": "Clear Queue",
        "download.current": "Download Current",
    ]

    static let actionSymbolById: [String: String] = [
        "playback.play": "play.fill",
        "playback.pause": "pause.fill",
        "playback.playNext": "text.line.first.and.arrowtriangle.forward",
        "playback.addToQueue": "text.badge.plus",
        "nav.library": "music.note.list",
        "nav.home": "house",
        "nav.discover": "sparkles",
        "nav.favorites": "heart",
        "app.openPreferences": "gearshape",
        "playback.toggleShuffle": "shuffle",
        "playback.toggleRepeat": "repeat",
        "queue.clear": "trash",
        "download.current": "arrow.down.circle",
    ]
}
