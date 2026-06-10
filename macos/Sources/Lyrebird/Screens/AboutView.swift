import AppKit
import SwiftUI

/// Dedicated **About Lyrebird** window (#25).
///
/// Summoned from the app menu's standard "About Lyrebird" item, which
/// `LyrebirdApp` rebinds via `CommandGroup(replacing: .appInfo)` so it opens
/// this branded panel instead of AppKit's stock about box. The window shows the
/// app mark, name, version + build, the connected server (host only), a short
/// copyright line, and an acknowledgements list.
///
/// All textual payload comes from ``AboutInfo`` — the same source the
/// Preferences → About pane reads — so the menu's About box and the Settings
/// pane can never advertise different versions or credits. The connected-server
/// row reads the live `serverURL` off `AppModel` and routes it through
/// `AboutInfo.connectedServerHost` (host only, no path / token), then hides
/// itself entirely when signed out.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    /// Resolved once per appearance — these are bundle reads that never change
    /// for the lifetime of the process, so there's no reason to recompute them
    /// on every body pass.
    private let version = AboutInfo.version()
    private let build = AboutInfo.build()
    private let copyright = AboutInfo.copyright()

    /// Connected server host (host only) or `nil` when signed out, in which
    /// case the row is omitted.
    private var serverHost: String? {
        AboutInfo.connectedServerHost(from: model.serverURL)
    }

    var body: some View {
        VStack(spacing: 20) {
            appIcon

            VStack(spacing: 6) {
                Text(AboutInfo.appName)
                    .font(Theme.font(26, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)

                Text(AboutInfo.tagline)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
            }

            versionBlock

            if let serverHost {
                serverRow(host: serverHost)
            }

            Divider()
                .overlay(Theme.border)
                .padding(.horizontal, 24)

            creditsBlock

            Text(copyright)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
    }

    // MARK: - Pieces

    /// The brand mark — a rounded-square accent gradient with a stylised "J",
    /// matching the Preferences About pane and the login screen. Rendered in
    /// code so the window needs no asset-catalog dependency.
    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [Theme.primary, Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("J")
                .font(Theme.font(46, weight: .black, italic: true))
                .foregroundStyle(.white)
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    private var versionBlock: some View {
        VStack(spacing: 2) {
            Text("Version \(version)")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .textSelection(.enabled)
            Text("Build \(build)")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Version \(version), build \(build)")
    }

    private func serverRow(host: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink3)
            Text(host)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected to \(host)")
    }

    private var creditsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Acknowledgements")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(AboutInfo.credits) { credit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(credit.name)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(credit.role)
                        .font(Theme.font(11, weight: .regular))
                        .foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(credit.name). \(credit.role)")
            }
        }
    }

    // MARK: - Scene identity

    /// Scene identity for the dedicated About `Window`. Centralised so the
    /// scene declaration in `LyrebirdApp` and the `openWindow(id:)` call site
    /// in the `.appInfo` command agree on the id, matching the
    /// `AppShortcuts.windowID` / `MiniPlayerScene.id` convention.
    static let windowID = "about-lyrebird"
}

#Preview {
    // Real rendering requires an `AppModel` in the environment; the dedicated
    // About `Window` in `LyrebirdApp` injects one. Previews without a model
    // will crash on `@Environment(AppModel.self)` — this preview is kept as
    // documentation for where the view lives, matching `PreferencesServer`.
    AboutView()
        .preferredColorScheme(.dark)
}
