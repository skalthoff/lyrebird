import SwiftUI
import Nuke
import NukeUI

/// Heavily-blurred, dimmed artwork backdrop behind the Now Playing hero
/// (#21). The current cover is decoded once by the hero `Artwork` and reused
/// here straight out of Nuke's shared pipeline, then scaled to fill, blurred,
/// and dropped to a low opacity so it reads as a soft, immersive wash rather
/// than a second copy of the cover.
///
/// Layering contract (see `NowPlayingView.body`): this sits *in front of*
/// `AmbientWash` but *behind* the player content. `AmbientWash` paints the
/// opaque `Theme.bg` base plus the artwork-derived palette gradient, so when
/// this backdrop renders nothing — under **Reduce Transparency**, or before
/// the cover resolves / when there's no art — the wash shows through
/// unchanged. That is the single source of the "fall back to Theme.bg /
/// ambient palette" rule.
///
/// **No double-darken.** The dim here is the *only* scrim applied over the
/// blurred cover: where the cover is opaque it fully occludes `AmbientWash`'s
/// own `0.25` scrim, so the two layers never stack their darkening. The dim is
/// a single top-to-bottom gradient (lighter at the top behind the artwork,
/// heavier toward the metadata column) tuned to keep white type legible on
/// bright covers without muddying dark ones.
struct NowPlayingBackdrop: View {
    /// Size-hinted URL for the current cover, or `nil` when the track has no
    /// artwork — in which case the backdrop renders nothing and the ambient
    /// wash beneath shows through.
    let url: URL?
    /// Track / album name, used only to mirror the hero's decode key; the
    /// blurred backdrop has no fallback gradient of its own (that's the
    /// ambient wash's job), so a seed-derived placeholder would double up.
    let seed: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Blur radius applied to the cover. Large enough that the cover dissolves
    /// into colour/shape rather than reading as a recognisable second thumbnail
    /// of the album art.
    static let blurRadius: CGFloat = 60

    /// Opacity the blurred cover is drawn at before the dim gradient. Low so
    /// the immersive wash never competes with the foreground type.
    static let artworkOpacity: CGFloat = 0.5

    /// Whether the blurred-artwork layer should be drawn at all. Pure so the
    /// Reduce-Transparency fallback and the no-artwork fallback are unit-
    /// testable without booting a SwiftUI scene (see `NowPlayingBackdropTests`).
    ///
    /// Returns `false` under Reduce Transparency (the system asks us to drop
    /// translucent / layered material — the flat `Theme.bg` from `AmbientWash`
    /// is the correct fallback) and `false` when there is no artwork URL to
    /// sample (the ambient palette gradient is the fallback there).
    static func showsArtworkLayer(reduceTransparency: Bool, hasArtwork: Bool) -> Bool {
        !reduceTransparency && hasArtwork
    }

    var body: some View {
        // When the layer is suppressed we render `Color.clear` rather than an
        // empty view so the `.background` ZStack keeps a stable child identity
        // (avoids a layout/transition hiccup when the rule flips on a track or
        // accessibility-setting change), letting the opaque `AmbientWash`
        // beneath provide the full background.
        if NowPlayingBackdrop.showsArtworkLayer(
            reduceTransparency: reduceTransparency,
            hasArtwork: url != nil
        ), let url {
            GeometryReader { geo in
                LazyImage(request: backdropRequest(for: url, in: geo.size)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .opacity(NowPlayingBackdrop.artworkOpacity)
                            .blur(radius: NowPlayingBackdrop.blurRadius)
                            .overlay(dimGradient)
                    } else {
                        // Pre-decode / decode failure: stay transparent so the
                        // ambient wash beneath carries the background. No
                        // seeded placeholder — that's the wash's responsibility.
                        Color.clear
                    }
                }
                .pipeline(Artwork.pipeline)
            }
            .ignoresSafeArea()
            // Cross-fade between covers on a track change so the immersive
            // wash doesn't hard-cut. Disabled under Reduce Motion.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: url)
            // Purely atmospheric — the hero `Artwork` already carries the
            // meaningful cover label, so VoiceOver should skip this layer.
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    /// A vertical dim that keeps white type legible over a bright cover. The
    /// top stays lighter (behind the artwork itself) and it deepens toward the
    /// bottom / metadata. This is the only scrim over the cover — see the
    /// "no double-darken" note in the type doc.
    private var dimGradient: some View {
        LinearGradient(
            colors: [
                Theme.bg.opacity(0.35),
                Theme.bg.opacity(0.55),
                Theme.bg.opacity(0.7),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Decode the cover at a modest pixel size — a 60pt blur destroys detail,
    /// so there's no point holding a full-resolution `CGImage` for the
    /// backdrop. Reuses `Artwork.pipeline`, so when the hero already decoded
    /// this URL the backdrop is a cache hit with no second network fetch.
    /// Mirrors `Artwork`'s `.pixels`-unit resize so Nuke doesn't double-multiply
    /// by screen scale; the side is clamped to a sane floor for tiny windows.
    private func backdropRequest(for url: URL, in size: CGSize) -> ImageRequest {
        let side = max(640, max(size.width, size.height))
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(
                size: CGSize(width: side, height: side),
                unit: .pixels,
                contentMode: .aspectFill,
                crop: false,
                upscale: false
            )
        ]
        return ImageRequest(url: url, processors: processors)
    }
}
