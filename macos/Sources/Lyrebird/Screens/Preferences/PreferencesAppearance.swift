import SwiftUI

// MARK: - Persisted enums

/// Theme preset. Matches the five presets from the design prototype's
/// `THEMES` table (Purple / Ocean / Forest / Sunset / Peanut). Only `purple`
/// is fully wired today — selecting another preset persists the choice so the
/// Tweaks palette and theme engine (#313 / #405) pick it up when they land.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case purple, ocean, forest, sunset, peanut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .purple: return "Purple"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .peanut: return "Peanut"
        }
    }

    /// Representative swatch color used in the theme picker. Sampled from the
    /// design's `primary` token for each preset in
    /// `design/project/src/tokens.jsx`.
    var swatch: Color {
        switch self {
        case .purple: return Color(hex: 0x887BFF)
        case .ocean: return Color(hex: 0x4B7DD7)
        case .forest: return Color(hex: 0x10AF8D)
        case .sunset: return Color(hex: 0xFF6625)
        case .peanut: return Color(hex: 0xD4A360)
        }
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

/// Row density. Wired to the UI-only selector here; `LibraryView` / track
/// lists consume the same `@AppStorage("appearance.density")` value once the
/// density work in #162 lands.
enum AppearanceDensity: String, CaseIterable, Identifiable {
    case roomy, compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .roomy: return "Roomy"
        case .compact: return "Compact"
        }
    }
}

/// Sidebar visibility. UI-only today; the sidebar chrome lives in
/// `Components/Sidebar.swift` and will read this key when auto-hide lands.
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
/// Only the color-scheme mode is wired end-to-end today (via
/// `LyrebirdApp.preferredColorScheme`). The other controls persist the user's
/// choice so the theme engine (#405) and sidebar chrome (#162) pick them up
/// when that work lands. Source: `research/06-screen-specs.md` Issue 64.
struct AppearancePane: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            AppearanceSection(
                title: "Theme",
                hint: "Purple is the shipping default. Other presets persist today and render once the theme engine lands."
            ) {
                ThemePicker(selection: theme)
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
                hint: "Row heights hook in once #162 lands — selection persists now."
            ) {
                SegmentedPicker(
                    options: AppearanceDensity.allCases,
                    selection: density,
                    label: \.label
                )
            }

            AppearanceSection(
                title: "Sidebar",
                hint: "Auto-hide wires up alongside the sidebar chrome work."
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

/// Horizontal row of five colored swatches. The active swatch draws a ring
/// in `Theme.accent` and inks the label. Tapping a swatch updates the
/// binding. Purely visual today — the theme engine itself lands in #405.
private struct ThemePicker: View {
    @Binding var selection: AppearanceTheme

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppearanceTheme.allCases) { theme in
                swatch(theme)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
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
    AppearancePane()
        .padding(32)
        .frame(width: 560, height: 520)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
