import Foundation

/// Capability flags that gate UI affordances whose backing FFI hasn't
/// landed yet. Each flag is `false` for the 0.2 release; flip to `true`
/// per-feature once the named issue closes.
///
/// Why a flag instead of just deleting the call site: keeping the menu
/// entry, button, and `AppModel` method around — but hidden — means the
/// FFI work that enables it can flip a single flag rather than re-wiring
/// every surface.
extension AppModel {
    /// Download engine (#70, #222). Gates "Download Current" in the
    /// command palette plus per-album / per-playlist / per-track Download
    /// affordances.
    var supportsDownloads: Bool { false }

    /// `mark_played` / `mark_unplayed` FFIs (#133, #222). Gates
    /// "Mark All as Played" on albums and "Mark as Played" on tracks.
    var supportsMarkPlayed: Bool { true }

    /// Artist-tracks FFI (#156, #465). Gates "Play All" / "Shuffle All"
    /// on artist surfaces. Top-track-driven actions (Play Next via
    /// top-tracks fallback, Start Artist Radio) remain available because
    /// they route through wired FFIs.
    var supportsArtistPlayShuffle: Bool { true }

    /// New-playlist picker (#72, #126). Gates the "New Playlist…" entry
    /// at the bottom of Add to Playlist submenus on album and track
    /// surfaces. The route-through helpers `addAlbumToPlaylist` /
    /// `addTracksToPlaylist` remain available — only the picker sheet
    /// is the missing piece.
    var supportsNewPlaylistPicker: Bool { false }

    /// Album metadata editor (#96, #222). Gates "Edit Album…".
    var supportsEditAlbum: Bool { false }

    /// Playlist M3U8 export (#98, #125). Gates "Export as .m3u8…".
    var supportsExportPlaylist: Bool { false }

    /// Track-info sheet (#95). Gates "Show Track Info" on track
    /// context menus.
    var supportsTrackInfo: Bool { true }

    /// Genre actions (#144, #248, #318). Disabled until #318 lands — the
    /// stub actions pass a genre name (e.g. "Jazz") as an item id to
    /// `core.instantMix(itemId:)` which expects a UUID, producing garbage.
    /// Flip to `true` once `browseGenre`, `shuffleGenre`, and
    /// `pinGenreToHome` are wired to real core FFIs.
    var supportsGenreActions: Bool { false }
}
