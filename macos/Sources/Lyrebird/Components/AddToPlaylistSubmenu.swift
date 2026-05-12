import SwiftUI
@preconcurrency import LyrebirdCore

/// "Add to Playlist" submenu — shared by the track and album context menus.
/// Renders one `Button` per user-owned playlist, plus a "New Playlist…"
/// affordance at the top that opens the create-playlist flow.
///
/// Both callbacks land in `AppModel`: `onPick` fires with the chosen
/// playlist, `onNewPlaylist` fires for the create-new shortcut. The
/// submenu intentionally renders a flat list with a hard cap (see
/// `maxPlaylists`) so a pathological 500-playlist library doesn't build
/// a scroll-hostile menu — the spec mentions a search affordance in a
/// future iteration (#72).
///
/// Disabled when `model.playlists` is empty, beyond the "New Playlist…"
/// entry, so the user can still create one inline.
struct AddToPlaylistSubmenu: View {
    @Environment(AppModel.self) private var model
    let onPick: (Playlist) -> Void
    let onNewPlaylist: () -> Void

    /// Safety cap — keeps the submenu usable when the server vends
    /// thousands of playlists. The spec in #72 calls for a search field;
    /// until that lands, capping at 50 matches Spotify's behavior.
    private let maxPlaylists = 50

    var body: some View {
        if model.supportsNewPlaylistPicker {
            Button("New Playlist…", systemImage: "plus") { onNewPlaylist() }
            if !model.playlists.isEmpty { Divider() }
        }
        if !model.playlists.isEmpty {
            ForEach(model.playlists.prefix(maxPlaylists), id: \.id) { playlist in
                Button(playlist.name) { onPick(playlist) }
            }
            if model.playlists.count > maxPlaylists {
                Text("…and \(model.playlists.count - maxPlaylists) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
