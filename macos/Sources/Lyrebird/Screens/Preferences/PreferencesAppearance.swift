import SwiftUI

// MARK: - Persisted enums

/// Theme preset. The picker offers only the presets the theme engine can
/// actually render: Purple (the shipping default) plus the two colour-blind-
/// verified alternatives, Ocean and Forest, each backed by a real
/// `ThemePreset` primary/accent pair. The design prototype's `THEMES` table
/// also listed Sunset and Peanut, but those never had a backing `ThemePreset`
/// case — `ThemePreset(appearanceTheme:)` silently folded them into Purple, so
/// offering them would promise a palette the engine can't produce. They're
/// dropped here until a verified pair is designed for each (the getter's
/// `?? .purple` fallback keeps any user who persisted "sunset"/"peanut" valid).
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case purple, ocean, forest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .purple: return "Purple"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        }
    }

    /// Representative swatch color used in the theme picker. Every case ships a
    /// colour-blind-verified `ThemePreset`, so the swatch is derived from
    /// `ThemePreset.primaryHex` — the picker preview always matches the
    /// WCAG-verified accent the preset applies and the two can never drift apart.
    var swatch: Color {
        Color(hex: ThemePreset(appearanceTheme: self).primaryHex)
    }
}

/// Color-scheme mode. `auto` follows the system, `oled` maps to `.dark` at
/// the SwiftUI layer today — the true-black surface wash lands alongside the
/// theme engine (#405). `light` is only meaningful when `theme == .purple`;
/// other presets coerce back to `.dark` for now.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, dark, oled, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .dark: return "Dark"
        case .oled: return "OLED"
        case .light: return "Light"
        }
    }

    /// Resolve to a SwiftUI color scheme. `nil` means "follow the system".
    /// `oled` resolves to `.dark` until the true-black surface wash is wired.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .dark, .oled: return .dark
        case .light: return .light
        }
    }
}

/// Row density. Wired end-to-end: `LibraryView` reads the same
/// `@AppStorage("appearance.density")` value and passes it to `TrackListRow`,
/// which sizes each row off `trackRowHeight` / `trackArtworkSize`.
enum AppearanceDensity: String, CaseIterable, Identifiable {
    case roomy, compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .roomy: return "Roomy"
        case .compact: return "Compact"
        }
    }

    /// Target row height for track lists, per the screen spec (#217): 48pt
    /// roomy / 36pt compact. Row content sizes its artwork + vertical
    /// padding off this so the two densities read distinctly without the
    /// caller having to special-case anything.
    var trackRowHeight: CGFloat {
        switch self {
        case .roomy: return 48
        case .compact: return 36
        }
    }

    /// Square artwork edge inside a track row. Shrinks in compact so the
    /// row can hit the 36pt target without clipping.
    var trackArtworkSize: CGFloat {
        switch self {
        case .roomy: return 40
        case .compact: return 28
        }
    }
}

/// Sidebar visibility. Wired end-to-end: `WindowStateStore` resolves a window's
/// initial column visibility from this key on first launch, and
/// `MainShell.applySidebarAutoHide` enables width-driven auto-hide only when
/// `.autoHide` is selected.
enum AppearanceSidebar: String, CaseIterable, Identifiable {
    case visible, hidden, autoHide = "auto_hide"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visible: return "Visible"
        case .hidden: return "Hidden"
        case .autoHide: return "Auto-hide"
        }
    }
}

// MARK: - AppStorage keys
//
// Keys are namespaced under `appearance.*` so future panes can colonize
// sibling prefixes without collisions.

enum AppearanceKeys {
    static let theme = "appearance.theme"
    static let mode = "appearance.mode"
    static let density = "appearance.density"
    static let sidebar = "appearance.sidebar"
}

// MARK: - Pane

