import SwiftUI

/// Compact home-screen quick-action tile: 48pt artwork + title + a floating
/// play-on-hover circle that slides in from the right. Lives in the 3-column
/// quick-tiles row at the top of Home. See #205 / `06-screen-specs.md`.
///
/// The tile is content-agnostic on purpose so the same component can back
/// "recently played" items, "most played" items, and pinned playlists once
/// those data sources land (see #206, #209). `action` fires on tap of the
/// tile surface, `onPlay` fires on the floating play button.
struct HomeQuickTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let subtitle: String?
    let artworkURL: URL?
    /// Seed for the deterministic placeholder gradient when artwork is missing.
    let seed: String
    let action: () -> Void
    let onPlay: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Artwork(url: artworkURL, seed: seed, size: 48, radius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.primary))
                        .shadow(color: Theme.primary.opacity(0.4), radius: 7, y: 6)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .offset(x: reduceMotion ? 0 : (isHovering ? 0 : 8))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHovering)
                .accessibilityLabel("Play \(title)")
            }
            .padding(.vertical, 10)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Theme.surface2 : Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // `.focusable` lets the VoiceOver rotor Tab into the tile from the
        // Home quick-tiles row; `.combine` presents the artwork + text + play
        // button as a single actionable element. See #588.
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isButton)
    }
}
