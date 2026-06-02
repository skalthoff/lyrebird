import SwiftUI

/// Search "Browse by Genre" tile grid (#247).
///
/// A grid of up to 12 gradient `GenreBrowseTile`s ranked by
/// `AppModel.refreshBrowseGenres()` — the *largest* genres in the library
/// (descending `song_count`) lead, so the empty-search landing surfaces the
/// corners the user is most likely to want to browse. Each tile carries a
/// genre whose `id` is the resolved Jellyfin UUID (sourced from `core.genres`),
/// so tapping navigates straight to the genre detail screen via
/// `AppModel.browseGenre` without a name→UUID round-trip.
///
/// Hidden entirely when there are no genres (a brand-new / genre-less library
/// doesn't render an empty band) or when genre actions are gated off, so the
/// surface never presents tiles that lead to a stubbed destination. Uses a
/// fixed-column `LazyVGrid` (vertical, not a horizontal `LazyHStack`) so it's
/// clear of the rc9 macOS 26.4 `LazyHStack`-in-horizontal-`ScrollView` UAF.
struct BrowseByGenreSection: View {
    @Environment(AppModel.self) private var model

    /// Three flexible columns → the ranked 12 genres lay out as 3×4.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
        count: 3
    )

    var body: some View {
        if model.supportsGenreActions && !model.browseGenres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "guitars")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("Browse by Genre")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("The biggest corners of your library")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.browseGenres, id: \.id) { genre in
                        GenreBrowseTile(genre: genre) {
                            model.browseGenre(genre: genre)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Browse by Genre")
        }
    }
}

/// One gradient genre tile for the Search browse grid. A 96pt-tall card with a
/// deterministic per-genre gradient so the grid reads as a colorful mosaic
/// rather than a wall of identical chips.
private struct GenreBrowseTile: View {
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
                    .font(Theme.font(16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .padding(14)
            }
            .frame(height: 96)
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
        .contextMenu { GenreContextMenu(genre: genre) }
        .help("Browse \(genre.name)")
        .accessibilityLabel("Browse \(genre.name)")
        .accessibilityHint("Opens the \(genre.name) genre")
        .accessibilityAddTraits(.isButton)
    }

    /// Deterministic base hue derived from the genre name so the same genre
    /// always lands on the same color across launches. Stable, well-spread
    /// hashing via a small FNV-1a over the name's unicode scalars — matches
    /// `GenresToExploreSection`'s tile so the two genre surfaces feel like
    /// siblings.
    private var seedColor: Color {
        Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    /// Diagonal wash from the seed color into a darker shade of itself so the
    /// white label stays legible at the bottom-left.
    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.62, brightness: 0.66),
                Color(hue: hue, saturation: 0.70, brightness: 0.34),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// FNV-1a over the genre name's unicode scalars, mapped to a 0–1 hue.
    private var hue: Double {
        var hash: UInt32 = 2_166_136_261
        for scalar in genre.name.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return Double(hash % 360) / 360.0
    }
}
