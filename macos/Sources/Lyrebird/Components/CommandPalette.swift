import SwiftUI
@preconcurrency import LyrebirdCore

/// ⌘K command palette — Spotlight-style launcher for library search + static
/// verbs. Owns its own `@FocusState` for the search field, a `@State` selection
/// index, and an 80ms debounce on library search so the FFI isn't pounded on
/// every keystroke. Lives at the root so the overlay sits above every screen;
/// dim scrim behind the centered 640pt column keeps the rest of the UI legible
/// and hints at the modal nature of the palette.
///
/// Issues: #305 (shell + ⌘K), #306 (library results), #307 (actions), #308
/// (recent + pinned actions), #309 (keyboard-only UX).
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

    /// Set when the most recent library search threw (network / auth /
    /// transient). Drives an inline error row distinct from the "No matches"
    /// empty state so a failed round-trip isn't silently indistinguishable
    /// from a genuinely empty result. Cleared on the next keystroke and on a
    /// successful search. See audit CommandPalette.swift:427.
    @State private var searchError: String?

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
                searchError = nil
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
            if let searchError {
                // Distinct from "No matches": a thrown search means we don't
                // actually know whether results exist, so don't claim "none".
                searchErrorView(searchError)
            } else {
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
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if searchError != nil {
                            // Non-fatal badge above retained rows: the rows may
                            // be stale (kept from a prior keystroke), so flag
                            // that the latest search didn't land.
                            searchErrorBanner
                        }
                        ForEach(Array(visibleRows.enumerated()), id: \.offset) { idx, row in
                            PaletteRow(
                                row: row,
                                isSelected: idx == selectedIndex,
                                isPinned: isPinned(row),
                                onActivate: { activate(at: idx) }
                            )
                            .id(idx)
                            .onTapGesture { activate(at: idx) }
                            .onHover { hovering in
                                if hovering { selectedIndex = idx }
                            }
                            .contextMenu { pinContextMenu(for: row) }
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

    /// Full-height error state shown when a search threw and there are no
    /// rows to fall back on. Visually distinct from the "No matches" empty
    /// state so the user can tell a failure from a genuinely empty result.
    private func searchErrorView(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Text("Search failed")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Text(message)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    /// Slim inline badge drawn above retained (possibly stale) rows when the
    /// latest search threw but earlier results are still on screen.
    private var searchErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
            Text("Search couldn’t refresh — showing earlier results.")
                .font(Theme.font(11, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.ink3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var hintsRow: some View {
        HStack(spacing: 18) {
            hint("\u{2191}\u{2193}", "navigate")
            hint("\u{21A9}", "select")
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
        // Carries the resolved `PaletteAction` so the row renders its
        // (localized) title + authoritative symbol straight off the model —
        // no parallel id→title/symbol tables to drift. Identity is the
        // action's `id`, so `PaletteAction` need not itself be `Hashable`.
        case action(AppModel.PaletteAction)

        /// The action id for a `.action` row, else `nil`. Used by the pin
        /// affordances and the commit dispatcher.
        var actionId: String? {
            if case .action(let a) = self { return a.id }
            return nil
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .artist(let a): hasher.combine(0); hasher.combine(a.id)
            case .album(let a): hasher.combine(1); hasher.combine(a.id)
            case .track(let t): hasher.combine(2); hasher.combine(t.id)
            case .action(let a): hasher.combine(3); hasher.combine(a.id)
            }
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case (.artist(let a), .artist(let b)): return a.id == b.id
            case (.album(let a), .album(let b)): return a.id == b.id
            case (.track(let a), .track(let b)): return a.id == b.id
            case (.action(let a), .action(let b)): return a.id == b.id
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
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // #308: empty query surfaces Pinned first, then Recent, then
                // the remaining roster — each action exactly once. Both the
                // pinned and recents lists are persisted id lists that may
                // reference actions not in the current roster (a
                // capability-gated verb whose flag is off); intersecting with
                // the live ids drops those stale entries silently.
                rows.append(contentsOf: orderedActionRows())
            } else {
                for action in model.paletteActions
                where CommandPalette.actionMatches(action.searchTitle, query: trimmed) {
                    rows.append(.action(action))
                }
            }
        }
        return rows
    }

    /// Whether a palette action whose title is `title` should surface for the
    /// user's `query`. Matching is substring-first (so "preferences",
    /// "shuffle", "queue", "favorites", "library" all hit), with a
    /// whitespace-token prefix pass so a query like "fav" also matches the
    /// "Favorites" token inside "Go to Favorites". Both sides are lowercased
    /// for case-insensitivity. Pure + static so the contract is unit-testable
    /// without constructing the view.
    static func actionMatches(_ title: String, query: String) -> Bool {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = title.lowercased()
        if haystack.contains(needle) { return true }
        return haystack
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0.hasPrefix(needle) }
    }

    /// Empty-query action ordering: Pinned → Recent → the rest, deduped, in
    /// roster order within the trailing group. Computed off the live roster so
    /// an action whose capability flag is off (and thus absent from
    /// `paletteActions`) never appears even if its id lingers in a persisted
    /// pinned/recent list. See #308.
    private func orderedActionRows() -> [Row] {
        let roster = model.paletteActions
        let rosterIds = roster.map(\.id)
        // Resolve ids back to live actions so the row carries the model
        // (title + symbol) rather than just an id. A persisted pinned/recent
        // id with no live action (capability flag off) resolves to nil and is
        // dropped — same silent-skip contract as before.
        let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })

        var ordered: [Row] = []
        var seen = Set<String>()
        func push(_ ids: [String]) {
            for id in ids where seen.insert(id).inserted {
                if let action = byId[id] { ordered.append(.action(action)) }
            }
        }
        push(model.palettePinnedActionIds)
        push(model.paletteRecentActionIds)
        push(rosterIds) // the remainder, in the roster's own order
        return ordered
    }

    /// Whether `row` is a currently-pinned action. Library rows can't be
    /// pinned (pin/unpin is an action-only affordance for #308), so they
    /// always report `false`.
    private func isPinned(_ row: Row) -> Bool {
        guard let id = row.actionId else { return false }
        return model.isPaletteActionPinned(id: id)
    }

    /// Right-click affordance for palette rows. Only action rows expose a
    /// Pin/Unpin toggle; library rows return an empty menu (so the
    /// right-click is a no-op rather than surfacing an irrelevant item).
    /// See #308.
    @ViewBuilder
    private func pinContextMenu(for row: Row) -> some View {
        if let id = row.actionId {
            let pinned = model.isPaletteActionPinned(id: id)
            Button {
                model.togglePaletteActionPin(id: id)
            } label: {
                Label(pinned ? "Unpin" : "Pin",
                      systemImage: pinned ? "pin.slash" : "pin")
            }
        }
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
            searchError = nil
        } catch {
            // Surface the failure: a thrown search (network / auth / transient)
            // must be distinguishable from a genuinely empty result, so we
            // log it and badge an inline error row (see `searchError`). Keep
            // the last-known `libraryResults` rather than clearing to nil so a
            // single flaky round-trip mid-typing doesn't wipe good rows.
            guard runId == searchRunId else { return }
            Log.app.error("CommandPalette search failed query=\(query, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            searchError = error.localizedDescription
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
        case .action(let action):
            model.executePaletteAction(id: action.id)
            // executePaletteAction flips isCommandPaletteOpen itself, but
            // belt-and-suspenders: ensure close fires so the transition
            // animation kicks off even if the action closure errors out.
            close()
        }
    }

    private func close() {
        model.isCommandPaletteOpen = false
    }

    // MARK: - Keyboard

    /// Invisible button overlay that binds the palette's non-text shortcuts.
    /// Return is handled by the TextField's `.onSubmit`, and Esc is handled
    /// by the scrim button's `.cancelAction`; both are intentionally absent
    /// from this block so Return and Esc reach one handler apiece rather
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
}