/// Appearance pane — theme, mode, density, sidebar visibility.
///
/// The color-scheme mode (via `LyrebirdApp.preferredColorScheme`), density
/// (via the track-list density work), and sidebar visibility are wired
/// end-to-end. The Theme picker is gated behind `AppModel.supportsThemeSelection`
/// and rendered as a disabled "coming soon" preview: choosing a swatch would
/// only persist `appearance.theme`, which no live surface reads yet — the
/// theme engine that resolves `Theme.primary` / `Theme.accent` from the
/// preset is #405. Source: `research/06-screen-specs.md` Issue 64.
struct AppearancePane: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppearanceKeys.theme) private var themeRaw: String = AppearanceTheme.purple.rawValue
    @AppStorage(AppearanceKeys.mode) private var modeRaw: String = AppearanceMode.dark.rawValue
    @AppStorage(AppearanceKeys.density) private var densityRaw: String = AppearanceDensity.roomy.rawValue
    @AppStorage(AppearanceKeys.sidebar) private var sidebarRaw: String = AppearanceSidebar.visible.rawValue

    private var theme: Binding<AppearanceTheme> {
        Binding(
            get: { AppearanceTheme(rawValue: themeRaw) ?? .purple },
            set: { newValue in
                themeRaw = newValue.rawValue
                // Light is purple-only today. Switching to another theme while
                // in light mode coerces back to dark so the UI doesn't render
                // against an unsupported surface wash.
                if newValue != .purple, modeRaw == AppearanceMode.light.rawValue {
                    modeRaw = AppearanceMode.dark.rawValue
                }
            }
        )
    }

    private var mode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: modeRaw) ?? .dark },
            set: { newValue in
                let currentTheme = AppearanceTheme(rawValue: themeRaw) ?? .purple
                // Ignore a `light` pick when the theme isn't Purple — the
                // segmented control also disables that option visually.
                if newValue == .light, currentTheme != .purple {
                    return
                }
                modeRaw = newValue.rawValue
            }
        )
    }

    private var density: Binding<AppearanceDensity> {
        Binding(
            get: { AppearanceDensity(rawValue: densityRaw) ?? .roomy },
            set: { densityRaw = $0.rawValue }
        )
    }

    private var sidebar: Binding<AppearanceSidebar> {
        Binding(
            get: { AppearanceSidebar(rawValue: sidebarRaw) ?? .visible },
            set: { sidebarRaw = $0.rawValue }
        )
    }

    /// Theme-section helper text. While theme selection is gated off
    /// (`!supportsThemeSelection`) the picker is a disabled preview, so the copy
    /// says so plainly rather than implying the swatch is actionable. Once the
    /// theme engine (#405) lands and the picker is live, the copy steers users
    /// who have asked the system to convey meaning without relying on colour
    /// alone (System Settings → Accessibility → Display → "Differentiate without
    /// color") toward the Ocean preset, whose primary/accent pair stays
    /// distinguishable for every colour-blind type.
    private var themeHint: String {
        guard model.supportsThemeSelection else {
            return "Theme colours are coming soon — the picker previews the palettes; the rest of the app still uses the Purple theme for now."
        }
        if ThemePreset.suggestedForAccessibility() == .ocean,
           (AppearanceTheme(rawValue: themeRaw) ?? .purple) != .ocean {
            return "Your system prefers colour-independent contrast — the Ocean theme keeps the accent distinguishable for every colour-blind type."
        }
        return "Purple is the shipping default. Pick Ocean or Forest for a colour-blind-verified accent pair."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            AppearanceSection(
                title: "Theme",
                hint: themeHint
            ) {
                ThemePicker(selection: theme, isEnabled: model.supportsThemeSelection)
            }

            AppearanceSection(
                title: "Mode",
                hint: theme.wrappedValue != .purple
                    ? "Light is only available for the Purple theme."
                    : nil
            ) {
                SegmentedPicker(
                    options: AppearanceMode.allCases,
                    selection: mode,
                    label: \.label,
                    isDisabled: { option in
                        option == .light && theme.wrappedValue != .purple
                    }
                )
            }

            AppearanceSection(
                title: "Density",
                hint: "Sets track-list row height — Roomy gives taller rows with larger artwork, Compact tightens them so more tracks fit on screen."
            ) {
                SegmentedPicker(
                    options: AppearanceDensity.allCases,
                    selection: density,
                    label: \.label
                )
            }

            AppearanceSection(
                title: "Sidebar",
                hint: "Auto-hide collapses the sidebar on narrow windows and restores it when they widen. Visible keeps it pinned; Hidden starts collapsed."
            ) {
                SegmentedPicker(
                    options: AppearanceSidebar.allCases,
                    selection: sidebar,
                    label: \.label
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Appearance")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Theme, mode, density, and sidebar visibility.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

// MARK: - Section shell

/// Left-aligned section with a title, optional helper text, and content. Used
/// for each group of controls on the Appearance pane so spacing is consistent
/// across rows. Named to avoid collision with the shared `PreferenceSection`
/// over in `PreferencesPlayback.swift`; the two have different control styles
/// (`hint` vs `footnote`) so the Appearance pane keeps its own wrapper.
private struct AppearanceSection<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)

            content()

            if let hint {
                Text(hint)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Theme picker

/// Horizontal row of colored swatches. The active swatch draws a ring in
/// `Theme.accent` and inks the label.
///
/// When `isEnabled` is false the row is a disabled "coming soon" preview: the
/// swatches still show the palettes (and the ring marks the persisted choice),
/// but taps are inert and the row dims, so the picker never masquerades as a
/// working selector while the theme engine (#405) that would consume the
/// selection is still unwired. Once `isEnabled` flips true, tapping a swatch
/// updates the binding.
private struct ThemePicker: View {
    @Binding var selection: AppearanceTheme
    var isEnabled: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AppearanceTheme.allCases) { theme in
                swatch(theme)
            }
            if !isEnabled {
                comingSoonBadge
            }
            Spacer(minLength: 0)
        }
        .opacity(isEnabled ? 1 : 0.55)
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
        // Surface the disabled state to assistive tech so VoiceOver announces
        // the picker as unavailable rather than reading the swatches as
        // tappable selectors.
        .accessibilityValue(isEnabled ? "" : "Coming soon")
    }

    private var comingSoonBadge: some View {
        Text("SOON")
            .font(Theme.font(9, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Theme.surface)
            )
            .overlay(
                Capsule().stroke(Theme.border, lineWidth: 1)
            )
            .padding(.top, 12)
            .accessibilityHidden(true)
    }

    private func swatch(_ target: AppearanceTheme) -> some View {
        let active = selection == target
        return Button {
            selection = target
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(target.swatch)
                        .frame(width: 36, height: 36)
                    if active {
                        Circle()
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: 44, height: 44)
                    }
                }
                .frame(width: 48, height: 48)
                Text(target.label)
                    .font(Theme.font(11, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - Segmented picker

/// Generic segmented control that matches the pill style used elsewhere in
/// the app (`LibraryViewToggle`). Active segment fills with `Theme.ink`;
/// inactive sits in `Theme.ink2`. Disabled segments dim to `Theme.ink3` and
/// ignore taps so constraints like "Light is purple-only" surface visually.
private struct SegmentedPicker<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: KeyPath<Option, String>
    var isDisabled: (Option) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func segment(_ option: Option) -> some View {
        let active = selection == option
        let disabled = isDisabled(option)
        let textColor: Color = {
            if active { return Theme.bg }
            if disabled { return Theme.ink3.opacity(0.55) }
            return Theme.ink2
        }()
        return Button {
            selection = option
        } label: {
            Text(option[keyPath: label])
                .font(Theme.font(12, weight: active ? .bold : .semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Theme.ink : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled && !active)
        .accessibilityLabel(option[keyPath: label])
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

#Preview {
    // Real rendering requires an `AppModel` in the environment; the Settings
    // scene in `LyrebirdApp` injects one. Previews without a model will crash
    // on `@Environment(AppModel.self)` — this preview is kept as documentation
    // for where the view lives.
    AppearancePane()
        .padding(32)
        .frame(width: 560, height: 520)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
