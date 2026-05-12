import SwiftUI

/// Centered empty state shown in `SearchView` when the user has submitted a
/// non-empty query but the server returned zero hits across artists, albums,
/// and tracks.
///
/// Not used for an empty query — that path is owned by `SearchView` and
/// should surface recent/categorized content instead.
struct NoSearchResultsState: View {
    let query: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)

            Text("No results for \u{201C}\(query)\u{201D}")
                .font(Theme.font(18, weight: .bold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("Try a different spelling, or use fewer or different terms.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No results for \(query). Try a different spelling, or use fewer or different terms.")
    }
}

#Preview("No search results") {
    NoSearchResultsState(query: "whale songs")
        .frame(width: 720, height: 360)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
