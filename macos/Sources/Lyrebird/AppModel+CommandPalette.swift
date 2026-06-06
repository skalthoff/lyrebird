import AppKit
import Foundation
import SwiftUI
@preconcurrency import LyrebirdCore

/// Command Palette (⌘K) on `AppModel`: the action catalog (`paletteActions`),
/// palette execution + the feature-tour entry point, and recents/pinned
/// management (record / pin / unpin / toggle + JSON `[String]` persistence).
///
/// The palette's stored state — `isCommandPaletteOpen` and the other modal
/// flags, `paletteRecentActionIds` / `palettePinnedActionIds`, and the
/// UserDefaults keys + cap — stays on the main `AppModel` class; stored
/// properties can't live in an extension. Extensions of a `@MainActor` type
/// inherit its isolation, so every method here is main-actor-bound just like
/// the rest of the class.
extension AppModel {
    // MARK: - Command Palette (⌘K)

    /// Re-open the feature tour on demand. Wired to the Help ▸ "Show Tour"
    /// menu command; `MainShell` renders `FeatureTourOverlay` whenever this is
    /// set and clears it on dismiss. See #113.
    func presentFeatureTour() {
        isFeatureTourPresented = true
    }

    /// A single verb entry in the command palette's action list. See
    /// `paletteActions` for the live roster and `executePaletteAction(id:)`
    /// for the dispatcher. Actions are intentionally held by id + closure
    /// rather than by enum so the registry can grow without rippling
    /// through view code. See #307.
    struct PaletteAction: Identifiable {
        let id: String
        /// Display title, localized when a strings catalog is registered.
        let title: LocalizedStringKey
        /// Stable, owned plain-text title used for command-palette search
        /// matching. Held separately from `title` because `LocalizedStringKey`
        /// has no public way to recover its underlying string — matching off a
        /// real `String` keeps search working across OS updates instead of
        /// depending on the key's private layout. Keep in sync with `title`.
        let searchTitle: String
        let symbol: String
        let run: () -> Void
    }

