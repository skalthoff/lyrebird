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

    /// Album metadata editor (#96, #222). Gates "Edit Album…".
    var supportsEditAlbum: Bool { false }

    /// Track-info sheet (#95). Gates "Show Track Info" on track
    /// context menus.
    var supportsTrackInfo: Bool { true }

    /// Genre actions (#823). Disabled until the genre-id resolver +
    /// `tracksForGenre` / `albumsForGenre` FFIs land — the stub actions
    /// today pass a genre name (e.g. "Jazz") as an item id to
    /// `core.instantMix(itemId:)` which expects a UUID, producing garbage.
    /// Flip to `true` once `browseGenre`, `shuffleGenre`, and
    /// `pinGenreToHome` are wired to real core FFIs.
    var supportsGenreActions: Bool { false }
}
