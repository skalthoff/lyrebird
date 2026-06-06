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
/// Persistence happens inside `moveTrackInPlaylist`, which applies the
/// reorder to the local cache optimistically and then calls
/// `core.reorderPlaylistTrack` to persist the new position on the server,
/// surfacing `errorMessage` on failure. (The move stays local-only only as
/// a fallback when the moved track lacks a `playlistItemId`.)

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
                // Payload encodes the source *index* alongside the track id as
                // "<index>|<trackId>". The index is what disambiguates a
                // duplicated track: a playlist can contain the same track id
                // more than once, so resolving the moved row by id alone would
                // always grab the first copy. Carrying the index lets the drop
                // move the exact copy the user grabbed.
                NSItemProvider(
                    object: NSString(string: PlaylistReorderPayload.encode(index: index, trackId: trackId))
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

/// Wire format for the drag payload: `"<sourceIndex>|<trackId>"`. The source
/// index disambiguates duplicated tracks (same id appearing more than once in
/// a playlist) so the dropped copy is moved by position, not re-derived from
/// the id. The track id is retained for the legacy id-based fallback when a
/// payload arrives without an index (e.g. a stale drag source).
enum PlaylistReorderPayload {
    /// Build the `"<index>|<trackId>"` wire string.
    static func encode(index: Int, trackId: String) -> String {
        "\(index)|\(trackId)"
    }

    /// Parse a payload string into its `(sourceIndex, trackId)` parts.
    ///
    /// Splits on the *first* `|` only, so a track id that itself contains a
    /// pipe round-trips intact. Returns `sourceIndex == nil` when the leading
    /// segment isn't an integer — the caller then falls back to resolving the
    /// move by track id.
    static func decode(_ payload: String) -> (sourceIndex: Int?, trackId: String) {
        guard let sep = payload.firstIndex(of: "|") else {
            // No separator: treat the whole string as a bare track id.
            return (nil, payload)
        }
        let indexPart = String(payload[payload.startIndex..<sep])
        let trackId = String(payload[payload.index(after: sep)...])
        return (Int(indexPart), trackId)
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
            guard let payload = object as? String else { return }
            let parsed = PlaylistReorderPayload.decode(payload)
            Task { @MainActor in
                if let sourceIndex = parsed.sourceIndex {
                    // Preferred path: move the exact copy the user grabbed by
                    // its source index, so duplicated tracks move independently.
                    model.applyPlaylistDrop(
                        playlistId: playlistId,
                        sourceIndex: sourceIndex,
                        destinationIndex: destinationIndex
                    )
                } else {
                    // Legacy fallback: no index in the payload, resolve by id.
                    model.applyPlaylistDrop(
                        playlistId: playlistId,
                        trackId: parsed.trackId,
                        destinationIndex: destinationIndex
                    )
                }
            }
        }
        return true
    }
}
