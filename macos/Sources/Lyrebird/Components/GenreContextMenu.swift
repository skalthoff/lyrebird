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
/// Takes a `Genre` so we have a stable id (display name today on the Swift
/// `Genre`; the AppModel actions resolve to real Jellyfin UUIDs via the
/// name→UUID cache before dispatching any FFI call). See #823 Wave 2.
///
/// All actions call through to `AppModel`.
struct GenreContextMenu: View {
    @Environment(AppModel.self) private var model
    let genre: Genre

    var body: some View {
        // `supportsGenreActions` stays as a kill-switch so this menu can
        // be disabled wholesale if the genre FFIs regress.
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
