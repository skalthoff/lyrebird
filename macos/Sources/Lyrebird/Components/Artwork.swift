import SwiftUI
import Nuke
import NukeUI

/// Displays an artwork image if the Jellyfin `image_tag` is available, otherwise
/// renders a deterministic gradient placeholder matching the design's Artwork.jsx.
///
/// Backed by Nuke's `LazyImage` so we get:
///   - Disk + memory cache (Nuke.DataCache + ImageCache.shared)
///   - Request coalescing (two cells asking for the same URL fetch once)
///   - Background decoding (`isDecompressionEnabled` on macOS)
///   - Decode-time downscaling via `ImageProcessors.Resize(size:unit:.pixels)`
///   - Memory-pressure eviction (ImageCache is NSCache-backed)
///
/// The `targetPixelSize` tells Nuke what pixel dimensions to decode at —
/// large library grids decode at ~360×360 even if the server ships a 1024px
/// image, so we don't blow memory on a 5k-album grid. Callers that don't pass
/// a pixel size get a sensible default derived from `size` at 2x scale.
///
/// Issue: #426 (Nuke replaces AsyncImage), #427 (size-hinted URLs + decode
/// downscale). `Artwork` is used by album, artist, playlist, track-row, and
/// now-playing surfaces — the default shape is backward-compatible so those
/// screens don't need to change in this batch (see BATCH-20 scope).
struct Artwork: View {
    let url: URL?
    let seed: String
    var size: CGFloat = 120
    var radius: CGFloat = 8
    var overlayLabel: String?
    /// Target decode size in pixels. Nuke downscales during decode to avoid
    /// holding a 1024×1024 CGImage in memory when the cell renders at 180pt.
    /// Defaults to `size * 2` to match typical Retina displays — the 3x
    /// headroom is handled by the `maxWidth` on the URL + disk cache.
    var targetPixelSize: CGSize?

    /// Shared image pipeline for the whole app. Initialised lazily so the
    /// disk cache sets itself up once on first artwork render, then registered
    /// as `ImagePipeline.shared` so any call that doesn't pipe through
    /// `Artwork` (e.g. the SmokeTest target, future prefetcher) picks up the
    /// same cache + decoding config.
    ///
    /// `isDecompressionEnabled = true` overrides the macOS default (off) so
    /// decoding happens on Nuke's dedicated queue rather than on the main
    /// thread when `Image` commits to the layer.
    static let pipeline: ImagePipeline = {
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.jellify.macos.artwork",
            sizeLimit: 256 * 1024 * 1024 // 256 MB on-disk, larger than 150MB
                                         // default so a full library grid
                                         // stays warm across relaunches.
        )
        config.isDecompressionEnabled = true
        // Task coalescing + rate limiter are on by default; spelling them out
        // here so the config's intent reads at a glance.
        config.isTaskCoalescingEnabled = true
        config.isRateLimiterEnabled = true
        let pipeline = ImagePipeline(configuration: config)
        ImagePipeline.shared = pipeline
        return pipeline
    }()

    /// Effective pixel size used to build the decode processor. Uses the
    /// caller's hint when present; otherwise derives from display `size` at
    /// 2x (the common Retina case on Apple Silicon MacBooks).
    private var effectivePixelSize: CGSize {
        if let targetPixelSize { return targetPixelSize }
        return CGSize(width: size * 2, height: size * 2)
    }

    var body: some View {
        ZStack {
            if let url = url {
                LazyImage(request: imageRequest(for: url)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else if state.error != nil {
                        placeholder
                    } else {
                        placeholder
                    }
                }
                .pipeline(Artwork.pipeline)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    /// Build the Nuke request with a resize processor that downscales at
    /// decode. `.pixels` unit means we hand Nuke the literal pixel target so
    /// it doesn't double-multiply by screen scale.
    private func imageRequest(for url: URL) -> ImageRequest {
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(
                size: effectivePixelSize,
                unit: .pixels,
                contentMode: .aspectFill,
                crop: false,
                upscale: false
            )
        ]
        return ImageRequest(url: url, processors: processors)
    }

    private var placeholder: some View {
        let palette = Artwork.palette(for: seed)
        return LinearGradient(
            colors: [palette.0, palette.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomLeading) {
            if let label = overlayLabel {
                Text(label)
                    .font(Theme.font(size * 0.085, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(size * 0.08)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 2)
            }
        }
    }

    private static let paletteHexes: [(UInt32, UInt32)] = [
        (0x2B1E5C, 0x887BFF),
        (0x4B0FD6, 0xFF066F),
        (0x0F3D48, 0x57E9C9),
        (0x3A1655, 0xCC2F71),
        (0x1F1A4A, 0x4B7DD7),
        (0x271055, 0xA96BFF),
        (0x541A2E, 0xFF6625),
        (0x10314F, 0x2FA6D9),
        (0x4A2260, 0xECECEC),
        (0x223355, 0x887BFF),
    ]

    static func palette(for seed: String) -> (Color, Color) {
        var hash: UInt32 = 0
        for byte in seed.utf8 {
            hash = hash &* 31 &+ UInt32(byte)
        }
        let pair = paletteHexes[Int(hash) % paletteHexes.count]
        return (Color(hex: pair.0), Color(hex: pair.1))
    }
}
