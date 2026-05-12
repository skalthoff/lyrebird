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
/// ## Variants
///
/// - **Default** — `ServerUnreachableBanner(onRetry:)` renders the generic
///   copy ("Can't reach your server.") for backwards compatibility with the
///   existing call site in `MainShell`.
/// - **Named server** — `ServerUnreachableBanner(host:onRetry:)` threads
///   the configured host (optionally `host:port`) into the copy, matching
///   issue #101's "Can't reach {server}. Trying again…" design.
struct ServerUnreachableBanner: View {
    /// Host (or `host:port`) displayed in the copy. `nil` falls back to the
    /// generic "your server" wording.
    let host: String?
    let onRetry: () -> Void

    init(host: String? = nil, onRetry: @escaping () -> Void) {
        self.host = host
        self.onRetry = onRetry
    }

    private var message: String {
        if let host, !host.isEmpty {
            return "Can't reach \(host). Trying again\u{2026}"
        }
        return "Can't reach your server."
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
                Text("Retry")
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
            .accessibilityLabel("Retry server connection")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
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
