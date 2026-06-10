import SwiftUI

/// General preferences pane.
///
/// Launch-at-login, menu-bar presence, language, and update channel.
///
/// - **Language**: in-app localization isn't wired yet — nothing reads
///   `general.language` back to re-render the UI, and `AppLanguage` only offers
///   System / English (both no-ops). The picker is therefore gated behind
///   `AppModel.supportsLanguageSelection` so it isn't presented as a working
///   setting while inert; it reappears once the strings catalog ships real
///   locales and a runtime override is wired.
/// - **Auto-start on login**: wired to `SMAppService.mainApp` via
///   `LaunchAtLogin`. The stored `@AppStorage` value shadows the system
///   registration so the toggle reflects the true state on every launch.
/// - **Show in menu bar**: a plain `@AppStorage` toggle. `LyrebirdApp`'s
///   `MenuBarExtra(isInserted:)` binding observes the same key, so flipping it
///   here inserts/removes the menu-bar extra reactively, and the persisted
///   value is re-applied on every launch by construction — no controller or
///   launch-time re-apply needed.
/// - **Receive beta updates**: stored at `BetaChannelPreference.betaOptInKey`.
///   Read by `UpdaterDelegate.allowedChannels(for:)` on every Sparkle check.
///   No relaunch required — Sparkle re-queries the delegate for each check.
///   Defaults to `false` (stable-only). See `BetaChannelPreference`.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 top-level General bullet.
struct PreferencesGeneral: View {
    /// Stable `@AppStorage` key for the persistent "Show in menu bar" toggle.
    /// Shared with `LyrebirdApp`, whose `MenuBarExtra(isInserted:)` binding
    /// reads it to resolve menu-bar presence (see `MenuBarVisibility`).
    static let showInMenuBarKey = "general.showInMenuBar"

    @Environment(AppModel.self) private var model

    @AppStorage("general.language") private var languageRaw: String = AppLanguage.system.rawValue
    @AppStorage("general.autoStartOnLogin") private var autoStartOnLogin: Bool = false
    @AppStorage(PreferencesGeneral.showInMenuBarKey) private var showInMenuBar: Bool = false
    @AppStorage(BetaChannelPreference.betaOptInKey) private var betaOptIn: Bool = false

    private var language: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    /// Binding that syncs `@AppStorage` with the real `SMAppService`
    /// registration whenever the value changes.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { autoStartOnLogin },
            set: { newValue in
                autoStartOnLogin = newValue
                if newValue {
                    LaunchAtLogin.enable()
                } else {
                    LaunchAtLogin.disable()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            // Language picker is gated behind `supportsLanguageSelection`
            // (#345). The control is inert today — nothing consumes
            // `general.language` — so we hide it rather than present a dead
            // setting. It returns once localization is wired.
            if model.supportsLanguageSelection {
                PreferenceSection(
                    title: "Language",
                    footnote: "Only English ships today — additional languages will appear as translations land."
                ) {
                    PreferenceRow(
                        label: "Language",
                        help: language.wrappedValue.subtitle
                    ) {
                        Picker("", selection: language) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .accessibilityLabel("Application language")
                    }
                }
            }

            PreferenceSection(
                title: "Startup",
                footnote: "Auto-start launches Lyrebird in the background when you log in."
            ) {
                PreferenceRow(
                    label: "Open at login",
                    help: autoStartOnLogin
                        ? "On — Lyrebird will launch in the background when you sign in."
                        : "Off — Lyrebird only opens when you launch it manually."
                ) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Launch Lyrebird at login")
                }
            }

            PreferenceSection(
                title: "Menu Bar",
                footnote: "Keeps a transport icon in the macOS menu bar for quick access."
            ) {
                PreferenceRow(
                    label: "Show in menu bar",
                    help: showInMenuBar
                        ? "On — a compact icon stays in the menu bar."
                        : "Off — Lyrebird lives only in the Dock."
                ) {
                    Toggle("", isOn: $showInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show in menu bar")
                }
            }

            PreferenceSection(
                title: "Updates",
                footnote: "Beta releases may be less stable than stable releases. The next scheduled check will use the new setting — no relaunch required."
            ) {
                PreferenceRow(
                    label: "Receive beta updates",
                    help: betaOptIn
                        ? "On — beta and stable releases are offered; the newest version wins."
                        : "Off — only stable releases are offered."
                ) {
                    Toggle("", isOn: $betaOptIn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Receive beta updates")
                        .accessibilityHint("When on, pre-release versions appear alongside stable updates.")
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            // Reconcile stored value with true SMAppService state on every
            // pane open so the toggle is never stale (e.g. if the user
            // toggled the login item from System Settings). Menu-bar presence
            // needs no equivalent reconcile: `MenuBarExtra(isInserted:)`
            // derives it from the stored key reactively (#984).
            autoStartOnLogin = LaunchAtLogin.isEnabled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text(model.supportsLanguageSelection
                ? "Language, startup, menu-bar presence, and updates."
                : "Startup, menu-bar presence, and updates.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

/// Application language for the UI. Only `system` (effectively English today)
/// and `english` are present in the v1 cut — additional cases land alongside
/// the strings catalog in `TODO(i18n-#345)`. Raw values are stable user-
/// defaults strings so on-disk preferences survive future additions.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Follow macOS language settings."
        case .english: return "Use English regardless of system language."
        }
    }
}

#Preview {
    // Real rendering requires an `AppModel` in the environment; the Settings
    // scene in `LyrebirdApp` injects one. Previews without a model will crash
    // on `@Environment(AppModel.self)` — this preview is kept as documentation
    // for where the view lives.
    PreferencesGeneral()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
