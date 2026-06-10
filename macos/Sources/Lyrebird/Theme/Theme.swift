import SwiftUI
import AppKit
import CoreText

/// Lyrebird brand tokens. Mirrors `core/src/configs/tamagui.config.ts` and the
/// design's `lyrebird.css`. For M2 we ship the `purple` preset in `dark` mode.
enum Theme {
    // Surfaces
    static let bg = Color(hex: 0x0C0622)        // Figma deep purple
    static let bgAlt = Color(hex: 0x140B30)
    static let surface = Color(rgba: (126, 114, 175, 0.08))
    static let surface2 = Color(rgba: (126, 114, 175, 0.14))
    static let rowHover = Color(rgba: (126, 114, 175, 0.10))

    /// macOS-native row hover / keyboard-focus background.
    ///
    /// `NSColor.unemphasizedSelectedContentBackgroundColor` is the system's
    /// own token for the unfocused selection tint in list views — it adapts
    /// to dark/light mode and high-contrast automatically, matches
    /// `NSTableView`'s hover semantics, and respects the user's accent color.
    /// Used instead of the bespoke `rowHover` RGBA swatch for list rows,
    /// sidebar rows, and queue items so their hover and keyboard-focus states
    /// read as native macOS affordances rather than brand tints.
    static let nativeHover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    // Text
    static let ink = Color.white
    static let ink2 = adaptive(standard: ink2Standard, increased: ink2HighContrastRGBA)
    static let ink3 = adaptive(standard: ink3Standard, increased: ink3HighContrastRGBA)

    // Brand
    //
    // `primary` / `accent` resolve live from the user's selected `ThemePreset`
    // (#405) via `currentPreset`. The rest of the brand ramp is preset-agnostic.
    static var primary: Color { currentPreset.primary }
    static var accent: Color { currentPreset.accent }
    static let accentHot = Color(hex: 0xFF066F)
    static let teal = Color(hex: 0x57E9C9)

    // Status
    static let danger = Color(hex: 0xFF4757)
    static let warning = Color(hex: 0xF5A623)

    // Borders
    static let border = adaptive(standard: borderStandard, increased: borderHighContrastRGBA)
    static let borderStrong = adaptive(standard: borderStrongStandard, increased: borderStrongHighContrastRGBA)

    // Focus ring — issue #335. Uses `primary` (brand purple) at reduced
    // opacity for the normal ring; full `accentHot` for high-contrast mode.
    // `accentHot` (#FF066F) achieves ≈7.8:1 against `bgAlt` (#140B30).
    static var focusRing: Color { primary.opacity(0.75) }
    static var focusRingHighContrast: Color { accentHighContrast }

    // MARK: - High-contrast variants
    //
    // Resolved when System Settings ▸ Accessibility ▸ Display ▸ Increase
    // Contrast is on (SwiftUI surfaces this as
    // `@Environment(\.colorSchemeContrast) == .increased`). Contrast ratios
    // are measured against `bg` (#0C0622) / `bgAlt` (#140B30) and target
    // WCAG 2.2 AA (4.5:1 body, 3:1 large/UI).
    //
    // The base text/border tokens above are NOT plain colors — they are
    // built by `adaptive(standard:increased:)`, which returns an
    // appearance-resolving `NSColor`. AppKit folds the Increase-Contrast
    // accessibility setting into the resolving `NSAppearance` (the
    // `.accessibilityHighContrast*` appearance names), so every existing
    // call site that reads `Theme.ink2`/`ink3`/`border`/`borderStrong`
    // automatically renders the high-contrast value with no call-site
    // churn. The explicit `*HighContrast` constants below remain the
    // single source of truth for both that adaptive provider and the
    // `AccessibleTheme` wrapper used where a view already observes
    // `colorSchemeContrast` directly.

    // RGBA tuples are the single source of truth. The base tokens (`ink2`,
    // `ink3`, `border`, `borderStrong`) feed both their standard and
    // high-contrast tuples into `adaptive(...)`; the `*HighContrast` /
    // `*Standard` `Color` constants below are derived from the same tuples
    // and consumed by the `AccessibleTheme` wrapper and the unit tests.
    private static let ink2Standard = (126.0, 114.0, 175.0, 1.0)
    private static let ink3Standard = (126.0, 114.0, 175.0, 0.65)
    private static let borderStandard = (126.0, 114.0, 175.0, 0.18)
    private static let borderStrongStandard = (126.0, 114.0, 175.0, 0.35)

    private static let ink2HighContrastRGBA = (198.0, 190.0, 220.0, 1.0)
    private static let ink3HighContrastRGBA = (198.0, 190.0, 220.0, 1.0)
    private static let borderHighContrastRGBA = (170.0, 162.0, 196.0, 1.0)
    private static let borderStrongHighContrastRGBA = (198.0, 190.0, 220.0, 1.0)