    /// Static verb list surfaced by the command palette. Computed so the
    /// play/pause entry swaps labels based on the current playback state —
    /// re-evaluated on every palette render since the model publishes
    /// `status` changes. See #307.
    var paletteActions: [PaletteAction] {
        let isPlaying = status.state == .playing
        let hasTrack = status.currentTrack != nil
        var actions: [PaletteAction] = []

        // Transport. "Play" / "Pause" swap so the user sees the action that
        // actually fires rather than a generic "Toggle Play/Pause".
        if hasTrack {
            if isPlaying {
                actions.append(PaletteAction(
                    id: "playback.pause",
                    title: "Pause",
                    searchTitle: "Pause",
                    symbol: "pause.fill",
                    run: { [weak self] in self?.pause() }
                ))
            } else {
                actions.append(PaletteAction(
                    id: "playback.play",
                    title: "Play",
                    searchTitle: "Play",
                    symbol: "play.fill",
                    run: { [weak self] in self?.togglePlayPause() }
                ))
            }
        } else {
            // No loaded track — still surface "Play" so ⌘K → Play has a
            // landing pad (it's a no-op until a track is loaded). Using
            // `togglePlayPause` keeps the behavior consistent with the
            // Space-bar shortcut (both no-op in this state).
            actions.append(PaletteAction(
                id: "playback.play",
                title: "Play",
                searchTitle: "Play",
                symbol: "play.fill",
                run: { [weak self] in self?.togglePlayPause() }
            ))
        }
        actions.append(PaletteAction(
            id: "playback.playNext",
            title: "Play Next",
            searchTitle: "Play Next",
            symbol: "text.line.first.and.arrowtriangle.forward",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.playNext(tracks: [track])
            }
        ))
        actions.append(PaletteAction(
            id: "playback.addToQueue",
            title: "Add to Queue",
            searchTitle: "Add to Queue",
            symbol: "text.badge.plus",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.addToQueue(tracks: [track])
            }
        ))

        // Navigation. Keep parity with the Go menu (⌘1 / ⌘2 / Discover).
        actions.append(PaletteAction(
            id: "nav.library",
            title: "Go to Library",
            searchTitle: "Go to Library",
            symbol: "music.note.list",
            run: { [weak self] in self?.selectTab(.library) }
        ))
        actions.append(PaletteAction(
            id: "nav.home",
            title: "Go to Home",
            searchTitle: "Go to Home",
            symbol: "house",
            run: { [weak self] in self?.selectTab(.home) }
        ))
        actions.append(PaletteAction(
            id: "nav.discover",
            title: "Go to Discover",
            searchTitle: "Go to Discover",
            symbol: "sparkles",
            run: { [weak self] in self?.goToDiscover() }
        ))
        actions.append(PaletteAction(
            id: "nav.favorites",
            title: "Go to Favorites",
            searchTitle: "Go to Favorites",
            symbol: "heart",
            run: { [weak self] in self?.selectTab(.favorites) }
        ))

        // Preferences. macOS exposes the Settings scene through the standard
        // Application menu (⌘,); from the palette we mirror that by opening
        // the scene directly rather than routing through `screen = .settings`
        // (which is unused today).
        actions.append(PaletteAction(
            id: "app.openPreferences",
            title: "Open Preferences",
            searchTitle: "Open Preferences",
            symbol: "gearshape",
            run: {
                // `showSettingsWindow:` is the documented selector for
                // opening the Settings scene from outside a menu command.
                // Fall back to the legacy Preferences selector for older
                // macOS versions that don't respond to the newer one.
                if #available(macOS 14, *) {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                } else {
                    NSApp.sendAction(
                        Selector(("showPreferencesWindow:")),
                        to: nil,
                        from: nil
                    )
                }
            }
        ))

        // Playback toggles (#34): flip shuffle / cycle repeat via the
        // palette entries. Both feed the same core setters that Control
        // Center's `MPChangeShuffleModeCommand` / `MPChangeRepeatModeCommand`
        // handlers drive, so all three surfaces stay consistent.
        actions.append(PaletteAction(
            id: "playback.toggleShuffle",
            title: "Toggle Shuffle",
            searchTitle: "Toggle Shuffle",
            symbol: "shuffle",
            run: { [weak self] in
                guard let self else { return }
                self.mediaSessionSetShuffle(!self.status.shuffle)
            }
        ))
        actions.append(PaletteAction(
            id: "playback.toggleRepeat",
            title: "Toggle Repeat",
            searchTitle: "Toggle Repeat",
            symbol: "repeat",
            run: { [weak self] in
                guard let self else { return }
                // Cycle off -> all -> one -> off to match Apple Music's
                // long-press menu ordering — "all" is the most frequently
                // wanted step up from "off".
                let next: RepeatMode = {
                    switch self.status.repeatMode {
                    case .off: return .all
                    case .all: return .one
                    case .one: return .off
                    }
                }()
                self.mediaSessionSetRepeatMode(next)
            }
        ))

        // Queue verb — wired via core.clearQueue (#282).
        actions.append(PaletteAction(
            id: "queue.clear",
            title: "Clear Queue",
            searchTitle: "Clear Queue",
            symbol: "trash",
            run: { [weak self] in
                // #282: wipe the queue but keep the currently playing track
                // as a single-item queue so playback doesn't stop.
                self?.core.clearQueue()
                if let core = self?.core {
                    self?.status = core.status()
                }
            }
        ))
        if supportsDownloads {
            actions.append(PaletteAction(
                id: "download.current",
                title: "Download Current",
                searchTitle: "Download Current",
                symbol: "arrow.down.circle",
                run: { [weak self] in
                    guard let self, let track = self.status.currentTrack else { return }
                    Task { await self.downloadTracks([track]) }
                }
            ))
        }

        return actions
    }

    /// Look up a palette action by id and run it. Called by `CommandPalette`
    /// on ↩ commit. Also closes the palette on success, mirroring the
    /// "execute and dismiss" behavior users expect from Spotlight-style
    /// launchers. Records the run in the recents list so the next empty-query
    /// open surfaces it under "Recent". See #307 / #308.
    func executePaletteAction(id: String) {
        guard let action = paletteActions.first(where: { $0.id == id }) else { return }
        recordPaletteActionUsage(id: id)
        action.run()
        isCommandPaletteOpen = false
    }

    // MARK: - Command Palette recents + pinned (#308)

    /// Record that `id` was just run: dedupe, insert at the front, cap to
    /// `paletteRecentActionsCap`, and persist. Mirrors `addRecentSearch`'s
    /// dedupe/cap/insert-at-0 contract so the most-recent action is always
    /// first and a re-run promotes (rather than duplicates) an entry.
    func recordPaletteActionUsage(id: String) {
        paletteRecentActionIds = AppModel.appendPaletteRecent(
            id,
            into: paletteRecentActionIds,
            cap: AppModel.paletteRecentActionsCap
        )
        persist(paletteRecentActionIds, forKey: AppModel.paletteRecentActionIdsKey)
    }

    /// Whether `id` is currently pinned. Cheap membership test for the row
    /// context menu's "Pin"/"Unpin" label and the empty-query grouping.
    func isPaletteActionPinned(id: String) -> Bool {
        palettePinnedActionIds.contains(id)
    }

    /// Pin `id` (no-op if already pinned). New pins go to the front so the
    /// most-recently-pinned action leads the "Pinned" group, matching the
    /// recents ordering.
    func pinPaletteAction(id: String) {
        guard !palettePinnedActionIds.contains(id) else { return }
        palettePinnedActionIds.insert(id, at: 0)
        persist(palettePinnedActionIds, forKey: AppModel.palettePinnedActionIdsKey)
    }

    /// Unpin `id` (no-op if not pinned).
    func unpinPaletteAction(id: String) {
        guard palettePinnedActionIds.contains(id) else { return }
        palettePinnedActionIds.removeAll { $0 == id }
        persist(palettePinnedActionIds, forKey: AppModel.palettePinnedActionIdsKey)
    }

    /// Toggle the pin state of `id`. Wired to the palette row's right-click
    /// "Pin"/"Unpin" affordance.
    func togglePaletteActionPin(id: String) {
        if isPaletteActionPinned(id: id) {
            unpinPaletteAction(id: id)
        } else {
            pinPaletteAction(id: id)
        }
    }

    /// Append a run to the recent-action-id list: drop any existing copy,
    /// insert at the front, cap to `cap`. Pure + static so the cap / dedupe /
    /// ordering contract is unit-testable without booting an `AppModel`,
    /// mirroring `addRecentSearch`. Action ids are exact-match (not
    /// case-insensitive) since they're internal identifiers, not user text.
    static func appendPaletteRecent(_ id: String, into list: [String], cap: Int) -> [String] {
        guard !id.isEmpty else { return list }
        var next = list
        next.removeAll { $0 == id }
        next.insert(id, at: 0)
        if next.count > cap {
            next = Array(next.prefix(cap))
        }
        return next
    }

    /// Decode a persisted JSON `[String]` of action ids. Returns `[]` on
    /// malformed data so a stale shape from a prior build can't wedge the
    /// palette — same defensive decode as `decodeRecentSearches`.
    static func decodePaletteActionIds(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    /// Encode an action-id list back to the JSON string persisted in
    /// `UserDefaults`. Returns `"[]"` on failure so a write never stores a
    /// half-baked value.
    static func encodePaletteActionIds(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    /// Persist an action-id list under `key` via the JSON-in-UserDefaults
    /// bridge.
    private func persist(_ list: [String], forKey key: String) {
        UserDefaults.standard.set(AppModel.encodePaletteActionIds(list), forKey: key)
    }
}
