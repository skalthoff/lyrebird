import SwiftUI

/// Notifications preferences pane.
///
/// Three toggles, all `@AppStorage`-backed so they persist across launches
/// and are readable by `NotificationManager` / `LyrebirdApp` through the
/// shared `NotificationPreference` keys:
///
/// - **Show notification on track change** — posts a "Now Playing"
///   `UNUserNotificationCenter` banner whenever the track changes. Enabling it
///   triggers the system authorization prompt (once per install).
/// - **Play sound** — whether the track-change notification plays the default
///   sound. Disabled when track-change notifications are off.
/// - **Show in menu bar while playing** — surfaces the menu-bar extra
///   transiently while audio is playing, complementing the always-on toggle in
///   General. `LyrebirdApp`'s `MenuBarExtra(isInserted:)` binding observes the
///   same key and the live playback state, so flipping it takes effect on the
///   spot in either direction — no controller call needed (#984).
///
/// Spec: `research/06-screen-specs.md` — Settings ▸ Notifications.
struct PreferencesNotifications: View {
    @AppStorage(NotificationPreference.trackChangeKey)
    private var trackChange: Bool = false
    @AppStorage(NotificationPreference.soundKey)
    private var sound: Bool = false
    @AppStorage(NotificationPreference.showInMenuBarWhilePlayingKey)
    private var showInMenuBarWhilePlaying: Bool = false

    /// Binding that requests notification authorization the moment the user
    /// opts in, so the system prompt is tied to the explicit toggle rather
    /// than appearing on cold launch.
    private var trackChangeBinding: Binding<Bool> {
        Binding(
            get: { trackChange },
            set: { newValue in
                trackChange = newValue
                if newValue {
                    NotificationManager.shared.requestAuthorizationIfNeeded()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Track Changes",
                footnote: "Posts a Now Playing banner each time a new track starts. macOS will ask for notification permission the first time you enable this."
            ) {
                PreferenceRow(
                    label: "Show notification on track change",
                    help: trackChange
                        ? "On — a banner appears whenever the track changes."
                        : "Off — Lyrebird won't post track-change notifications."
                ) {
                    Toggle("", isOn: trackChangeBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show notification on track change")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Play sound",
                    help: sound
                        ? "On — the track-change notification plays the default sound."
                        : "Off — track-change notifications are silent."
                ) {
                    Toggle("", isOn: $sound)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!trackChange)
                        .accessibilityLabel("Play notification sound")
                }
            }

            PreferenceSection(
                title: "Menu Bar",
                footnote: "Shows the menu-bar icon only while audio is playing. To keep it visible at all times, use Show in menu bar in General."
            ) {
                PreferenceRow(
                    label: "Show in menu bar while playing",
                    help: showInMenuBarWhilePlaying
                        ? "On — the menu-bar icon appears while a track is playing."
                        : "Off — the menu-bar icon follows the General setting only."
                ) {
                    Toggle("", isOn: $showInMenuBarWhilePlaying)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show in menu bar while playing")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Track-change banners, sound, and menu-bar presence.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

#Preview {
    PreferencesNotifications()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
