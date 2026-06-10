import SwiftUI
@preconcurrency import LyrebirdCore

/// 180pt square album tile used in the Home screen's horizontal album
/// carousels: Jump Back In (#51), Quick Picks (#53), Recently Added (#54),
/// and Favorites (#55).
///
/// Clicking plays the album immediately; double-clicking opens the album
/// detail screen. Right-click surfaces the shared `AlbumContextMenu` with
/// Play / Shuffle / Play Next / Add to Queue / Go to Artist / radio
/// actions. The floating play button lifts in on hover so the tile still
/// reads as a single "open me" affordance in a dense row.
///
/// Intentionally distinct from the library's `AlbumCard` (which is tuned
/// for a grid container that lifts hover state into a shared binding and
/// uses `.adaptive` sizing). This tile is fixed-width and self-contained
/// so it plays nicely in a `LazyHStack` carousel.
///
/// The `badge` closure is called during the artwork overlay phase — use
/// it to stamp a "NEW" chip, a play-count chip, etc. on a specific tile
/// variant without forking the whole component.
struct HomeAlbumTile<Badge: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    /// Optional subtitle override — defaults to `artist · year`. Used by
    /// variants that want a different subline (e.g. "Quick Picks" may
    /// eventually want "Heavy rotation" as a genre chip).
    var subtitle: String?
    /// Accessibility hint suffix. Defaults to "Plays the album" — callers
    /// that want a different hint (e.g. "Opens the album detail") override.
    var hint: String = "Click to play, double-click to open"
    @ViewBuilder let badge: () -> Badge

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
            metadata
        }
        .frame(width: 180)
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 8))
        .scaleEffect(reduceMotion ? 1.0 : (isHovering ? 1.02 : 1.0))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            model.navPath.append(AppModel.Route.album(album.id))
        }
        .onTapGesture(count: 1) {
            model.play(album: album)
        }
        .contextMenu { AlbumContextMenu(album: album) }
        // `.contain` (not `.combine`) so VoiceOver sees the tile group as
        // a container — the outer body is its own focus target with the
        // album's label + hint, but the inline Play button remains a
        // separately-focusable control with its own "Play <album>" label.
        // `.focusable` allows the VoiceOver rotor to Tab into the tile from
        // a horizontal carousel. See #331 / #588.
        .focusable(true)
        .focusEffectDisabled(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(album.name) by \(album.artistName)")
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Artwork(
                url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 400),
                seed: album.name,
                size: 180,
                radius: 8,
                targetPixelSize: CGSize(width: 540, height: 540)
            )
            .frame(width: 180, height: 180)
            // Badge (NEW chip / play-count chip) anchored to the
            // top-leading corner of the artwork itself — using `.overlay`
            // rather than a sibling in the parent ZStack keeps the hit
            // region scoped to the 180×180 tile and means the badge never
            // forces the stack to expand past the artwork's bounds.
            .overlay(alignment: .topLeading) {
                badge()
                    .padding(8)
                    .allowsHitTesting(false)
            }

            Button {
                model.play(album: album)
            } label: {
                Image(systemName: "play.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 16))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.primary))
                    .shadow(color: Theme.primary.opacity(0.5), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(8)
            .opacity(isHovering ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .accessibilityLabel("Play \(album.name)")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isHovering ? Theme.borderStrong : .clear,
                    lineWidth: 1
                )
        )
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.name)
                .font(Theme.font(13, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(subtitle ?? defaultSubtitle)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
        }
        .frame(width: 180, alignment: .leading)
    }

    private var defaultSubtitle: String {
        if let year = album.year, year > 0 {
            return "\(album.artistName) · \(year)"
        }
        return album.artistName
    }
}

// Convenience: allow callers to skip the badge argument when they don't
// need one (most of the time). Swift can't infer `EmptyView` through the
// trailing-closure form, so this overload keeps the call sites clean.
extension HomeAlbumTile where Badge == EmptyView {
    init(album: Album, subtitle: String? = nil, hint: String = "Click to play, double-click to open") {
        self.album = album
        self.subtitle = subtitle
        self.hint = hint
        self.badge = { EmptyView() }
    }
}
