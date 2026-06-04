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
