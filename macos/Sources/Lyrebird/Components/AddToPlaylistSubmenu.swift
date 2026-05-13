import SwiftUI
@preconcurrency import LyrebirdCore

/// "Add to Playlist" submenu — shared by the track and album context menus.
/// Renders one `Button` per user-owned playlist. `onPick` lands the chosen
/// playlist in `AppModel`. The submenu intentionally renders a flat list
/// with a hard cap (see `maxPlaylists`) so a pathological 500-playlist
/// library doesn't build a scroll-hostile menu.
struct AddToPlaylistSubmenu: View {
    @Environment(AppModel.self) private var model
    let onPick: (Playlist) -> Void

    /// Safety cap — keeps the submenu usable when the server vends
    /// thousands of playlists. Matches Spotify's behavior.
    private let maxPlaylists = 50

    var body: some View {
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
