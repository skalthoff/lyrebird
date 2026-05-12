import SwiftUI
@preconcurrency import LyrebirdCore

/// Shared right-click / long-press context menu for album surfaces
/// (library grid cell + album hero in detail view).
///
/// Menu order follows Apple Music + Spotify convention and the spec in #96:
///
///     Play, Shuffle, Play Next, Add to Queue
///     ─
///     Start Album Radio, Add to Playlist →
///     ─
///     Go to Artist, Go to Album
///     ─
///     Favorite Album, Mark All as Played
///     ─
///     Download, Edit Album…, Copy Link
///
/// `showGoToAlbum` is omitted when the menu is invoked from the album's own
/// detail screen — mirrors the spec's "if invoked from a context outside the
/// album page" qualifier. Defaults to `true` so call sites like the library
/// grid don't need to think about it.
///
/// Many of the backing actions are TODO stubs pending follow-up FFI work
/// (see individual `AppModel` methods for issue refs).
struct AlbumContextMenu: View {
    @Environment(AppModel.self) private var model
    let album: Album
    var showGoToAlbum: Bool = true

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.play(album: album) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(album: album) }
        Button("Play Next", systemImage: "text.insert") { model.playNext(album: album) }
        Button("Add to Queue", systemImage: "text.append") { model.addToQueue(album: album) }

        Divider()

        Button("Start Album Radio", systemImage: "dot.radiowaves.left.and.right") {
            model.startAlbumRadio(album: album)
        }
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            AddToPlaylistSubmenu { playlist in
                model.addAlbumToPlaylist(album: album, playlist: playlist)
            } onNewPlaylist: {
                // New-playlist picker is v1.x scope (#72/#126). supportsNewPlaylistPicker
                // gates this button off so this closure is never triggered today.
            }
        }

        Divider()

        Button("Go to Artist", systemImage: "person") { model.goToArtist(album: album) }
            .disabled(album.artistId == nil)
        if showGoToAlbum {
            Button("Go to Album", systemImage: "square.stack") {
                model.goToAlbum(album: album)
            }
        }

        Divider()

        let isFav = model.isFavorite(album: album)
        Button(isFav ? "Unfavorite Album" : "Favorite Album",
               systemImage: isFav ? "heart.fill" : "heart") {
            model.toggleFavorite(album: album)
        }
        if model.supportsMarkPlayed {
            Button("Mark All as Played", systemImage: "checkmark.circle") {
                model.markAllAsPlayed(album: album)
            }
        }

        Divider()

        if model.supportsDownloads {
            Button("Download", systemImage: "arrow.down.circle") {
                model.enqueueDownload(album: album)
            }
        }
        if model.supportsEditAlbum {
            Button("Edit Album…", systemImage: "pencil") {
                model.requestEditAlbum(album: album)
            }
        }
        Button("Copy Link", systemImage: "link") { model.copyShareLink(album: album) }
            .disabled(model.webURL(for: album) == nil)
    }
}
