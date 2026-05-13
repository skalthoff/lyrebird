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
/// Takes a `Genre` so we have a stable id (name-derived today, real id when
/// the genre-id resolver lands). The browse / radio / shuffle entries still
/// hand `genre.name` to their `String`-typed AppModel stubs; those signatures
/// migrate to `Genre` in Wave 2 of #823.
///
/// All actions call through to `AppModel`. The three radio/browse/shuffle
/// entries remain TODO stubs pending the tracksForGenre / albumsForGenre
/// FFIs tracked in #823.
struct GenreContextMenu: View {
    @Environment(AppModel.self) private var model
    let genre: Genre

    var body: some View {
        // Every entry in this menu is gated on FFIs that don't ship in 0.2
        // (#823). When `supportsGenreActions` flips on these will come back.
        if model.supportsGenreActions {
            Button("Browse genre", systemImage: "square.grid.2x2") {
                model.browseGenre(genre: genre.name)
            }
            Button("Start genre radio", systemImage: "dot.radiowaves.left.and.right") {
                model.startGenreRadio(genre: genre.name)
            }
            Button("Shuffle genre", systemImage: "shuffle") {
                model.shuffleGenre(genre: genre.name)
            }

            Divider()

            Button("Pin to Home", systemImage: "pin") {
                model.pinGenreToHome(genre: genre)
            }
        }
    }
}
