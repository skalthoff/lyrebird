import SwiftUI

/// Privacy preferences pane.
///
/// Houses the opt-in "Send crash reports" toggle backed by
/// `CrashReporter.optInKey` (`"privacy.crashReportingEnabled"`).
///
/// **What is sent (when opted in and a DSN is configured):**
/// - Crash stack traces and exception details
/// - macOS version and Lyrebird version/build
/// - Device hardware class (e.g. "Apple M-series Mac")
///
/// **What is never sent:**
/// - Your Jellyfin server address or any credentials
/// - Track, album, artist, playlist, or search query names
/// - IP address or device serial number
/// - Any data from your music library
///
/// **DSN requirement:**
/// Reports are only transmitted when a Sentry DSN has been configured at
/// build time (via `Info.plist` key `LyrebirdSentryDSN`) or via a developer
/// override (`UserDefaults["sentry.dsnOverride"]`). When no DSN is present,
/// the toggle is shown but grayed out with a note explaining that no endpoint
/// is configured in this build — the setting is preserved for when a DSN
/// is later added.
///
/// **Effect timing:**
/// The toggle is persisted immediately. Sentry is initialized once at app
/// startup; enabling the toggle takes effect on the next relaunch.
///
/// Closes #442.
struct PreferencesPrivacy: View {

    @AppStorage(CrashReporter.optInKey) private var crashReportingEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            crashReportingSection

            Spacer(minLength: 0)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privacy")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Control what diagnostic data, if any, Lyrebird may send.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Crash reporting section

    private var crashReportingSection: some View {
        PreferenceSection(
            title: "Crash Reports",
            footnote: crashReportingFootnote
        ) {
            PreferenceRow(
                label: "Send crash reports",
                help: crashReportingHelp
            ) {
                Toggle("", isOn: $crashReportingEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!CrashReporter.isAvailable)
                    .accessibilityLabel("Send crash reports to the Lyrebird development team")
                    .accessibilityHint(
                        CrashReporter.isAvailable
                            ? "Takes effect on the next relaunch."
                            : "Unavailable — no crash-reporting endpoint is configured in this build."
                    )
            }

            if crashReportingEnabled && CrashReporter.isAvailable {
                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                whatIsSharedView
            }

            if !CrashReporter.isAvailable {
                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                noDSNNoteView
            }
        }
    }

    /// Footnote copy adapts based on whether the toggle is currently on/off
    /// and whether a DSN is present.
    private var crashReportingFootnote: String {
        if !CrashReporter.isAvailable {
            return "No crash-reporting endpoint is configured in this build. This setting will take effect once a DSN is configured."
        }
        if crashReportingEnabled {
            return "Crash reports are enabled. They take effect on the next relaunch. You can turn this off at any time."
        }
        return "Off by default. Enable to help identify crashes and improve stability. No data is sent until you opt in."
    }

    /// Per-row help text for the toggle row.
    private var crashReportingHelp: String {
        if !CrashReporter.isAvailable {
            return "No DSN configured in this build — toggle has no effect."
        }
        if crashReportingEnabled {
            return "On — crash reports will be sent starting from the next launch."
        }
        return "Off — no crash data is sent."
    }

    // MARK: - Sub-views

    /// Bullet-list summary of what is shared, shown when the user has opted in.
    private var whatIsSharedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is shared:")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)

            bulletRow(icon: "checkmark.circle.fill", color: Theme.accent,
                      text: "Crash stack traces and exception details")
            bulletRow(icon: "checkmark.circle.fill", color: Theme.accent,
                      text: "macOS version, Lyrebird version, and hardware class")

            Text("What is never shared:")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 4)

            bulletRow(icon: "xmark.circle.fill", color: Theme.ink3,
                      text: "Your Jellyfin server address or any credentials")
            bulletRow(icon: "xmark.circle.fill", color: Theme.ink3,
                      text: "Track, album, artist, playlist, or search query names")
            bulletRow(icon: "xmark.circle.fill", color: Theme.ink3,
                      text: "IP address, device name, or serial number")
        }
        .padding(.horizontal, 4)
    }

    /// Inline note shown when the DSN is absent, so developers can tell at a
    /// glance that the toggle is inert in this build.
    private var noDSNNoteView: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.ink3)
                .font(Theme.font(12))
            Text("No crash-reporting endpoint is configured in this build. "
                 + "Set `Info.plist` key `LyrebirdSentryDSN` at build time to activate.")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func bulletRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(Theme.font(12))
                .frame(width: 16)
            Text(text)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink2)
        }
    }
}

// MARK: - Preview

#Preview {
    PreferencesPrivacy()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
