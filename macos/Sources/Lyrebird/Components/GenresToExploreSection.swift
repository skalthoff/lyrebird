import SwiftUI

/// Discover "Genres to Explore" grid (#250).
///
/// A 4×2 grid of large (120pt-tall) `GenreExploreTile`s ranked by
/// `AppModel.refreshGenresToExplore()` — the least-explored genres present in
/// the library bubble to the top. Each tile carries a genre whose `id` is the
/// resolved Jellyfin UUID (sourced from `core.genres`), so tapping navigates
/// straight to the genre detail screen without a name→UUID round-trip.
///
/// Hidden entirely when there are no genres so a brand-new / genre-less
/// library doesn't render an empty band. Uses a fixed-column `LazyVGrid`
/// (vertical, not a horizontal `LazyHStack`) so it's clear of the rc9 macOS
/// 26.4 `LazyHStack`-in-horizontal-`ScrollView` UAF.
struct GenresToExploreSection: View {
    @Environment(AppModel.self) private var model

    /// Four flexible columns → the ranked 8 genres lay out as 4×2.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
        count: 4
    )

    var body: some View {
        if !model.genresToExplore.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(Theme.teal)
                        .font(.system(size: 14, weight: .bold))
                    Text("Genres to Explore")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Corners of your library you have barely touched")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.genresToExplore, id: \.id) { genre in
                        GenreExploreTile(genre: genre) {
                            model.navigate(to: .genre(genre))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Genres to Explore")
        }
    }
}

/// One large genre tile for the Discover grid. Bigger than the search-dropdown
/// chip: a 120pt-tall card with a deterministic per-genre gradient so the grid
/// reads as a colorful mosaic rather than a wall of identical chips.
private struct GenreExploreTile: View {
    let genre: Genre
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(gradient)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(isHovering ? 0.35 : 0.12), lineWidth: 1)
                Text(genre.name)
                    .font(Theme.font(17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .padding(14)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(reduceMotion ? 1 : (isHovering ? 1.03 : 1))
            .shadow(
                color: seedColor.opacity(isHovering ? 0.45 : 0.25),
                radius: isHovering ? 14 : 8,
                y: isHovering ? 8 : 4
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Browse \(genre.name)")
        .accessibilityLabel("Explore \(genre.name)")
        .accessibilityHint("Opens the \(genre.name) genre")
        .accessibilityAddTraits(.isButton)
    }

    /// Deterministic base hue derived from the genre name so the same genre
    /// always lands on the same color across launches. Stable, well-spread
    /// hashing via a small FNV-1a over the name's unicode scalars.
    private var seedColor: Color {
        var hash: UInt32 = 2_166_136_261
        for scalar in genre.name.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    /// Diagonal wash from the seed color into a darker shade of itself so the
    /// white label stays legible at the bottom-left.
    private var gradient: LinearGradient {
        var hash: UInt32 = 2_166_136_261
        for scalar in genre.name.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.62, brightness: 0.66),
                Color(hue: hue, saturation: 0.70, brightness: 0.34),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
