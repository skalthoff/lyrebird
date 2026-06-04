import AppKit
import Nuke
import SwiftUI

/// Advanced / Developer / Debug preferences pane. Closes #267.
///
/// Surfaces two sections of developer-oriented controls:
///
/// 1. **Diagnostic logs** — toggle to enable verbose tracing. The flag is
///    stored in `@AppStorage("advanced.verboseLogging")` so it survives
///    restarts. When on, subsystems that check `Log.isVerbose` emit
///    `.debug`-level traces in addition to the always-on `.info` /
///    `.notice` / `.error` levels. The "Open in Console.app" button
///    launches Console with a pre-applied `subsystem:org.lyrebird.desktop`
///    filter so streaming logs is one click away. The "Copy `log stream`
///    command" button puts a ready-to-paste `log stream` invocation in
///    the clipboard for users on the Terminal.
///
/// 2. **Reset state** — two destructive-ish actions behind confirm dialogs:
///    - *Reset onboarding* writes `false` to `hasCompletedOnboarding`
///      (same key used by `OnboardingView`) so the welcome / server-setup
///      flow re-runs on the next launch.
///    - *Clear caches* evicts **only** the artwork cache (the same Nuke
///      pipeline cache the Library pane clears) and its on-disk directory.
///      It deliberately does **not** touch the caches root, so offline
///      downloads (`Caches/Downloads`, see `PreferencesDownloads`), stored
///      credentials, and user preferences all survive.
///
/// All controls use `@AppStorage` — no AppModel mutations, no core FFI.
/// Destructive buttons are guarded by `confirmationDialog` alerts so
/// accidental taps don't cause irreversible state changes.
///
/// Spec: `research/03-ux-patterns.md` → Advanced bullet. GitHub #267.
struct PreferencesAdvanced: View {

    // MARK: - Stored preferences

    @AppStorage("advanced.verboseLogging") private var verboseLogging: Bool = false
    // Default must match the other two declarations (LyrebirdApp.swift,
    // OnboardingView.swift) so the absent-key state agrees app-wide: a
    // never-written key reads `false` everywhere, which means onboarding
    // runs on a fresh install.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    // MARK: - Ephemeral UI state

