import SwiftUI

/// Skeleton placeholders for in-flight library/track/artist fetches.
///
/// Issue #100 / #102. Three canonical shapes — `albumTile`, `artistTile`,
/// `trackRow` — match the real components they stand in for so first-paint
/// layout stays stable when data arrives. A 200ms linear-gradient shimmer
/// sweeps the base rectangle; `@Environment(\.accessibilityReduceMotion)` is
/// honored — the shimmer is replaced with a static fill when the system
/// preference is on.
///
/// ## Usage note — crossfade to real content
///
/// When the caller swaps the skeleton for real content, wrap the swap in a
/// 120ms crossfade so the transition doesn't feel like a jump-cut:
///
/// ```swift
/// Group {
///     if isLoading {
///         LoadingSkeleton(shape: .albumTile)
///     } else {
///         AlbumCard(album: album)
///     }
/// }
/// .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isLoading)
/// ```
///
/// The 120ms duration matches the hover-reveal timing used elsewhere in the
/// app (`AlbumCard`, `TrackListRow`) so all "state change" motion feels
/// coherent. Respect `reduceMotion` at the call site as shown above — passing
/// `nil` to `.animation` disables the crossfade entirely for that preference.
struct LoadingSkeleton: View {
    /// Predefined sizes matching the real components the skeleton stands in
    /// for. Keep these synced with the components below:
    /// - `albumTile`  → `AlbumCard` square artwork (180pt)
    /// - `artistTile` → `ArtistCard` artwork rendered as a circle (140pt)
    /// - `trackRow`   → `TrackListRow` / `TrackRow` (full width × 56pt)
    enum Shape {
        case albumTile
        case artistTile
        case trackRow
    }

    let shape: Shape

    init(shape: Shape) {
        self.shape = shape
    }

    var body: some View {
        switch shape {
        case .albumTile:
            ShimmerRect(cornerRadius: 8)
                .frame(width: 180, height: 180)
        case .artistTile:
            ShimmerCircle()
                .frame(width: 140, height: 140)
        case .trackRow:
            ShimmerRect(cornerRadius: 6)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        }
    }
}

// MARK: - Shimmer primitives
//
// Both primitives share the same shimmer recipe: a base `surface2` fill with a
// brighter diagonal gradient band sweeping from leading to trailing over
// 200ms. The band is clipped to the container shape so the artist skeleton
// shimmers as a circle and the tile/row skeletons shimmer within rounded
// rectangles. `reduceMotion` short-circuits the sweep to a static fill.

/// Rounded-rectangle shimmer base. Used for album tiles and track rows.
private struct ShimmerRect: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.surface2)
            .overlay {
                if !reduceMotion {
                    ShimmerBand()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Circular shimmer base. Used for artist tiles.
private struct ShimmerCircle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.surface2)
            .overlay {
                if !reduceMotion {
                    ShimmerBand()
                        .clipShape(Circle())
                }
            }
            .accessibilityHidden(true)
    }
}

/// Diagonal gradient band that sweeps across its parent every 200ms.
///
/// Drawn as a stretched `LinearGradient` that we translate along the x-axis
/// from `-width` to `+width` on a 0.2s linear loop. The gradient fades
/// symmetrically so the highlight reads as a single pass rather than a
/// flashing edge. The band is sized 2× parent width so the highlight fully
/// exits the frame before the animation wraps.
private struct ShimmerBand: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geom in
            let width = geom.size.width
            let band = width * 2
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.white.opacity(0.08), location: 0.45),
                    .init(color: Color.white.opacity(0.16), location: 0.5),
                    .init(color: Color.white.opacity(0.08), location: 0.55),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: geom.size.height)
            .offset(x: phase * width)
            .onAppear {
                withAnimation(.linear(duration: 0.2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
        }
    }
}

#Preview("Album tile skeleton") {
    LoadingSkeleton(shape: .albumTile)
        .padding(24)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Artist tile skeleton") {
    LoadingSkeleton(shape: .artistTile)
        .padding(24)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Track row skeleton") {
    LoadingSkeleton(shape: .trackRow)
        .padding(.horizontal, 24)
        .frame(width: 640)
        .padding(.vertical, 24)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Mixed — library first paint") {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            LoadingSkeleton(shape: .albumTile)
            LoadingSkeleton(shape: .albumTile)
            LoadingSkeleton(shape: .albumTile)
        }
        HStack(spacing: 16) {
            LoadingSkeleton(shape: .artistTile)
            LoadingSkeleton(shape: .artistTile)
            LoadingSkeleton(shape: .artistTile)
        }
        VStack(spacing: 8) {
            LoadingSkeleton(shape: .trackRow)
            LoadingSkeleton(shape: .trackRow)
            LoadingSkeleton(shape: .trackRow)
        }
    }
    .padding(32)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
