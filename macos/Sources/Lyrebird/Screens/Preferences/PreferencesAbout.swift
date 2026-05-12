import AppKit
import SwiftUI

/// About pane.
///
/// A one-glance summary of the app: title, version, copyright, and a link to
/// the GitHub repo. Nothing here is interactive beyond the GitHub button —
/// the values come from the app bundle so they stay accurate release-to-
/// release without anyone having to remember to bump a string constant.
///
/// This is distinct from the system "About Jellify" sheet (the one that
/// opens from the app-menu item); that sheet is owned by AppKit and shows
/// the same version info in Apple's standard layout. The Preferences About
/// pane exists so users who expect the info inside Settings (macOS System
/// Settings has one, most third-party apps do too) don't have to go hunting
/// through the app menu.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 About bullet.
struct PreferencesAbout: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            HStack(alignment: .top, spacing: 20) {
                appIcon
                VStack(alignment: .leading, spacing: 10) {
                    Text("Jellify")
                        .font(Theme.font(24, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(versionText)")
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                            .textSelection(.enabled)
                        Text("Build \(buildText)")
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }

                    Text(copyrightText)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink2)

                    Text("A native macOS music player for Jellyfin.")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )

            actions

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Version, copyright, and project links.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// A 64pt square rendered in the accent color with a stylised "J" —
    /// matches the brand mark used on the login screen. Avoids pulling in
    /// an asset dependency just for this pane.
    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Theme.primary, Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("J")
                .font(Theme.font(36, weight: .black, italic: true))
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { openGitHub() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on GitHub")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View on GitHub")
            .accessibilityHint("Opens the Jellify repository in your browser.")

            Button { openIssues() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.bubble")
                    Text("Report an Issue")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Report an issue")
            .accessibilityHint("Opens the Jellify issue tracker in your browser.")
        }
    }

    // MARK: - Bundle values

    /// Marketing version (`CFBundleShortVersionString`). Falls back to a
    /// dev-only placeholder when the bundle key is missing — e.g. when
    /// running from Xcode against an unconfigured Info.plist.
    private var versionText: String {
        bundleString(for: "CFBundleShortVersionString") ?? "0.0.0 (dev)"
    }

    /// Build number (`CFBundleVersion`). Similar fallback reasoning.
    private var buildText: String {
        bundleString(for: "CFBundleVersion") ?? "—"
    }

    /// Copyright string (`NSHumanReadableCopyright`). When missing, render a
    /// generic attribution for Skyler Althoff + Jellify contributors rather
    /// than an empty row.
    private var copyrightText: String {
        bundleString(for: "NSHumanReadableCopyright")
            ?? "Copyright © Skyler Althoff and Jellify contributors."
    }

    private func bundleString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Actions

    private func openGitHub() {
        guard let url = URL(string: "https://github.com/skalthoff/jellify-desktop") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openIssues() {
        guard let url = URL(string: "https://github.com/skalthoff/jellify-desktop/issues") else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    PreferencesAbout()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
