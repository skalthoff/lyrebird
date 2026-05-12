import SwiftUI

/// Banner shown at the top of the content column when the system is offline.
///
/// Design tokens: `danger` background at 10% opacity, a 3pt `danger` left
/// border, and a `Retry` action that re-evaluates network state and refetches
/// the library via `AppModel`. The banner hides automatically when
/// connectivity returns (debounced by `NetworkMonitor`).
///
/// ## Variants
///
/// - **Default** — `OfflineBanner(onRetry:)` renders the generic offline
///   message: "You're offline. Playing from downloaded tracks only."
/// - **Named server** — `OfflineBanner(host:onRetry:)` renders the
///   issue-#101 copy: "Can't reach {host}. Trying again…" with the same
///   Retry action. Use this when the caller knows the configured server
///   host and wants to thread that into the copy.
struct OfflineBanner: View {
    /// Optional server host/URL surfaced in the copy. When `nil`, falls
    /// back to the generic offline message.
    let host: String?
    let onRetry: () -> Void

    init(host: String? = nil, onRetry: @escaping () -> Void) {
        self.host = host
        self.onRetry = onRetry
    }

    /// Resolved copy for the banner. The named-server variant interpolates
    /// the user-supplied host verbatim — it's user data, not a translatable
    /// phrase, so only the surrounding scaffolding comes from the catalog.
    /// The generic fallback goes through `Localizable.xcstrings` via the
    /// `offline.generic` key.
    private var message: String {
        if let host, !host.isEmpty {
            return "Can't reach \(host). Trying again\u{2026}"
        }
        return String(localized: "offline.generic", bundle: .main)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
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
                            .fill(Theme.danger.opacity(0.25))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.danger, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("offline.retry.a11y")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.danger)
                .frame(width: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Offline banner — generic") {
    OfflineBanner(onRetry: {})
        .frame(width: 720)
        .padding()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Offline banner — named server (#101)") {
    OfflineBanner(host: "jellyfin.example.com", onRetry: {})
        .frame(width: 720)
        .padding()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