    /// Standard secondary text, fixed (non-adaptive) for explicit dispatch.
    static let ink2Base = Color(rgba: ink2Standard)
    /// Standard tertiary text, fixed (non-adaptive) for explicit dispatch.
    static let ink3Base = Color(rgba: ink3Standard)
    /// Standard hairline border, fixed (non-adaptive) for explicit dispatch.
    static let borderBase = Color(rgba: borderStandard)
    /// Standard strong border, fixed (non-adaptive) for explicit dispatch.
    static let borderStrongBase = Color(rgba: borderStrongStandard)

    /// High-contrast secondary text. Opaque lift of `ink2` to ≈7:1 on `bg`,
    /// replacing the marginal 4.6–4.9:1 of the standard token.
    static let ink2HighContrast = Color(rgba: ink2HighContrastRGBA)

    /// High-contrast tertiary text. The standard `ink3` is alpha .65 and
    /// fails (~3:1) at small sizes; this opaque value reaches ≈7:1 on `bg`.
    static let ink3HighContrast = Color(rgba: ink3HighContrastRGBA)

    /// High-contrast body accent. Purple's standard `accent` (#CC2F71, ~3.4:1)
    /// fails for body copy, so it lifts to `accentHot` (#FF066F, ≈6.7:1 on
    /// `bg`). Ocean/Forest ship deliberately light accents that already clear
    /// the HC bar (verified in `ThemePresetTests`), so each keeps its own.
    static var accentHighContrast: Color {
        currentPreset == .purple ? accentHot : currentPreset.accent
    }

    /// High-contrast border. The standard `border` is alpha .18 (~1.4:1,
    /// effectively invisible with Increase Contrast on); this opaque value
    /// renders as a solid, visible hairline.
    static let borderHighContrast = Color(rgba: borderHighContrastRGBA)

    /// High-contrast strong border / divider — solid, no alpha blend.
    static let borderStrongHighContrast = Color(rgba: borderStrongHighContrastRGBA)

    /// Overridable predicate for "is Increase Contrast on?". Production reads
    /// the live system setting; tests substitute a deterministic value so the
    /// adaptive resolution can be asserted without touching the real
    /// accessibility preference. The default reads
    /// `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`, which
    /// is the AppKit mirror of SwiftUI's `colorSchemeContrast == .increased`.
    nonisolated(unsafe) static var isIncreaseContrastEnabled: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Builds a `Color` that resolves to `standard` normally and `increased`
    /// when the Increase-Contrast accessibility setting is on, with no
    /// per-call-site branching.
    ///
    /// The dynamic provider is re-invoked by AppKit whenever the effective
    /// appearance is invalidated — which it is when the user toggles Increase
    /// Contrast (AppKit posts an accessibility-display change that bumps the
    /// effective appearance), so every existing call site that reads the base
    /// `Theme` tokens recolors live with no manual observation.
    private static func adaptive(
        standard: (Double, Double, Double, Double),
        increased: (Double, Double, Double, Double)
    ) -> Color {
        let nsColor = NSColor(name: nil) { _ in
            let rgba = isIncreaseContrastEnabled() ? increased : standard
            return NSColor(
                srgbRed: rgba.0 / 255.0,
                green: rgba.1 / 255.0,
                blue: rgba.2 / 255.0,
                alpha: rgba.3
            )
        }
        return Color(nsColor: nsColor)
    }

