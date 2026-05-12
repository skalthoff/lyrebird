import AppKit
import SwiftUI

/// Advanced / Developer / Debug preferences pane. Closes #267.
///
/// Surfaces three sections of developer-oriented controls:
///
/// 1. **Diagnostic logs** — toggle to enable verbose tracing. The flag is
///    stored in `@AppStorage("advanced.verboseLogging")` so it survives
///    restarts. When on, subsystems that check `Log.isVerbose` emit
///    `.debug`-level traces in addition to the always-on `.info` /
///    `.notice` / `.error` levels. The "Open in Console.app" button
///    launches Console with a pre-applied `subsystem:org.jellify.desktop`
///    filter so streaming logs is one click away. The "Copy `log stream`
///    command" button puts a ready-to-paste `log stream` invocation in
///    the clipboard for users on the Terminal.
///
/// 2. **Reset state** — two destructive-ish actions behind confirm dialogs:
///    - *Reset onboarding* writes `false` to `hasCompletedOnboarding`
///      (same key used by `OnboardingView`) so the welcome / server-setup
///      flow re-runs on the next launch.
///    - *Clear caches* removes the `~/Library/Caches/<bundle-id>/` tree —
///      artwork tiles and other ephemeral data. Does not touch stored
///      credentials or user preferences.
///
/// 3. **Show internal IDs** — toggle stored in
///    `@AppStorage("advanced.showInternalIds")`. When enabled, detail views
///    can surface the raw Jellyfin UUID alongside the display name so
///    engineers can copy item IDs for API calls without leaving the app.
///
/// All controls use `@AppStorage` — no AppModel mutations, no core FFI.
/// Destructive buttons are guarded by `confirmationDialog` alerts so
/// accidental taps don't cause irreversible state changes.
///
/// Spec: `research/03-ux-patterns.md` → Advanced bullet. GitHub #267.
struct PreferencesAdvanced: View {

    // MARK: - Stored preferences

    @AppStorage("advanced.verboseLogging") private var verboseLogging: Bool = false
    @AppStorage("advanced.showInternalIds") private var showInternalIds: Bool = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = true

    // MARK: - Ephemeral UI state

    @State private var showResetOnboardingConfirm = false
    @State private var showClearCachesConfirm = false
    @State private var onboardingResetDone = false
    @State private var cachesClearedDone = false
    @State private var copyCommandDone = false
    @State private var consoleHintShown = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            diagnosticLogsSection
            resetStateSection
            internalIDsSection

