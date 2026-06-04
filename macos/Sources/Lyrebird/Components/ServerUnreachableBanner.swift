import SwiftUI

/// Banner shown when the Jellyfin server is reachable over the network layer
/// but is failing to answer (5xx, connection refused, or repeated timeouts).
///
/// Distinct from `OfflineBanner` — that one surfaces when the system has no
/// usable network at all. This banner assumes we *are* online and instead
/// signals that the configured server endpoint is the problem.
///
/// Design tokens: `warning` (amber) background at 10% opacity, a 3pt amber
/// left border, and a `Retry` action that refetches the library via
/// `AppModel`. Hides automatically when a subsequent fetch succeeds
/// (`ServerReachability.noteSuccess`).
///
/// All user-facing copy is localized through `Localizable.xcstrings` (the
/// `banner.server_unreachable.*` keys + the shared `common.retry`), matching
/// the rest of the UI and the sibling `OfflineBanner`.
///
/// ## Variants
///
/// - **Default** — `ServerUnreachableBanner(onRetry:)` renders the generic
///   copy from `banner.server_unreachable.generic` for backwards compatibility
///   with the existing call site in `MainShell`.
/// - **Named server** — `ServerUnreachableBanner(host:onRetry:)` threads the
///   configured host (optionally `host:port`) into the
///   `banner.server_unreachable.named %@` format, matching issue #101's
///   "Can't reach {server}. Trying again…" design.
struct ServerUnreachableBanner: View {
    /// Host (or `host:port`) displayed in the copy. `nil` falls back to the
    /// generic "your server" wording.
    let host: String?
    let onRetry: () -> Void

    init(host: String? = nil, onRetry: @escaping () -> Void) {
        self.host = host
        self.onRetry = onRetry
    }

    /// Resolved banner copy as a `LocalizedStringKey`. The named-server variant
    /// interpolates the user-supplied host — it's user data, not a translatable
    /// phrase, so only the surrounding scaffolding comes from the catalog
    /// (`banner.server_unreachable.named %@`). The generic fallback goes through
    /// `banner.server_unreachable.generic`. Matches the sibling `OfflineBanner`,
    /// which routes its strings through the catalog the same way.
    private var message: LocalizedStringKey {
        if let host, !host.isEmpty {
            return "banner.server_unreachable.named \(host)"
        }
        return "banner.server_unreachable.generic"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(action: onRetry) {
                Text("common.retry")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.warning.opacity(0.25))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.warning, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("banner.server_unreachable.retry.a11y")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.warning)
                .frame(width: 3)
        }
        // `children: .contain` keeps the banner as a single VoiceOver container
        // while preserving its descendants as individually focusable elements —
        // critically the Retry Button, which a `.combine` flatten would fold into
        // one inert static-text element and make unreachable. The icon is already
        // `accessibilityHidden`, so VoiceOver lands on the message Text and then
        // the actionable Retry button.
        .accessibilityElement(children: .contain)
    }
}

#Preview("Server unreachable — generic") {
    ServerUnreachableBanner(onRetry: {})
        .frame(width: 720)
        .padding()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Server unreachable — named host") {
    ServerUnreachableBanner(host: "jellyfin.example.com:8096", onRetry: {})
        .frame(width: 720)
        .padding()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
