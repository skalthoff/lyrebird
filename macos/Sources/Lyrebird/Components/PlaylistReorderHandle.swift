import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import LyrebirdCore

/// BATCH-06b (#73 / #235): Drag-to-reorder affordance for tracks inside a
/// playlist detail view. Shipped as a standalone component because the
/// full `PlaylistDetailView.swift` (BATCH-06a / #540) hasn't merged yet —
/// this file lets the detail view slot reorder in as a wrapper modifier on
/// any track row, and lets `PlaylistView.swift` (the current hero-first
/// playlist screen) adopt it today without a rewrite.
///
/// Usage:
/// ```swift
/// ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
///     TrackRow(track: track, number: idx + 1, ...)
///         .playlistReorderable(
///             playlistId: playlist.id,
///             trackId: track.id,
///             index: idx
///         )
/// }
/// ```
///
/// The modifier wires up:
///   - `onHover` → surfaces a small grabber handle overlay at the leading
///     edge of the row;
///   - `onDrag` → emits the track id as an `NSItemProvider` so the row
///     becomes the drag source;
///   - `onDrop` → reads the source track id and the drop index, then
///     routes both through `AppModel.moveTrackInPlaylist(playlistId:,
///     from:, to:)`.
///
/// Persistence happens inside `moveTrackInPlaylist`, which today is a
/// local-only reorder plus a `TODO(core-#129)` stub. When
/// `move_playlist_item` lands on the core the modifier needs no change.

/// Identifier used for the `NSItemProvider` payload so drops from anywhere
/// outside the playlist-reorder affordance can be rejected cleanly.
/// Scoped under `org.lyrebird` to avoid colliding with any system UTI.
public let lyrebirdPlaylistTrackDragUTI = "org.lyrebird.playlist-track"

extension View {
    /// Wrap a track row in the drag-to-reorder affordance. See the file
    /// header for usage; the `index` argument is the track's current
    /// position in the list, which is what the drop handler mutates
    /// through `AppModel.moveTrackInPlaylist`.
    func playlistReorderable(
        playlistId: String,
        trackId: String,
        index: Int
    ) -> some View {
        modifier(
            PlaylistReorderModifier(
                playlistId: playlistId,
                trackId: trackId,
                index: index
            )
        )
    }
}

/// Internal view-modifier backing `.playlistReorderable`. Holds the hover
/// state so the grabber handle only reveals on pointer-over, and manages
/// the drop indicator rendered immediately above the row that's about to
/// receive a drop.
private struct PlaylistReorderModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let playlistId: String
    let trackId: String
    let index: Int

    @State private var isHovering = false
    /// Whether this row is the current drop target. Drives the thin
    /// accent-coloured insertion line rendered above the row. Driven by
    /// `DropDelegate.dropEntered` / `dropExited`.
    @State private var isDropTarget = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                // Reveal the grabber only on hover so the track list still
                // looks clean at rest. The grabber is purely visual — the
                // entire row is the drag source.
                if isHovering {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .padding(.leading, 2)
                        .accessibilityLabel("Reorder handle")
                }
            }
            .overlay(alignment: .top) {
                // Subtle 2px insertion indicator. Only shows while a drag
                // is live AND this row is the nearest above the cursor.
                if isDropTarget {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .accessibilityHidden(true)
                }
            }
            .onHover { isHovering = $0 }
            .onDrag {
                // Payload is the track id. Consumers key off the registered
                // UTI so drops from other drag sources are rejected.
                NSItemProvider(
                    object: NSString(string: trackId)
                )
            }
            .onDrop(
                of: [UTType.plainText, UTType(lyrebirdPlaylistTrackDragUTI) ?? .plainText],
                delegate: PlaylistReorderDropDelegate(
                    playlistId: playlistId,
                    destinationIndex: index,
                    isDropTarget: $isDropTarget,
                    model: model
                )
            )
    }
}

/// `DropDelegate` that translates a dropped track id into an
/// `AppModel.moveTrackInPlaylist` call. The destination index is the
/// target row's own index in the list — the model's reorder logic uses
/// SwiftUI `move(fromOffsets:toOffset:)` semantics, so dropping onto row
/// N inserts the dragged item at position N (shifting N down).
private struct PlaylistReorderDropDelegate: DropDelegate {
    let playlistId: String
    let destinationIndex: Int
    @Binding var isDropTarget: Bool
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        isDropTarget = true
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            return false
        }
        // Capture for the async closure so we don't need to retain self.
        let playlistId = self.playlistId
        let destinationIndex = self.destinationIndex
        let model = self.model
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let trackId = object as? String else { return }
            Task { @MainActor in
                model.applyPlaylistDrop(
                    playlistId: playlistId,
                    trackId: trackId,
                    destinationIndex: destinationIndex
                )
            }
        }
        return true
    }
}