            Spacer(minLength: 0)
        }
        .confirmationDialog(
            "Reset Onboarding?",
            isPresented: $showResetOnboardingConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                hasCompletedOnboarding = false
                onboardingResetDone = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The welcome and server-setup flow will run the next time Jellify launches. Your credentials and preferences are not affected.")
        }
        .confirmationDialog(
            "Clear Caches?",
            isPresented: $showClearCachesConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Caches", role: .destructive) {
                clearCaches()
                cachesClearedDone = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artwork tiles and other temporary data will be removed. Your music library and settings are not affected.")
        }
    }

    // MARK: - Sections

    private var diagnosticLogsSection: some View {
        PreferenceSection(
            title: "Diagnostic Logs",
            footnote: "Verbose tracing writes additional entries to the system log. Enable only when troubleshooting — it increases disk and CPU overhead slightly."
        ) {
            PreferenceRow(
                label: "Enable verbose tracing",
                help: verboseLogging
                    ? "On — fine-grained trace events are emitted to the system log."
                    : "Off — only warnings and errors are logged."
            ) {
                Toggle("", isOn: $verboseLogging)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable verbose logging")
            }

            Divider()
                .background(Theme.border)
                .padding(.vertical, 10)

            PreferenceRow(
                label: "Stream logs",
                help: streamLogsHelp
            ) {
                HStack(spacing: 8) {
                    logActionButton(
                        title: consoleHintShown ? "Paste in search bar" : "Open in Console.app",
                        systemImage: consoleHintShown ? "doc.on.clipboard" : "doc.text.magnifyingglass",
                        action: openLogsInConsole,
                        accessibilityLabel: "Open Console.app and copy a Jellify filter to the clipboard"
                    )
                    logActionButton(
                        title: copyCommandDone ? "Copied" : "Copy log command",
                        systemImage: copyCommandDone ? "checkmark" : "terminal",
                        action: copyLogCommandToClipboard,
                        accessibilityLabel: "Copy a log stream command to the clipboard"
                    )
                }
            }
        }
    }

    private var resetStateSection: some View {
        PreferenceSection(
            title: "Reset State",
            footnote: "These actions are reversible but disruptive — use them when diagnosing startup or library issues."
        ) {
            PreferenceRow(
                label: "Onboarding",
                help: onboardingResetDone
                    ? "Reset — the setup flow will reappear on the next launch."
                    : "Clears the onboarding-complete flag so the welcome flow re-runs on next launch."
            ) {
                Button {
                    showResetOnboardingConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Onboarding")
                    }
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset onboarding flag")
                .accessibilityHint("Causes the welcome setup flow to appear on the next app launch.")
            }

            Divider()
                .background(Theme.border)
                .padding(.vertical, 10)

            PreferenceRow(
                label: "Caches",
                help: cachesClearedDone
                    ? "Cleared — artwork and temporary files have been removed."
                    : "Removes artwork tiles and other temporary files. Credentials and preferences are preserved."
            ) {
                Button {
                    showClearCachesConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Clear Caches")
                    }
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear caches")
                .accessibilityHint("Deletes temporary files including artwork. Your library and settings are untouched.")
            }
        }
    }

    private var internalIDsSection: some View {
        PreferenceSection(
            title: "Show Internal IDs",
            footnote: "Useful when filing issues or testing API calls. IDs appear alongside display names in track, album, and artist detail views."
        ) {
            PreferenceRow(
                label: "Show UUIDs in detail views",
                help: showInternalIds
                    ? "On — Jellyfin item IDs are displayed beside names in detail views."
                    : "Off — detail views show display names only."
            ) {
                Toggle("", isOn: $showInternalIds)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Show internal item IDs")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Advanced")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Diagnostic logs, reset state, and developer options.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Helpers

    /// Help-text generator for the Stream Logs row. Mentions both the
    /// streaming and the persistence semantics so the user knows entries
    /// don't survive across reboots unless `log show` is run.
    private var streamLogsHelp: String {
        if consoleHintShown {
            return "Console is open — paste (⌘V) into its search bar to filter for Jellify entries."
        }
        if copyCommandDone {
            return "Command copied — paste it into Terminal to start streaming."
        }
        return "Stream Jellify's `os.Logger` output. Console.app is GUI-friendly; the copied `log stream` command is the same data on the Terminal."
    }

    /// Open Console.app and pre-load the clipboard with a search-friendly
    /// filter so the user can land in the app and `⌘F`+`⌘V` to filter for
    /// Jellify entries.
    ///
    /// Why not deep-link with a URL scheme: Console.app registers no
    /// `CFBundleURLTypes` (verified on macOS 26.4 — the previously-shipped
    /// `x-apple-syslog:?subsystem=…` scheme was an invented one and silently
    /// failed). AppleScript-driving the search field would work but requires
    /// the user to grant accessibility permissions to Jellify, which is a
    /// heavyweight ask for a debug button. Clipboard + alert is two extra
    /// keystrokes for the user, no permissions, no failure modes.
    ///
    /// The clipboard payload is just `subsystem:org.jellify.desktop` —
    /// Console's search bar accepts that token directly and applies it as a
    /// scoped filter (versus typing the same string into a free-text search
    /// which matches as substring across all fields).
    private func openLogsInConsole() {
        let filter = "subsystem:org.jellify.desktop"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(filter, forType: .string)

        // Bring Console forward by bundle id; falls back to launching by
        // path if `urlForApplication(withBundleIdentifier:)` returns nil
        // (rare — Console is in the system Utilities folder by default).
        if let consoleURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Console"
        ) {
            NSWorkspace.shared.open(consoleURL)
        } else {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
            )
        }

        consoleHintShown = true
        // Auto-dismiss the hint after a few seconds so the row doesn't stay
        // stuck on "Paste in search bar" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            consoleHintShown = false
        }
    }

    /// Copy a ready-to-paste `log stream` invocation to the clipboard.
    /// `--info --debug` is included because the default predicate-stream
    /// only surfaces `.notice` and above — useful logs (timing, cache
    /// hits, FFI traces) live at `.info` / `.debug`.
    private func copyLogCommandToClipboard() {
        let cmd = "log stream --predicate 'subsystem == \"org.jellify.desktop\"' --info --debug --style compact"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        copyCommandDone = true
        // Reset the visual confirmation after a few seconds so the button
        // doesn't look stuck on "Copied" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            copyCommandDone = false
        }
    }

    /// Shared chrome for the two log-action buttons so they stay visually
    /// consistent without repeating the modifier stack.
    @ViewBuilder
    private func logActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Removes the app's `Caches` sandbox directory subtree. This clears
    /// artwork tiles and any other ephemeral blobs the app has written.
    /// Credentials (Keychain), preferences (UserDefaults / AppStorage),
    /// and downloaded offline tracks are stored elsewhere and are not
    /// affected.
    private func clearCaches() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? fm.removeItem(at: caches)
        // Recreate the directory so subsequent writes don't fail.
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
    }
}

// MARK: - Preview

#Preview {
    PreferencesAdvanced()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
