import SwiftUI

/// Experiments (feature-flags) preferences pane. Hidden from the sidebar
/// unless `FeatureFlags.shared.debugPanelEnabled` is true in `flags.json`.
///
/// Shows toggles for each flag defined in `FeatureFlags`. Changes take effect
/// immediately in memory and are also written back to
/// `~/Library/Application Support/Lyrebird/flags.json` so they survive
/// relaunch.
///
/// The pane intentionally avoids exposing a "set from UI and hide the file"
/// story — power-user ergonomics are deliberate. This is NOT a general-
/// audience settings pane; it is surfaced only when the user has already
/// touched the config file (because they set `debug_panel_enabled: true`).
///
/// Closes #451 (Feature flags — static file + in-app toggles).
struct PreferencesExperiments: View {

    // MARK: - State

    @State private var flags = FeatureFlags.shared

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Playback",
                footnote: "These knobs control experimental audio-engine behaviour. Changes take effect on the next track unless otherwise noted."
            ) {
                flagToggle(
                    label: "Gapless playback",
                    help: flags.gaplessPlayback
                        ? "On — tracks play without silence between them."
                        : "Off — each track ends cleanly before the next begins.",
                    accessibilityLabel: "Gapless playback",
                    value: flagBinding(get: { $0.gaplessPlayback }, set: { $0.gaplessPlayback = $1 })
                )

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Crossfade",
                    help: flags.crossfadeMs == 0
                        ? "Off — no overlap between tracks."
                        : "Overlap of \(flags.crossfadeMs) ms (engine support coming soon)."
                ) {
                    // Integer stepper: 0 / 500 / 1000 / … / 12 000 ms in steps of 500.
                    Stepper(
                        value: Binding(
                            get: { flags.crossfadeMs },
                            set: { newValue in
                                flags.crossfadeMs = newValue
                                persistFlags()
                            }
                        ),
                        in: 0 ... 12_000,
                        step: 500
                    ) {
                        Text(flags.crossfadeMs == 0 ? "Off" : "\(flags.crossfadeMs) ms")
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    .accessibilityLabel("Crossfade duration")
                }
            }

            PreferenceSection(
                title: "Library",
                footnote: "Library sync controls affect how Lyrebird refreshes your music catalogue from the server."
            ) {
                flagToggle(
                    label: "Delta sync",
                    help: flags.libraryDeltaSync
                        ? "On — only fetch items changed since the last sync."
                        : "Off — full catalogue reload on each launch.",
                    accessibilityLabel: "Library delta sync",
                    value: flagBinding(get: { $0.libraryDeltaSync }, set: { $0.libraryDeltaSync = $1 })
                )
            }

            PreferenceSection(
                title: "Debug",
                footnote: "Controls the visibility of this Experiments pane. Set to false in flags.json and relaunch to hide it again."
            ) {
                flagToggle(
                    label: "Debug panel",
                    help: flags.debugPanelEnabled
                        ? "On — this pane is visible in Preferences."
                        : "Off — this pane is hidden on the next relaunch.",
                    accessibilityLabel: "Debug panel enabled",
                    value: flagBinding(get: { $0.debugPanelEnabled }, set: { $0.debugPanelEnabled = $1 })
                )
            }

            locationRow

            Spacer(minLength: 0)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Experiments")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Feature flags loaded from flags.json. Changes persist to disk immediately.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - File location row

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Config file".uppercased())
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.2)

            HStack(spacing: 12) {
                Text(flagsFilePath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    revealFlagsFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text("Show in Finder")
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
                .accessibilityLabel("Show flags.json in Finder")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )

            Text("Edit this file to change flags. Send SIGUSR1 (kill -USR1 \(ProcessInfo.processInfo.processIdentifier)) to reload without relaunch.")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    /// Resolved path for the flags file, used in UI display only.
    private var flagsFilePath: String {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return "~/Library/Application Support/Lyrebird/flags.json"
        }
        return support.appendingPathComponent("Lyrebird/flags.json").path
    }

    /// Build a Binding for a flag property. Updates the in-memory flag and
    /// writes the full flags file to disk so changes survive relaunch.
    private func flagBinding<T>(
        get getter: @escaping (FeatureFlags) -> T,
        set setter: @escaping (inout FeatureFlags, T) -> Void
    ) -> Binding<T> {
        Binding(
            get: { getter(flags) },
            set: { newValue in
                // The FeatureFlags class is @Observable; mutate via a local
                // copy of the reference so the binding remains Sendable-clean.
                setter(&flags, newValue)
                persistFlags()
            }
        )
    }

    /// Shared toggle control with consistent styling.
    @ViewBuilder
    private func flagToggle(
        label: String,
        help: String,
        accessibilityLabel: String,
        value: Binding<Bool>
    ) -> some View {
        PreferenceRow(label: label, help: help) {
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// Persist the current in-memory flags to `flags.json`. Creates the
    /// Lyrebird Application Support directory if it doesn't exist yet. Errors
    /// are logged but do not surface to the user — the UI already reflects the
    /// in-memory state, and a disk-write failure is a non-critical edge case.
    private func persistFlags() {
        let dict: [String: Any] = [
            "debug_panel_enabled": flags.debugPanelEnabled,
            "gapless_playback": flags.gaplessPlayback,
            "crossfade_ms": flags.crossfadeMs,
            "library_delta_sync": flags.libraryDeltaSync,
        ]

        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let dir = support.appendingPathComponent("Lyrebird")
        let url = dir.appendingPathComponent("flags.json")

        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("flags.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open Finder at the flags file; creates the directory + an empty-schema
    /// file first so Finder has something to reveal.
    private func revealFlagsFile() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let dir = support.appendingPathComponent("Lyrebird")
        let url = dir.appendingPathComponent("flags.json")

        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            // Create a template file if one doesn't exist yet so Finder can
            // reveal it rather than just opening the parent folder.
            if !FileManager.default.fileExists(atPath: url.path) {
                let template: [String: Any] = [
                    "crossfade_ms": 0,
                    "debug_panel_enabled": true,
                    "gapless_playback": true,
                    "library_delta_sync": true,
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: template,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: url, options: .atomic)
                // Reload so the app immediately reflects the written values.
                FeatureFlags.shared.loadFromDisk()
            }
        } catch {
            Log.app.error("flags.json template write failed: \(error.localizedDescription, privacy: .public)")
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