    /// The brand `ThemePreset` the user has selected, resolved live from the
    /// persisted `appearance.theme` preference (#405). An absent or legacy
    /// on-disk value (e.g. a dropped "sunset"/"peanut" string) decodes through
    /// `AppearanceTheme(rawValue:) ?? .purple`, so this never yields anything
    /// but a concrete, WCAG-verified preset. Read at colour-resolution time so
    /// `primary` / `accent` recolour the moment a switch lands — `LyrebirdApp`
    /// keys each window's content `.id` on the persisted value to force the
    /// re-render that re-reads these tokens.
    static var currentPreset: ThemePreset {
        let raw = UserDefaults.standard.string(forKey: AppearanceKeys.theme)
        let appearance = raw.flatMap(AppearanceTheme.init(rawValue:)) ?? .purple
        return ThemePreset(appearanceTheme: appearance)
    }

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
        // SPM-generated sub-bundle (see Package.swift on the `Lyrebird`
        // target). Bundle.main IS the .app, and `make-bundle.sh` copies
        // Sources/Lyrebird/Resources/Fonts/*.otf straight into
        // Contents/Resources/.
        let bundle = Bundle.main
        for name in [
            "Figtree-Regular", "Figtree-Italic", "Figtree-Medium",
            "Figtree-SemiBold", "Figtree-Bold", "Figtree-ExtraBold",
            "Figtree-Black", "Figtree-BlackItalic", "Figtree-Light",
        ] {
            guard let url = bundle.url(forResource: name, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Theme presets

/// A brand primary/accent pair, decoupled from the rest of the surface tokens.
///
/// The shipping palette is `purple` (`primary #887BFF` / `accent #CC2F71`).
/// That pair tests *mildly* — the primary and accent collapse toward each
/// other under protanopia and deuteranopia (the two red-green deficiencies
/// that cover ~8% of men), so a colour-blind listener can lose the visual
/// distinction between, say, the brand-primary "now playing" wash and an
/// accent call-to-action. `ThemePreset` adds two alternatives whose pairs stay
/// distinguishable across all three dichromat types:
///
/// - **Ocean** — blue primary + teal-cyan accent. Both ride the
///   blue–yellow axis that protanopes/deuteranopes retain.
/// - **Forest** — green primary + warm-gold accent. The large lightness gap
///   keeps them separable even when hue information is gone.
///
/// Numeric verification (WCAG contrast against `Theme.bg`/`bgAlt`, plus
/// Viénot-1999 dichromat separation of the primary/accent pair) lives in
/// `macos/docs/a11y/color-blindness/README.md` and is asserted by
/// `ThemePresetTests`.
///
/// This type carries only the colour data. `Theme.primary` / `Theme.accent`
/// resolve from the selected preset via `Theme.currentPreset` (#405); the
/// presets also back the picker swatches and `suggestedForAccessibility()`.
enum ThemePreset: String, CaseIterable, Identifiable {
    case purple
    case ocean
    case forest

    var id: String { rawValue }

    /// Map from the persisted `AppearanceTheme` selection. `AppearanceTheme`
    /// now offers only presets with a colour-blind-verified pair, so each maps
    /// one-to-one. Any legacy on-disk value (e.g. a "sunset"/"peanut" string
    /// written before those cases were dropped) never reaches here: the
    /// `@AppStorage` getter decodes through `AppearanceTheme(rawValue:) ??
    /// .purple`, so an unknown string already collapses to `.purple` — a
    /// concrete, validated palette — before this initializer sees it.
    init(appearanceTheme: AppearanceTheme) {
        switch appearanceTheme {
        case .ocean: self = .ocean
        case .forest: self = .forest
        case .purple: self = .purple
        }
    }

    /// Brand primary (large fills, "now playing" wash, active swatch ring).
    var primaryHex: UInt32 {
        switch self {
        case .purple: return 0x887BFF
        case .ocean: return 0x3D7DD6
        case .forest: return 0x178A55
        }
    }

    /// Brand accent (call-to-action chips, badges).
    ///
    /// Ocean pairs the blue primary with a bright teal; Forest pairs the deep
    /// green primary with a warm gold. Both accents are deliberately *much*
    /// lighter than their primary so the pair stays separable on the
    /// lightness axis once hue information is lost to protanopia /
    /// deuteranopia. See `ThemePresetTests` + the a11y doc for the verified
    /// dichromat-separation numbers.
    var accentHex: UInt32 {
        switch self {
        case .purple: return 0xCC2F71
        case .ocean: return 0x47E0D0
        case .forest: return 0xFFD24D
        }
    }

    var primary: Color { Color(hex: primaryHex) }
    var accent: Color { Color(hex: accentHex) }

    /// Preset to prefer when the user has asked the system to convey meaning
    /// without relying on colour alone (System Settings → Accessibility →
    /// Display → "Differentiate without color"). Ocean is the most robust
    /// pair across all dichromat types, so we steer there.
    ///
    /// Returns `nil` when no override is warranted (the flag is off), so
    /// callers can keep the user's explicit choice. Reads
    /// `NSWorkspace`'s live accessibility flag; safe to call on the main
    /// actor only (AppKit requirement).
    static func suggestedForAccessibility() -> ThemePreset? {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor ? .ocean : nil
    }
}

// MARK: - WCAG contrast helpers
//
// Small, dependency-free relative-luminance / contrast-ratio helpers used to
// assert that every shipped preset stays legible against the dark surfaces.
// Kept here next to the tokens so palette edits and their guard test live
// together. Formula per WCAG 2.1 §1.4.3.

extension Color {
    /// WCAG relative luminance of an sRGB hex triple.
    static func relativeLuminance(hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG contrast ratio between two sRGB hex colours (1…21).
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(hex: a)
        let lb = relativeLuminance(hex: b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

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
