import SwiftUI

/// Empty state shown inside the queue panel when nothing is enqueued and
/// nothing is playing.
///
/// Design (Issue #296): centered, low-contrast, not an error — just a gentle
/// nudge. A single amethyst-tinted glyph, an 18pt/700 headline, and a 13pt/500
/// subtitle. Mirrors the "empty states" brief in `06-screen-specs.md`.
struct EmptyQueueState: View {
    /// SF Symbol rendered above the headline.
    var systemImage: String = "text.line.first.and.arrowtriangle.forward"
    /// Optional overrides — when `nil`, the catalog-backed defaults load from
    /// `Localizable.xcstrings`. Passing explicit copy is still supported for
    /// places that want a surface-specific phrasing.
    var title: String? = nil
    var subtitle: String? = nil

    private var resolvedTitle: String {
        title ?? String(localized: "empty.queue.title", bundle: .main)
    }
    private var resolvedSubtitle: String {
        subtitle ?? String(localized: "empty.queue.subtitle", bundle: .main)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(resolvedTitle)
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)

                Text(resolvedSubtitle)
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resolvedTitle). \(resolvedSubtitle)")
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Empty queue") {
    EmptyQueueState()
        .frame(width: 320, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
