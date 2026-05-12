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