    @State private var showResetOnboardingConfirm = false
    @State private var showClearCachesConfirm = false
    @State private var onboardingResetDone = false
    @State private var cachesClearedDone = false
    @State private var cachesClearInProgress = false
    @State private var cachesClearError: String?
    @State private var copyCommandDone = false
    @State private var consoleHintShown = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            diagnosticLogsSection
            resetStateSection

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
            Text("The welcome and server-setup flow will run the next time Lyrebird launches. Your credentials and preferences are not affected.")
        }
        .confirmationDialog(
            "Clear Caches?",
            isPresented: $showClearCachesConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Caches", role: .destructive) {
                clearCaches()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached artwork will be removed. Your music library, offline downloads, and settings are not affected.")
        }
        .alert(
            "Couldn't Clear Caches",
            isPresented: Binding(
                get: { cachesClearError != nil },
                set: { if !$0 { cachesClearError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { cachesClearError = nil }
        } message: {
            Text(cachesClearError ?? "")
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
                        accessibilityLabel: "Open Console.app and copy a Lyrebird filter to the clipboard"
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
                    ? "Cleared — cached artwork has been removed."
                    : "Removes cached artwork. Offline downloads, credentials, and preferences are preserved."
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
                .accessibilityHint("Removes cached artwork. Your library, offline downloads, and settings are untouched.")
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
            return "Console is open — paste (⌘V) into its search bar to filter for Lyrebird entries."
        }
        if copyCommandDone {
            return "Command copied — paste it into Terminal to start streaming."
        }
        return "Stream Lyrebird's `os.Logger` output. Console.app is GUI-friendly; the copied `log stream` command is the same data on the Terminal."
    }

    /// Open Console.app and pre-load the clipboard with a search-friendly
    /// filter so the user can land in the app and `⌘F`+`⌘V` to filter for
    /// Lyrebird entries.
    ///
    /// Why not deep-link with a URL scheme: Console.app registers no
    /// `CFBundleURLTypes` (verified on macOS 26.4 — the previously-shipped
    /// `x-apple-syslog:?subsystem=…` scheme was an invented one and silently
    /// failed). AppleScript-driving the search field would work but requires
    /// the user to grant accessibility permissions to Lyrebird, which is a
    /// heavyweight ask for a debug button. Clipboard + alert is two extra
    /// keystrokes for the user, no permissions, no failure modes.
    ///
    /// The clipboard payload is just `subsystem:org.lyrebird.desktop` —
    /// Console's search bar accepts that token directly and applies it as a
    /// scoped filter (versus typing the same string into a free-text search
    /// which matches as substring across all fields).
    private func openLogsInConsole() {
        let filter = "subsystem:org.lyrebird.desktop"
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
        let cmd = "log stream --predicate 'subsystem == \"org.lyrebird.desktop\"' --info --debug --style compact"
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

    /// Clears the artwork cache only — the same Nuke pipeline cache the
    /// Library pane evicts (`Artwork.pipeline.cache.removeAll()`), plus the
    /// pipeline's on-disk `DataCache` directory.
    ///
    /// It deliberately does **not** delete the caches root. Offline
    /// downloads live at `Caches/Downloads` (see `PreferencesDownloads`);
    /// nuking the whole caches tree would destroy them, contradicting the
    /// dialog's promise that the library isn't affected. Credentials
    /// (Keychain) and preferences (UserDefaults) live outside Caches and
    /// are untouched either way.
    ///
    /// The in-memory eviction and the artwork directory's URL are read on
    /// the MainActor (Nuke's `ImagePipeline` / `DataCache` are main-actor
    /// isolated in this module); the filesystem delete + verify runs off
    /// the main thread so the recursive walk doesn't block the UI, and the
    /// success / failure result is marshalled back to the MainActor.
    private func clearCaches() {
        guard !cachesClearInProgress else { return }
        cachesClearInProgress = true
        cachesClearError = nil

        // Memory cache eviction is cheap and main-actor isolated.
        Artwork.pipeline.cache.removeAll()

        // Resolve the on-disk artwork directory on main, then hand only that
        // URL (Sendable) to the background task — never the caches root.
        let artworkDir = (Artwork.pipeline.configuration.dataCache as? DataCache)?.path

        Task {
            // Do the recursive delete + recreate off the main thread so the
            // filesystem walk never blocks the UI.
            let result = await Task.detached(priority: .utility) {
                Self.clearArtworkCacheDirectory(at: artworkDir)
            }.value

            // Marshal the outcome back to the MainActor for the @State writes.
            await MainActor.run {
                cachesClearInProgress = false
                switch result {
                case .success:
                    cachesClearedDone = true
                    // Auto-reset the row's "Cleared" affordance so it doesn't
                    // stay stuck on the success copy forever.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        cachesClearedDone = false
                    }
                case .failure(let error):
                    cachesClearedDone = false
                    cachesClearError = error.localizedDescription
                }
            }
        }
    }

    /// Pure filesystem step: delete the artwork `DataCache` directory and
    /// recreate it empty, returning the outcome instead of swallowing it.
    ///
    /// Safety: refuses to operate on the caches root or on a `Downloads`
    /// directory, so a future config change can never turn this into the
    /// download-destroying recursive nuke this used to be. A `nil` URL
    /// (no on-disk cache configured) is a no-op success — the in-memory
    /// eviction in `clearCaches()` already did the meaningful work.
    ///
    /// `nonisolated static` so it carries no `self`/MainActor capture and
    /// can run on a background executor; unit-testable in isolation.
    nonisolated static func clearArtworkCacheDirectory(
        at directory: URL?
    ) -> Result<Void, Error> {
        guard let directory else { return .success(()) }

        guard isSafeArtworkCacheDirectory(directory) else {
            return .failure(CacheClearError.refusedUnsafePath(directory.path))
        }

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: directory.path) {
                try fm.removeItem(at: directory)
            }
            // Recreate so the next artwork write doesn't fail on a missing dir,
            // then verify it actually exists before reporting success.
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.fileExists(atPath: directory.path) else {
                return .failure(CacheClearError.recreateFailed(directory.path))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Guards against ever deleting the caches root itself or a downloads
    /// store. The artwork cache is always a named subdirectory (Nuke uses
    /// `com.lyrebird.macos.artwork`), so a target whose last path component
    /// is `Caches` or `Downloads` is rejected.
    nonisolated static func isSafeArtworkCacheDirectory(_ directory: URL) -> Bool {
        let last = directory.lastPathComponent
        if last == "Downloads" || last == "Caches" || last.isEmpty || last == "/" {
            return false
        }
        return true
    }

    /// Errors surfaced to the user when the artwork-cache clear can't
    /// complete, so a failed or partial clear is visible instead of being
    /// silently reported as success.
    enum CacheClearError: LocalizedError {
        case refusedUnsafePath(String)
        case recreateFailed(String)

        var errorDescription: String? {
            switch self {
            case .refusedUnsafePath(let path):
                return "The cache location looked unsafe to delete (\(path)), so nothing was removed."
            case .recreateFailed(let path):
                return "The cache was cleared but the folder couldn't be recreated at \(path)."
            }
        }
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
