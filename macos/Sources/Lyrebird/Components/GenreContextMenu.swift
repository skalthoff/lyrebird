import SwiftUI
@preconcurrency import LyrebirdCore

/// Context menu for a genre row or chip. Spec: #314.
///
/// Menu order:
///
///     Browse genre, Start genre radio, Shuffle genre
///     ─
///     Pin to Home
///
/// The core does not yet expose a Genre type (genres are surfaced as
/// bare strings on `Album`/`Artist` today), so this menu accepts the
/// genre name directly. When #823 introduces a proper `Genre` struct this
/// view can grow an overload without touching call sites.
///
/// All actions call through to `AppModel`. Every entry here is a TODO
/// stub pending the genre-id resolver + tracksForGenre/albumsForGenre
/// FFIs tracked in #823.
struct GenreContextMenu: View {
    @Environment(AppModel.self) private var model
    let genre: String

    var body: some View {
        // Every entry in this menu is gated on FFIs that don't ship in 0.2
        // (#823). When `supportsGenreActions` flips on these will come back.
        if model.supportsGenreActions {
            Button("Browse genre", systemImage: "square.grid.2x2") {
                model.browseGenre(genre: genre)
            }
            Button("Start genre radio", systemImage: "dot.radiowaves.left.and.right") {
                model.startGenreRadio(genre: genre)
            }
            Button("Shuffle genre", systemImage: "shuffle") {
                model.shuffleGenre(genre: genre)
            }

            Divider()

            Button("Pin to Home", systemImage: "pin") {
                model.pinGenreToHome(genre: genre)
            }
        }
    }
}
