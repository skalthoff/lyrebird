import SwiftUI
@preconcurrency import LyrebirdCore

/// Shared right-click / long-press context menu for playlist surfaces
/// (sidebar rows, library grid cards, playlist detail hero).
///
/// Menu order follows Apple Music + Spotify convention and the spec in #98:
///
///     Open
///     ─
///     Play, Shuffle, Play Next, Add to Queue
///     ─
///     Rename (inline), Duplicate, Delete (with confirm)
///     ─
///     Export as M3U…, Export as JSON…, Copy Link  (#237)
///
/// BATCH-06b (#71 / #75):
///   - **Rename** flips the sidebar row into an inline `TextField` (see
///     `AppModel.requestRename`, which sets `sidebarEditingPlaylistId`).
///   - **Duplicate** creates a new "<name> Copy" playlist seeded with the
///     source's tracks via `create_playlist` + `add_to_playlist`. While
///     the round trip is in flight the source row shows a spinner, so the
///     menu item is disabled to prevent a double-fire.
///   - **Delete** opens a `.confirmationDialog` presented by `MainShell`
///     via `AppModel.playlistPendingDelete`; on confirm we call through to
///     `deletePlaylist`, which optimistically removes the playlist and then
///     persists the deletion via `core.deletePlaylist`, rolling back and
///     surfacing `errorMessage` on failure.
struct PlaylistContextMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    private var isCopying: Bool {
        model.sidebarCopyingPlaylistIds.contains(playlist.id)
    }

    var body: some View {
        // Primary action — navigate to the playlist detail view. Pulled up
        // above Play so a single click on a blank area of the row still
        // feels like "open".
        Button("Open", systemImage: "arrow.right.circle") {
            model.goToPlaylist(playlist)
        }

        Divider()

        Button("Play", systemImage: "play.fill") { model.play(playlist: playlist) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(playlist: playlist) }
        Button("Play Next", systemImage: "text.insert") { model.playNext(playlist: playlist) }
        Button("Add to Queue", systemImage: "text.append") { model.addToQueue(playlist: playlist) }

        Divider()

        Button("Rename", systemImage: "pencil") { model.requestRename(playlist: playlist) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.requestDuplicate(playlist: playlist)
        }
        .disabled(isCopying)
        Button("Delete…", systemImage: "trash", role: .destructive) {
            model.confirmDelete(playlist: playlist)
        }

        Divider()

        Button("Export as M3U…", systemImage: "square.and.arrow.up.on.square") {
            model.exportPlaylist(playlist: playlist)
        }
        Button("Export as JSON…", systemImage: "curlybraces") {
            model.exportPlaylistJSON(playlist: playlist)
        }
        Button("Copy Link", systemImage: "link") { model.copyShareLink(playlist: playlist) }
            .disabled(model.webURL(for: playlist) == nil)
    }
}