// MARK: - Row

struct PaletteRow: View {
    let row: CommandPalette.Row
    let isSelected: Bool
    /// Whether this row is a pinned action. Drives the small pin glyph shown
    /// before the ↩ hint so the user can tell at a glance which actions are
    /// pinned (and that the right-click "Unpin" applies). Always `false` for
    /// library rows. See #308.
    var isPinned: Bool = false
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                primaryTextView
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
            if isPinned {
                // Persistent pin marker — drawn whether or not the row is
                // selected, unlike the ↩ hint which only shows on selection.
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityLabel("Pinned")
            }
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
        .background(isSelected ? Theme.nativeHover : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var iconName: String {
        switch row {
        case .artist: return "person"
        case .album: return "square.stack"
        case .track: return "music.note"
        // Symbol comes straight off the resolved `PaletteAction` so it can't
        // drift from the model and isn't gated on a parallel lookup table.
        case .action(let a): return a.symbol
        }
    }

    /// Primary label. Library rows render plain (server-provided) names;
    /// action rows render the model's `LocalizedStringKey` `title` so the
    /// label localizes once a strings catalog is registered — no hardcoded
    /// English mirror that bypasses localization or falls back to a raw id.
    @ViewBuilder
    private var primaryTextView: some View {
        switch row {
        case .artist(let a): Text(a.name)
        case .album(let a): Text(a.name)
        case .track(let t): Text(t.name)
        case .action(let a): Text(a.title)
        }
    }

    private var secondaryText: String? {
        switch row {
        case .artist(let a):
            let albums = a.albumCount
            let songs = a.songCount
            if albums == 0 && songs == 0 { return "Artist" }
            let albumPart = CountStrings.label(Int(albums), .albums)
            let songPart = CountStrings.label(Int(songs), .songs)
            return "Artist \u{00B7} \(albumPart) \u{00B7} \(songPart)"
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
}
