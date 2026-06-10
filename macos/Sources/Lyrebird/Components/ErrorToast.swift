import SwiftUI

/// Transient surface for `AppModel.errorMessage` in the signed-in shell.
///
/// Every failure path that sets `errorMessage` (library loads, playlist
/// mutations, playback stalls / terminal stream failures via the
/// `AudioEngineDelegate` hooks, drag-and-drop parse errors, …) previously
/// rendered nowhere once the user was past `LoginView` — the message was
/// written and silently overwritten. `MainShell` mounts this toast
/// top-trailing, over whichever screen is active, so those errors are
/// finally visible.
///
/// Behaviour:
///   * The close button clears the message immediately.
///   * The toast auto-dismisses after `autoDismissDelay` — re-keyed per
///     message, so a newer error restarts the clock instead of inheriting
///     the previous message's remaining time.
///
/// Design tokens mirror the established error treatment: `danger`
/// icon/border on a `bgAlt` surface with a 3pt leading rule. The icon and
/// message read as one combined VoiceOver element; the dismiss button stays
/// an independently focusable sibling.
struct ErrorToast: View {
    /// Seconds a message stays up before auto-dismissing. Long enough to
    /// read two lines; short enough that a stale failure doesn't squat over
    /// the toolbar corner. Static so unit tests and previews can reference
    /// the same constant the view sleeps on.
    static let autoDismissDelay: TimeInterval = 6

    /// The user-facing message. Already presentation-quality — call sites
    /// route raw errors through `LyrebirdErrorPresenter` before writing
    /// `errorMessage`.
    let message: String
    /// Clears the message (the caller owns the `errorMessage` slot).
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)

                Text(message)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.dismiss.a11y"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.bgAlt)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.danger)
                .frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
        // Auto-dismiss, re-keyed per message: a newer error cancels the
        // previous sleep and starts its own full window. A cancelled sleep
        // (message changed / toast left the tree) must NOT dismiss the
        // replacement message, so bail on cancellation.
        .task(id: message) {
            try? await Task.sleep(for: .seconds(Self.autoDismissDelay))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

#Preview("Error toast") {
    VStack(spacing: 12) {
        ErrorToast(message: "Couldn't load your library. Check the server and try again.", onDismiss: {})
        ErrorToast(message: "Stalled, retrying…", onDismiss: {})
    }
    .padding(24)
    .background(Theme.bg)
}
