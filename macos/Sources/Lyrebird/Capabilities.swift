import Foundation

/// Capability flags that gate UI affordances whose backing FFI may not
/// have landed yet. A flag returns `false` when the surface is wired in
/// the UI but the backing FFI is still a stub; it flips to `true` once
/// the named issue closes and the action is real. Flags that already
/// ship enabled keep the flag around as a kill-switch / regression
/// fallback rather than removing the gate outright.
///
/// Why a flag instead of just deleting the call site: keeping the menu
/// entry, button, and `AppModel` method around — but hidden — means the
/// FFI work that enables it can flip a single flag rather than re-wiring
/// every surface.
extension AppModel {
    /// Download engine (#819). Gates "Download Current" in the command
    /// palette plus per-album / per-playlist / per-track Download
    /// affordances. The four AppModel stubs (Download Current,
    /// enqueueDownload(album:), enqueueDownload(playlist:),
    /// toggleDownload(tracks:)) flip live once the core engine lands.
    var supportsDownloads: Bool { false }

    /// `mark_played` / `mark_unplayed` FFIs (#133, #222). Gates
    /// "Mark All as Played" on albums and "Mark as Played" on tracks.
    var supportsMarkPlayed: Bool { true }

    /// Artist-tracks FFI (#156, #465). Gates "Play All" / "Shuffle All"
    /// on artist surfaces. Top-track-driven actions (Play Next via
    /// top-tracks fallback, Start Artist Radio) remain available because
    /// they route through wired FFIs.
    var supportsArtistPlayShuffle: Bool { true }

    /// Track-info sheet (#95). Gates "Show Track Info" on track
    /// context menus.
    var supportsTrackInfo: Bool { true }

    /// Genre actions (#823). Gates the genre context menu (Browse /
    /// Radio / Shuffle / Pin), the `GenreResultRow` row in search, and
    /// the genre detail screen reachable via `Route.genre`. Wired
    /// end-to-end on top of `core.genres`, `core.itemsByGenre`,
    /// `core.tracksByGenre`, and `core.instantMix`; the flag stays as a
    /// kill-switch / regression fallback. See
    /// `supportsMarkPlayed` / `supportsArtistPlayShuffle` for the same
    /// pattern.
    var supportsGenreActions: Bool { true }

    /// Streaming / download quality + preferred-codec selection (#260).
    /// Gates the quality and codec pickers in the Audio pane. These need
    /// the core to thread `MaxStreamingBitrate` + a `DeviceProfile`
    /// (audio codec / container) into the Jellyfin `PlaybackInfo`
    /// request; `core/src/client.rs` has no such parameter yet, so the
    /// pickers would write a preference nothing reads. Disabled until the
    /// core FFI lands rather than presenting controls that don't affect
    /// playback.
    var supportsStreamQualitySelection: Bool { false }

    /// Crossfade between tracks (#116). Gates the crossfade slider in the
    /// Playback pane. Overlapping the tail of one track with the head of
    /// the next needs a second player / mixer in `AudioEngine`; the
    /// engine has no crossfade path today, so the slider would persist a
    /// value nothing honours. Disabled until the engine supports
    /// overlapping playback. Gapless (no-overlap joins) is a separate,
    /// already-wired feature — see `armNextTrackPreload`.
    var supportsCrossfade: Bool { false }
    /// Playlist search results. The current `core.search` endpoint does
    /// not return playlists, so `bucketSearchResults` leaves that bucket
    /// empty. Gating the Playlists scope chip + section behind this flag
    /// keeps the full-search page from exposing a permanently-empty scope
    /// whose section can only ever say "No playlists matched this query."
    /// Flip to `true` — and populate the bucket in `bucketSearchResults`
    /// — once the core surfaces playlists through `search`. Same pattern
    /// as `supportsGenreActions`.
    var supportsPlaylistSearch: Bool { false }
    /// In-app UI localization (#345). Gates the General ▸ Language picker.
    /// The picker only persists `general.language` today — nothing reads it
    /// back to set `AppleLanguages`, override the bundle locale, or otherwise
    /// re-render the UI in another language, and `AppLanguage` only offers
    /// System / English (both no-ops). Flag stays `false` so the inert control
    /// isn't presented as a working setting; flips to `true` once the strings
    /// catalog ships real locales and the runtime override is wired.
    var supportsLanguageSelection: Bool { false }

    /// Theme selection (#405). Gates the Appearance ▸ Theme picker. Choosing a
    /// swatch persists `appearance.theme`, but no live surface reads it back —
    /// `Theme.primary` / `Theme.accent` are still fixed brand constants, so the
    /// selection can't recolour the UI yet (the theme engine wiring is #405).
    /// Flag stays `false` so the picker renders as a disabled "coming soon"
    /// preview rather than masquerading as a working selector; flips to `true`
    /// once `Theme` resolves its accent/primary from the persisted preset.
    var supportsThemeSelection: Bool { false }
}
