import SwiftUI
@preconcurrency import JellifyCore

/// Shared right-click / long-press context menu for track rows. Covers
/// both the single-track and multi-selection cases via the `selection`
/// parameter — pass a single-element array for `TrackListRow` / `TrackRow`
/// surfaces and the full selection set for multi-select contexts (tracked
/// in #315).
///
/// Menu order follows Apple Music + Spotify convention and the spec in
/// #95 / #310:
///
///     Play (↩), Play Next, Add to Queue
///     ─
///     Start Song Radio, Add to Playlist →
///     ─
///     Go to Album, Go to Artist, Show Track Info    (single-track only)
///     Remove from Playlist                          (multi-select in playlist)
///     ─
///     Favorite / Unfavorite, Download / Remove Download, Mark as Played / Unplayed
///     ─
///     Copy Link
///
/// For multi-selection: the "Go to …" actions are omitted (they can't
/// disambiguate across a selection); a "Remove from Playlist" action
/// appears when `playlistScope` is non-nil (invoked from a playlist
/// detail view).
///
/// Backing actions call through to `AppModel`. Several are TODO stubs
/// pending FFI work (song radio, track info, download engine,
/// mark-played). Disabled states follow suit per spec.
struct TrackContextMenu: View {
    @Environment(AppModel.self) private var model
    /// The selection this menu acts on. Single-track call sites pass
    /// `[track]`; multi-select surfaces pass every selected track.
    let selection: [Track]
    /// When non-nil, the menu was invoked from within a playlist detail
    /// view; enables the "Remove from Playlist" entry.
    var playlistScope: Playlist?

    private var isMulti: Bool { selection.count > 1 }
    private var first: Track? { selection.first }

    /// Label suffix for actions that span a multi-track selection, e.g.
    /// "Add 5 Songs to Queue". Empty for the single-track case so labels
    /// stay short and canonical.
    private var countSuffix: String {
        guard isMulti else { return "" }
        return " (\(selection.count))"
    }

    var body: some View {
        Button("Play\(countSuffix)", systemImage: "play.fill") {
            model.play(tracks: selection, startIndex: 0)
        }
        .keyboardShortcut(.defaultAction)
        Button("Play Next\(countSuffix)", systemImage: "text.insert") {
            model.playNext(tracks: selection)
        }
        Button("Add to Queue\(countSuffix)", systemImage: "text.append") {
            model.addToQueue(tracks: selection)
        }

        Divider()

        Button("Start Song Radio", systemImage: "dot.radiowaves.left.and.right") {
            if let track = first { model.startSongRadio(track: track) }
        }
        .disabled(isMulti || first == nil)
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            AddToPlaylistSubmenu { playlist in
                model.addTracksToPlaylist(tracks: selection, playlist: playlist)
            } onNewPlaylist: {
                // New-playlist picker is v1.x scope (#126). supportsNewPlaylistPicker
                // gates this button off so this closure is never triggered today.
            }
        }

        Divider()

        // Go-to actions are single-track only per #315.
        if !isMulti, let track = first {
            Button("Go to Album", systemImage: "square.stack") {
                model.goToAlbum(track: track)
            }
            .disabled(track.albumId == nil)
            Button("Go to Artist", systemImage: "person") {
                model.goToArtist(track: track)
            }
            .disabled(track.artistId == nil)
            if model.supportsTrackInfo {
                Button("Show Track Info", systemImage: "info.circle") {
                    model.showTrackInfo(track: track)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        if let scope = playlistScope {
            Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                model.removeTracksFromPlaylist(tracks: selection, playlist: scope)
            }
        }

        if !isMulti || playlistScope != nil { Divider() }

        Button(
            favoriteLabel,
            systemImage: allFavorited ? "heart.slash" : "heart"
        ) { model.toggleFavorite(tracks: selection) }
        if model.supportsDownloads {
            Button(
                downloadLabel,
                systemImage: "arrow.down.circle"
            ) { model.toggleDownload(tracks: selection) }
        }
        if model.supportsMarkPlayed {
            Button(
                markPlayedLabel,
                systemImage: "checkmark.circle"
            ) { model.toggleMarkPlayed(tracks: selection) }
        }

        Divider()

        Button("Copy Link", systemImage: "link") {
            if let track = first { model.copyShareLink(track: track) }
        }
        .disabled(isMulti || first.flatMap { model.webURL(for: $0) } == nil)
    }

    /// True when every track in the selection is already favorited, so the
    /// toggle reads as "Unfavorite" rather than "Favorite".
    private var allFavorited: Bool {
        !selection.isEmpty && selection.allSatisfy { $0.isFavorite }
    }

    private var favoriteLabel: String {
        allFavorited ? "Unfavorite\(countSuffix)" : "Favorite\(countSuffix)"
    }

    private var downloadLabel: String {
        // Download state isn't tracked per-track yet (#70 downloads engine),
        // so the label always reads as "Download" for now. Once state lands
        // this mirrors favorite's all-on / any-off logic.
        "Download\(countSuffix)"
    }

    private var markPlayedLabel: String {
        // Mark-played state tracked by playCount>0 would require per-track
        // inspection; for the selection-aware label we report the canonical
        // "Mark as Played" copy and let the action toggle intelligently.
        "Mark as Played\(countSuffix)"
    }
}
