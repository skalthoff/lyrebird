import SwiftUI

/// Breadcrumb trail for the top bar. Renders a path like
/// `Jellify › Library › Albums › The Deep End` where each non-final segment is
/// a tappable control that jumps up to that depth via `onTap(index)`. The
/// final segment is non-interactive (you are already there) and styled as the
/// current location in `Theme.ink`; preceding segments use `Theme.ink2`.
///
/// This is intentionally a pure presentation component: it takes a `[String]`
/// and a closure. Navigation-model integration lives in the caller. A preview
/// at the bottom exercises the component with representative paths.
struct Breadcrumbs: View {
    /// The ordered segments to display, leaf last.
    let segments: [String]
    /// Called when a non-final segment at the given zero-based index is tapped.
    var onTap: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(segments.indices, id: \.self) { idx in
                let segment = segments[idx]
                let isLast = idx == segments.count - 1
                if isLast {
                    Text(segment)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                } else {
                    Button {
                        onTap(idx)
                    } label: {
                        Text(segment)
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Navigate to \(segment)")

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breadcrumbs")
    }
}

#Preview("Breadcrumbs") {
    VStack(alignment: .leading, spacing: 20) {
        Breadcrumbs(segments: ["Jellify"])
        Breadcrumbs(segments: ["Jellify", "Library"])
        Breadcrumbs(segments: ["Jellify", "Library", "Albums"])
        Breadcrumbs(segments: ["Jellify", "Library", "Albums", "The Deep End"])
    }
    .padding(24)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
