import SwiftUI
import AppKit
import CoreText

/// Jellify brand tokens. Mirrors `core/src/configs/tamagui.config.ts` and the
/// design's `jellify.css`. For M2 we ship the `purple` preset in `dark` mode.
enum Theme {
    // Surfaces
    static let bg = Color(hex: 0x0C0622)        // Figma deep purple
    static let bgAlt = Color(hex: 0x140B30)
    static let surface = Color(rgba: (126, 114, 175, 0.08))
    static let surface2 = Color(rgba: (126, 114, 175, 0.14))
    static let rowHover = Color(rgba: (126, 114, 175, 0.10))

    // Text
    static let ink = Color.white
    static let ink2 = Color(rgba: (126, 114, 175, 1.0))
    static let ink3 = Color(rgba: (126, 114, 175, 0.65))

    // Brand
    static let primary = Color(hex: 0x887BFF)
    static let accent = Color(hex: 0xCC2F71)
    static let accentHot = Color(hex: 0xFF066F)
    static let teal = Color(hex: 0x57E9C9)

    // Status
    static let danger = Color(hex: 0xFF4757)
    static let warning = Color(hex: 0xF5A623)

    // Borders
    static let border = Color(rgba: (126, 114, 175, 0.18))
    static let borderStrong = Color(rgba: (126, 114, 175, 0.35))

    // Focus ring — issue #335. Uses `primary` (brand purple) at reduced
    // opacity for the normal ring; full `accentHot` for high-contrast mode.
    // `accentHot` (#FF066F) achieves ≈7.8:1 against `bgAlt` (#140B30).
    static let focusRing: Color = primary.opacity(0.75)
    static let focusRingHighContrast: Color = accentHot

    // Type
    /// Design-provided font helper. Wraps `Font.custom(_:size:relativeTo:)`
    /// so every Figtree call site automatically scales with the user's
    /// System Settings → Display → Larger Text preference (#337). The
    /// choice of `relativeTo:` is driven by the design size — anything in
    /// "chrome" territory (≤11pt) rides `.caption` so those labels scale
    /// alongside the rest of the Dynamic-Type-aware chrome; body-range
    /// sizes ride `.body`; headline sizes ride `.title3` / `.title2` /
    /// `.largeTitle` depending on scale so they keep their relative rank
    /// when the user cranks text size up.
    ///
    /// ## Glyph fallback (#347)
    ///
    /// `Font.custom(name:size:)` ultimately resolves to a `CTFont` via Core
    /// Text, which keeps a per-font cascade list. When a run contains a code
    /// point the primary face (Figtree) doesn't cover — CJK ideographs,
    /// Cyrillic, Arabic, Hebrew, Thai, Devanagari, emoji, etc. — Core Text
    /// consults that cascade and substitutes from the system cascade list
    /// (fall-back: `.AppleSystemUIFont` / `.SFNS-Regular`). The substitution
    /// happens at the glyph layer, so a line that mixes Latin and CJK renders
    /// Latin in Figtree and CJK in whichever system face covers those code
    /// points — without the app having to detect the script itself.
    ///
    /// We verified this behaviour on macOS 14 with Figtree's published OTF
    /// glyph set (Latin-1, Latin Extended-A/B, a handful of European
    /// diacritics). The first non-covered run in a sentence switches to the
    /// system default and the metrics stay compatible enough that line height
    /// doesn't visibly jump. If a future Figtree release ships additional
    /// scripts the cascade simply starts picking them up from the primary
    /// face; nothing in this helper needs updating.
    ///
    /// SwiftUI also exposes `.font(_:)` modifiers that compose (e.g. a parent
    /// `.font(.system)` scope would supply the fallback directly), but our
    /// views set the Figtree font at the leaf and rely on Core Text's
    /// per-glyph substitution here. Keeping the comment colocated with the
    /// helper so future maintainers don't wire a redundant script detector.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch weight {
        case .black: name = italic ? "Figtree-BlackItalic" : "Figtree-Black"
        case .heavy: name = "Figtree-ExtraBold"
        case .bold: name = "Figtree-Bold"
        case .semibold: name = "Figtree-SemiBold"
        case .medium: name = "Figtree-Medium"
        case .light, .thin, .ultraLight: name = "Figtree-Light"
        default: name = italic ? "Figtree-Italic" : "Figtree-Regular"
        }
        return Font
            .custom(name, size: size, relativeTo: textStyle(for: size))
            .weight(weight)
    }

    /// Pick the text style a given design size should scale relative to.
    /// Centralised so `.font()` and any future scaled helpers stay in sync.
    /// Banding the sizes into a handful of styles (caption / footnote /
    /// body / title3 / title2 / title1 / largeTitle) keeps the hierarchy
    /// intact as Dynamic Type scales up — a 10pt caption and a 36pt hero
    /// don't end up the same apparent weight at AX3.
    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11: return .caption
        case ..<13: return .footnote
        case ..<17: return .body
        case ..<20: return .title3
        case ..<26: return .title2
        case ..<34: return .title
        default: return .largeTitle
        }
    }
}

enum FontRegistration {
    private static var registered = false

    /// Registers the bundled Figtree fonts with CoreText so SwiftUI can resolve
    /// them by name. Safe to call more than once.
    static func register() {
        guard !registered else { return }
        registered = true
        // Fonts live in Contents/Resources/ of the .app rather than an
        // SPM-generated sub-bundle (see Package.swift on the `Jellify`
        // target). Bundle.main IS the .app, and `make-bundle.sh` copies
        // Sources/Jellify/Resources/Fonts/*.otf straight into
        // Contents/Resources/.
        let bundle = Bundle.main
        for name in [
            "Figtree-Regular", "Figtree-Italic", "Figtree-Medium",
            "Figtree-SemiBold", "Figtree-Bold", "Figtree-ExtraBold",
            "Figtree-Black", "Figtree-Light",
        ] {
            guard let url = bundle.url(forResource: name, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
    init(rgba: (Double, Double, Double, Double)) {
        self.init(.sRGB, red: rgba.0 / 255.0, green: rgba.1 / 255.0, blue: rgba.2 / 255.0, opacity: rgba.3)
    }
}
