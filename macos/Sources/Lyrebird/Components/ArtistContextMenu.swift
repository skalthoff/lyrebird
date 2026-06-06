import SwiftUI
@preconcurrency import LyrebirdCore

/// Shared right-click / long-press context menu for artist surfaces
/// (library/search rows + artist detail hero).
///
/// Menu order follows Apple Music + Spotify convention and the spec in #97:
///
///     Play All, Shuffle All, Play Next
///     ─
///     Start Artist Radio
///     ─
///     Favorite / Unfavorite, Go to Artist Page
///     ─
///     Copy Link
///
/// `showGoToArtist` is omitted when the menu is invoked from the artist's
/// own detail screen — mirrors the spec's "if invoked elsewhere" qualifier.
/// Defaults to `true` so call sites like grid rows don't need to think
/// about it.
///
/// All backing actions call through to `AppModel` and are wired: Play All /
/// Shuffle All (`tracksByArtist`), Play Next (`playNext`), Start Artist
/// Radio (`instantMix`), Favorite (`setFavorite`), Go to Artist Page, and
/// Copy Link. None are gated behind `supportsDownloads` — this menu has no
/// download action.
struct ArtistContextMenu: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    var showGoToArtist: Bool = true

    var body: some View {
        if model.supportsArtistPlayShuffle {
            Button("Play All", systemImage: "play.fill") { model.playAll(artist: artist) }
            Button("Shuffle All", systemImage: "shuffle") { model.shuffle(artist: artist) }
        }
        // Play Next inserts the artist's full catalog after the current track,
        // matching album/track "Play Next" rather than only the top-tracks teaser.
        Button("Play Next", systemImage: "text.insert") { model.playNextArtist(artist: artist) }

        Divider()

        Button("Start Artist Radio", systemImage: "dot.radiowaves.left.and.right") {
            model.startArtistRadio(artist: artist)
        }

        Divider()

        let isFav = model.isFavorite(artist: artist)
        Button(
            isFav ? "Unfavorite Artist" : "Favorite Artist",
            systemImage: isFav ? "heart.fill" : "heart"
        ) { model.toggleFavorite(artist: artist) }
        if showGoToArtist {
            Button("Go to Artist Page", systemImage: "person") {
                model.goToArtistPage(artist: artist)
            }
        }

        Divider()

        Button("Copy Link", systemImage: "link") { model.copyShareLink(artist: artist) }
            .disabled(model.webURL(for: artist) == nil)
    }
}
