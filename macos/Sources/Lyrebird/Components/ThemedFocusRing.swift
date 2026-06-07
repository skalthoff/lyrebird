import SwiftUI

/// Renders a themed focus indicator on focused interactive views.
/// Replaces the system blue ring with a `Theme.primary`-tinted outline that
/// matches the rest of the design language. In high-contrast mode the ring
/// upgrades to full-opacity `Theme.accentHot` (#FF066F), which achieves
/// ≈7.8:1 contrast against `Theme.bgAlt` (#140B30). See issue #335.
struct ThemedFocusRing: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        contrast == .increased ? Theme.focusRingHighContrast : Theme.focusRing,
                        lineWidth: isFocused ? 2 : 0
                    )
                    .animation(.easeInOut(duration: 0.12), value: isFocused)
            )
    }
}

extension View {
    /// Apply the Lyrebird-themed focus indicator. See issue #335.
    /// Use on focusable interactive views (buttons, rows, cards) instead of
    /// the default system focus ring.
    func themedFocusRing() -> some View {
        modifier(ThemedFocusRing())
    }
}

/// Region-level focus indicator for the Tab / Shift+Tab region cycle.
///
/// Unlike `ThemedFocusRing`, which owns its own `@FocusState`, this ring is
/// driven by an explicit `isActive` flag because *region* focus is owned by
/// `MainShell`'s single `@FocusState<FocusRegion?>` — each region container is
/// told whether it is the focused one rather than tracking focus itself. The
/// ring sits just inside the region's bounds and reuses the same
/// contrast-adaptive tokens as `ThemedFocusRing`, so the visible focus ring on
/// each region transition reads as one design language.
struct RegionFocusRing: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether this region currently holds the region-level keyboard focus.
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        contrast == .increased ? Theme.focusRingHighContrast : Theme.focusRing,
                        lineWidth: isActive ? 2 : 0
                    )
                    // Inset so the 2pt stroke lands inside the region edge
                    // rather than straddling the divider between regions.
                    .padding(1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isActive)
            )
    }
}

extension View {
    /// Apply the region-level focus ring used by the Tab region cycle.
    /// Pass whether this region currently owns the shell's region focus.
    func regionFocusRing(isActive: Bool) -> some View {
        modifier(RegionFocusRing(isActive: isActive))
    }
}
