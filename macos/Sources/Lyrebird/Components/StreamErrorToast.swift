import SwiftUI

/// Foreground toast shown when a track fails to stream and playback has
/// decided to skip it. The user gets a clear, non-silent acknowledgement —
/// the toast does *not* dismiss itself by auto-advancing; a `Retry` button
/// re-attempts the failed track and a `Go to track` button routes to the
/// track's surface so the user can investigate manually.
///
/// Issue #302. The accompanying low-intensity cue (a 10% danger tint flash on
/// the `PlayerBar`) is driven by `AppModel.streamErrorFlash` — this component
/// doesn't touch `PlayerBar` directly; that's owned by the reliability
/// wiring batch (`BATCH-21`). The caller raises both the toast and the flag
/// together, and lowers the flag after the flash window.
///
/// Design tokens: `danger` text/accent, `bgAlt` surface with a `danger` left
/// border, `ink` primary button, borderless secondary. Sized to sit at the
/// bottom of the content column, above the `PlayerBar`.
struct StreamErrorToast: View {
    /// Track name shown in the copy. Kept plain `String` (not
    /// `LocalizedStringKey`) because it's user data, not a UI string.
    let trackName: String
    /// Called when the user taps `Retry`. Typically re-issues the stream
    /// request via the audio engine.
    let onRetry: () -> Void
    /// Called when the user taps `Go to track`. Typically routes to the
    /// parent album detail or the track's artist page via `AppModel.screen`.
    let onGoToTrack: () -> Void
    /// Called when the user dismisses the toast without acting. Optional —
    /// if `nil`, the toast renders without a close affordance and the caller
    /// is expected to dismiss it on its own timer.
    let onDismiss: (() -> Void)?

    init(
        trackName: String,
        onRetry: @escaping () -> Void,
        onGoToTrack: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.trackName = trackName
        self.onRetry = onRetry
        self.onGoToTrack = onGoToTrack
        self.onDismiss = onDismiss
    }

    private var message: String {
        "\u{201C}\(trackName)\u{201D} couldn't play. Skipping."
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
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
            .accessibilityLabel("stream.error.retry.a11y")

            Button(action: onGoToTrack) {
                Text("stream.error.go_to_track")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("stream.error.go_to_track"))

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("common.dismiss.a11y")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Stream error toast") {
    StreamErrorToast(
        trackName: "Paranoid Android",
        onRetry: {},
        onGoToTrack: {},
        onDismiss: {}
    )
    .frame(width: 640)
    .padding(24)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}

#Preview("Stream error toast — long title, no dismiss") {
    StreamErrorToast(
        trackName: "A Really Long Track Title That Probably Wraps",
        onRetry: {},
        onGoToTrack: {},
        onDismiss: nil
    )
    .frame(width: 480)
    .padding(24)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
