import AppKit
import SwiftUI

/// Advanced / Developer / Debug preferences pane. Closes #267.
///
/// Surfaces three sections of developer-oriented controls:
///
/// 1. **Diagnostic logs** — toggle to enable verbose tracing. The flag is
///    stored in `@AppStorage("advanced.verboseLogging")` so it survives
///    restarts. When on, subsystems that check this key emit fine-grained
///    traces. Opening the log folder button reveals
///    `~/Library/Logs/Jellify/` in Finder — the folder where `os_log`
///    archives land for sandbox-compatible apps.
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
                label: "Log folder",
                help: "Opens ~/Library/Logs/Jellify/ in Finder."
            ) {
                Button {
                    openLogFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open in Finder")
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
                .accessibilityLabel("Open log folder in Finder")
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

    /// Reveals `~/Library/Logs/Jellify/` in Finder, creating the folder if
    /// it doesn't exist yet so Finder doesn't error on a fresh install.
    private func openLogFolder() {
        let logDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jellify")
        try? FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(logDir)
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
