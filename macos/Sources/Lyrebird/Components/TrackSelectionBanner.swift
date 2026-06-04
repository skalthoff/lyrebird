import SwiftUI
@preconcurrency import LyrebirdCore

/// Bottom-anchored action bar for a multi-track selection (#217). Slides in
/// over the content while at least one row is selected and exposes the
/// spec's batch actions:
///
///     "{n} selected — Play / Queue / Favorite / Add to playlist / Remove"
///
/// `Remove` only appears when `onRemove` is supplied (e.g. a playlist
/// surface); the Library Tracks tab leaves it nil since you can't remove a
/// track from the whole library. All actions route through `AppModel`'s
/// existing selection-aware methods (`play(tracks:)`, `addToQueue(tracks:)`,
/// `toggleFavorite(tracks:)`, `addTracksToPlaylist(tracks:playlist:)`), so
/// the banner is pure presentation.
struct TrackSelectionBanner: View {
    @Environment(AppModel.self) private var model

    /// The currently-selected tracks, in list order.
    let selection: [Track]
    /// Clears the host's selection. Wired to the trailing ✕ and fired after
    /// any terminal action so the banner dismisses itself.
    let onClear: () -> Void
    /// Optional remove handler — present only on surfaces where "remove from
    /// this collection" is meaningful (playlists). Library callers leave it
    /// nil and the Remove button is hidden.
    var onRemove: (() -> Void)? = nil

    private var count: Int { selection.count }

    private var allFavorited: Bool {
        !selection.isEmpty && selection.allSatisfy { model.isFavorite(track: $0) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(CountStrings.label(count, .selected))
                .font(Theme.font(13, weight: .bold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .accessibilityLabel("\(CountStrings.label(count, .tracks)) selected")

            Text("—")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)

            actionButton("Play", systemImage: "play.fill") {
                model.play(tracks: selection, startIndex: 0)
                onClear()
            }
            actionButton("Queue", systemImage: "text.append") {
                model.addToQueue(tracks: selection)
                onClear()
            }
            actionButton(
                allFavorited ? "Unfavorite" : "Favorite",
                systemImage: allFavorited ? "heart.slash" : "heart"
            ) {
                model.toggleFavorite(tracks: selection)
            }

            Menu {
                AddToPlaylistSubmenu { playlist in
                    model.addTracksToPlaylist(tracks: selection, playlist: playlist)
                    onClear()
                }
            } label: {
                bannerLabel("Add to playlist", systemImage: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add \(CountStrings.label(count, .tracks)) to a playlist")

            if let onRemove {
                actionButton("Remove", systemImage: "trash", role: .destructive) {
                    onRemove()
                }
            }

            Spacer(minLength: 8)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Clear selection")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgAlt.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            bannerLabel(title, systemImage: systemImage, destructive: role == .destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) · \(CountStrings.label(count, .tracks)) selected")
    }

    private func bannerLabel(
        _ title: String,
        systemImage: String,
        destructive: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(Theme.font(12, weight: .bold))
        }
        .foregroundStyle(destructive ? Theme.danger : Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(destructive ? Theme.danger.opacity(0.18) : Theme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(destructive ? Theme.danger.opacity(0.6) : Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
