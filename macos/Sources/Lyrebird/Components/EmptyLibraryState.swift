import SwiftUI
import AppKit

/// Centered empty-state shown when the connected Jellyfin server has no music
/// in its library yet (or is still indexing). Offers an escape hatch to the
/// server's web UI so the user can finish setting things up.
///
/// Design tokens: `surface` pill around the illustration, `ink` headline,
/// `ink2` subtitle, and the primary CTA reuses the pill-button styling from
/// the player controls.
struct EmptyLibraryState: View {
    let serverUrl: URL?

    /// Resolved copy for the a11y-combine label. We pull the catalog values
    /// once here so the composite `Text` uses the same phrasing the rest of
    /// the view renders.
    private var headline: String { String(localized: "empty.library.title", bundle: .main) }
    private var subtitle: String { String(localized: "empty.library.subtitle", bundle: .main) }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Theme.surface2))
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("empty.library.title")
                    .font(Theme.font(22, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("empty.library.subtitle")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let serverUrl {
                Button {
                    NSWorkspace.shared.open(serverUrl)
                } label: {
                    HStack(spacing: 8) {
                        Text("empty.library.open_web")
                            .font(Theme.font(13, weight: .bold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(Theme.primary.opacity(0.2))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Theme.primary, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("empty.library.open_web")
            }
        }
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(subtitle)")
    }
}

#Preview("Empty library — with server URL") {
    EmptyLibraryState(serverUrl: URL(string: "https://jellyfin.example.com"))
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Empty library — no URL") {
    EmptyLibraryState(serverUrl: nil)
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
