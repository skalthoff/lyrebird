import SwiftUI

/// General preferences pane.
///
/// Launch-at-login, menu-bar presence, and language.
///
/// - **Language**: only English ships; the picker is present so the setting
///   is visible and the user can see i18n is on the roadmap. Real wiring is
///   tracked in `TODO(i18n-#345)`.
/// - **Auto-start on login**: wired to `SMAppService.mainApp` via
///   `LaunchAtLogin`. The stored `@AppStorage` value shadows the system
///   registration so the toggle reflects the true state on every launch.
/// - **Show in menu bar**: wired to `MenuBarController.shared`. The
///   `NSStatusItem` is created on enable and released on disable.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 top-level General bullet.
struct PreferencesGeneral: View {
    @AppStorage("general.language") private var languageRaw: String = AppLanguage.system.rawValue
    @AppStorage("general.autoStartOnLogin") private var autoStartOnLogin: Bool = false
    @AppStorage("general.showInMenuBar") private var showInMenuBar: Bool = false

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

    /// Binding that syncs `@AppStorage` with `MenuBarController` whenever
    /// the value changes.
    private var showInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { showInMenuBar },
            set: { newValue in
                showInMenuBar = newValue
                MenuBarController.shared.setVisible(newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

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
                    Toggle("", isOn: showInMenuBarBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show in menu bar")
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            // Reconcile stored value with true SMAppService state on every
            // pane open so the toggle is never stale (e.g. if the user
            // toggled the login item from System Settings).
            autoStartOnLogin = LaunchAtLogin.isEnabled
            // Re-apply the menu-bar state in case the controller lost its
            // item during a Settings window close/reopen cycle.
            MenuBarController.shared.setVisible(showInMenuBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Language, startup, and menu-bar presence.")
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
    PreferencesGeneral()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
