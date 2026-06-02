import AppKit
import SwiftUI

/// Immutable snapshot of everything the Dock tile needs to draw a single
/// frame. The tile lives *outside* any window (`NSApp.dockTile.contentView`),
/// so SwiftUI's Observation machinery never re-evaluates its body on its own —
/// every redraw is driven imperatively by `DockTileController` handing in a
/// fresh snapshot and calling `NSApp.dockTile.display()`. Keeping the input a
/// value type (rather than reading a live `@Observable` model) makes that
/// contract explicit and the view trivially deterministic for previews/tests.
struct DockTileSnapshot: Equatable {
    /// Pre-fetched album art. Resolved off-screen by the controller via the
    /// shared Nuke pipeline so the bitmap is already present when the tile is
    /// asked to draw — an async `LazyImage` would render its placeholder first
    /// and never get a second `display()` to swap in the real art.
    var artwork: NSImage?
    /// Stable string used to pick the deterministic gradient placeholder when
    /// `artwork` is nil (matches `Artwork`'s seeded palette).
    var seed: String
    /// Playback progress in `0...1`. Drives the ring fill. Clamped by the
    /// controller; the view assumes it is already in range.
    var progress: Double
    /// Whether to draw the translucent pause overlay badge.
    var isPaused: Bool

    static let placeholderSeed = "lyrebird"
}

/// SwiftUI view rendered into `NSApp.dockTile.contentView` via an
/// `NSHostingView`. Shows the current album art with a thin progress ring
/// around the tile edge and a pause overlay when playback is paused.
///
/// The ring (rather than a bottom bar) was chosen so progress reads at the
/// small Dock size from any angle — the same affordance Doppler uses.
struct DockTileView: View {
    var snapshot: DockTileSnapshot

    /// Inset of the artwork from the tile edge so the progress ring has room
    /// to breathe without clipping. Expressed as a fraction of the tile side.
    private let inset: CGFloat = 0.06

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = max(2, side * 0.05)
            let artInset = side * inset
            let cornerRadius = (side - artInset * 2) * 0.18

            ZStack {
                artwork
                    .frame(width: side - artInset * 2, height: side - artInset * 2)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        if snapshot.isPaused {
                            pauseOverlay(cornerRadius: cornerRadius)
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: side * 0.04, x: 0, y: side * 0.02)

                progressRing(side: side, ringWidth: ringWidth)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = snapshot.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            let palette = Artwork.palette(for: snapshot.seed)
            LinearGradient(
                colors: [palette.0, palette.1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Thin ring hugging the tile edge. A faint full-circle track sits under a
    /// bright trimmed arc that sweeps clockwise from 12 o'clock as the track
    /// plays.
    private func progressRing(side: CGFloat, ringWidth: CGFloat) -> some View {
        let diameter = side - ringWidth
        return ZStack {
            Circle()
                .stroke(Color.black.opacity(0.28), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, snapshot.progress)))
                .stroke(
                    Theme.primary,
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }

    /// Translucent scrim + pause glyph shown while playback is paused, so a
    /// glance at the Dock tells the user audio is loaded but stopped.
    private func pauseOverlay(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(0.4))
            Image(systemName: "pause.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        }
    }
}
