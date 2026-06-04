import SwiftUI
import AppKit
import CoreImage
import Nuke

/// Two artwork-derived colors used to paint the Now Playing ambient wash
/// (#271). Replaces the theme-default `primary`/`accent` pair so the player
/// background picks up the mood of whatever is on screen.
///
/// The pair is packed to / from a compact `RRGGBB,RRGGBB` hex string so it
/// round-trips cleanly through `AppModel`'s per-album palette cache as an
/// opaque value, with no bespoke codable surface — and so a cached entry
/// re-hydrates to exactly the colors a fresh sample would have produced.
struct AmbientPalette: Equatable {
    let top: Color
    let bottom: Color

    /// The two hex triples backing `top` / `bottom`, kept so the palette can
    /// be re-serialized for the cache without round-tripping through
    /// `NSColor` component extraction (which is lossy across color spaces).
    private let topHex: UInt32
    private let bottomHex: UInt32

    init(topHex: UInt32, bottomHex: UInt32) {
        self.topHex = topHex
        self.bottomHex = bottomHex
        self.top = Color(hex: topHex)
        self.bottom = Color(hex: bottomHex)
    }

    /// `"RRGGBB,RRGGBB"` — the compact cache encoding.
    var encoded: String {
        String(format: "%06X,%06X", topHex, bottomHex)
    }

    /// Parse a `"RRGGBB,RRGGBB"` string produced by `encoded`. Returns `nil`
    /// on any malformed input so a stale / corrupt cache row falls back to a
    /// fresh sample rather than rendering garbage.
    init?(encoded: String) {
        let parts = encoded.split(separator: ",")
        guard parts.count == 2,
              let t = UInt32(parts[0], radix: 16),
              let b = UInt32(parts[1], radix: 16)
        else { return nil }
        self.init(topHex: t, bottomHex: b)
    }
}

/// Off-main sampler that pulls two dominant colors from album artwork via
/// Core Image's `CIAreaAverage` — no third-party Vibrant dependency. The
/// image is split top/bottom and each half is averaged, which gives a pair
/// that reads as a gentle vertical gradient matching the artwork's overall
/// light-to-dark fall rather than two near-identical full-frame averages.
///
/// Each averaged color is nudged toward the dark surface palette (clamped
/// luminance, modest saturation floor) so the wash never blows out to a flat
/// white or a muddy gray on monochrome covers — it stays a *wash*, legible
/// behind white type, per the screen spec's "ambient" intent.
enum PaletteSampler {
    /// Shared CIContext — creating one per sample is expensive (it spins up a
    /// Metal/GL pipeline), and `CIContext` is `Sendable` + internally
    /// thread-safe for rendering, so one shared instance serves every
    /// off-main sample.
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Extract an `AmbientPalette` from a decoded `CGImage`. Runs the Core
    /// Image reductions synchronously; callers invoke it off the main actor
    /// (see `AppModel.ambientPalette`).
    static func palette(from cgImage: CGImage) -> AmbientPalette? {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        guard extent.width >= 2, extent.height >= 2 else { return nil }

        let topRect = CGRect(
            x: extent.minX, y: extent.midY,
            width: extent.width, height: extent.height / 2
        )
        let bottomRect = CGRect(
            x: extent.minX, y: extent.minY,
            width: extent.width, height: extent.height / 2
        )

        guard let topHex = averageHex(of: ci, in: topRect),
              let bottomHex = averageHex(of: ci, in: bottomRect)
        else { return nil }

        return AmbientPalette(topHex: topHex, bottomHex: bottomHex)
    }

    /// Average the pixels of `image` inside `rect` with `CIAreaAverage`, then
    /// render the resulting 1×1 image to a single RGBA8 pixel and tone-map it
    /// for the dark wash.
    private static func averageHex(of image: CIImage, in rect: CGRect) -> UInt32? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect),
        ]), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return toneMappedHex(r: bitmap[0], g: bitmap[1], b: bitmap[2])
    }

    /// Clamp an averaged color into the band that reads well as a dark wash:
    /// floor a little saturation so pure-gray covers don't yield a dead gray,
    /// and cap luminance so a bright cover doesn't wash out the white type.
    private static func toneMappedHex(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        let color = NSColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        color.getHue(&h, saturation: &s, brightness: &v, alpha: nil)

        // Keep some chroma so monochrome covers don't flatten to gray, but
        // hold brightness in a mid-dark band so the wash stays behind type.
        let mappedS = max(0.18, min(s, 0.85))
        let mappedV = max(0.22, min(v, 0.55))
        let mapped = NSColor(hue: h, saturation: mappedS, brightness: mappedV, alpha: 1.0)

        guard let srgb = mapped.usingColorSpace(.sRGB) else { return 0 }
        let ri = UInt32((srgb.redComponent * 255).rounded())
        let gi = UInt32((srgb.greenComponent * 255).rounded())
        let bi = UInt32((srgb.blueComponent * 255).rounded())
        return (ri << 16) | (gi << 8) | bi
    }
}

/// Full-bleed ambient background painted from an `AmbientPalette` (#271).
/// Two radial gradients — one anchored top-leading in the palette's top
/// color, one bottom-trailing in the bottom color — layered over the base
/// `Theme.bg`, then blurred 20pt so it reads as a soft wash rather than two
/// hard spotlights. Mirrors the prototype's twin-radial pattern but sources
/// the colors from artwork instead of the static theme primary/accent.
///
/// When `palette` is `nil` (pre-sample, or extraction failed) it falls back
/// to the theme `primary`/`accent` pair, so the player is never bare.
///
/// Accessibility: under **Reduce Transparency** the radial wash is dropped
/// for a flat `Theme.bg` (no translucent layering), and under **Reduce
/// Motion** the cross-fade between palettes is disabled so a track change
/// snaps rather than animates the background.
struct AmbientWash: View {
    let palette: AmbientPalette?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let top = palette?.top ?? Theme.primary
        let bottom = palette?.bottom ?? Theme.accent

        ZStack {
            Theme.bg
            if !reduceTransparency {
                GeometryReader { geo in
                    let side = max(geo.size.width, geo.size.height)
                    ZStack {
                        RadialGradient(
                            colors: [top.opacity(0.55), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: side * 0.9
                        )
                        RadialGradient(
                            colors: [bottom.opacity(0.55), .clear],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: side * 0.9
                        )
                    }
                    .blur(radius: 20)
                }
                // A faint scrim keeps white type legible over a bright wash.
                Theme.bg.opacity(0.25)
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: palette)
    }
}

// MARK: - Nuke image fetch (palette source)

extension PaletteSampler {
    /// Pull the decoded artwork for `url` out of Nuke's shared pipeline —
    /// reusing the same cache the on-screen `Artwork` already populated, so
    /// sampling never triggers a second network fetch when the art is
    /// already visible — and hand its `CGImage` to the sampler.
    ///
    /// Returns `nil` when the image can't be loaded or decoded; callers treat
    /// that as "no palette" and fall back to the theme wash.
    static func sample(from url: URL) async -> AmbientPalette? {
        let request = ImageRequest(url: url)
        let image: PlatformImage
        do {
            image = try await Artwork.pipeline.image(for: request)
        } catch {
            return nil
        }
        guard let cgImage = image.cgImageForPalette() else { return nil }
        return palette(from: cgImage)
    }
}

private extension PlatformImage {
    /// Best-effort `CGImage` for sampling. `NSImage` may be backed by a vector
    /// or multi-rep source, so go through `cgImage(forProposedRect:)` which
    /// rasterizes the best representation at native size.
    func cgImageForPalette() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
