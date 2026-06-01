import SwiftUI

/// Notifications preferences pane.
///
/// Three toggles, all `@AppStorage`-backed so they persist across launches
/// and are readable by `NotificationManager` / `MenuBarController` through the
/// shared `NotificationPreference` keys:
///
/// - **Show notification on track change** — posts a "Now Playing"
///   `UNUserNotificationCenter` banner whenever the track changes. Enabling it
///   triggers the system authorization prompt (once per install).
/// - **Play sound** — whether the track-change notification plays the default
///   sound. Disabled when track-change notifications are off.
/// - **Show in menu bar while playing** — surfaces the menu-bar icon
///   transiently while audio is playing, complementing the always-on toggle in
///   General. `AppModel` drives `MenuBarController.setVisibleWhilePlaying(_:)`
///   off the playback state.
///
/// Spec: `research/06-screen-specs.md` — Settings ▸ Notifications.
struct PreferencesNotifications: View {
    @Environment(AppModel.self) private var model

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

    /// Binding that applies the "Show in menu bar while playing" preference
    /// immediately, rather than waiting for the next playback state transition.
    ///
    /// Without this, flipping the toggle on while a track is already playing
    /// did nothing until the user paused/resumed — the AppModel poll loop only
    /// drives `setVisibleWhilePlaying(_:)` on a `state` change. Resolving the
    /// current playback state here makes the toggle take effect on the spot:
    /// enabling it while playing shows the icon now; disabling it removes the
    /// transient icon now (unless the persistent General toggle is keeping it).
    private var showInMenuBarWhilePlayingBinding: Binding<Bool> {
        Binding(
            get: { showInMenuBarWhilePlaying },
            set: { newValue in
                showInMenuBarWhilePlaying = newValue
                // When turned on, reflect the live playback state immediately;
                // when turned off, drop the transient icon (passing `false`
                // so it only stays if the persistent toggle pins it).
                let playing = newValue && model.status.state == .playing
                MenuBarController.shared.setVisibleWhilePlaying(playing)
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
                    Toggle("", isOn: showInMenuBarWhilePlayingBinding)
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
    // Real rendering requires an `AppModel` in the environment; the Settings
    // scene in `LyrebirdApp` injects one. Previews without a model will crash
    // on `@Environment(AppModel.self)` — this preview is kept as documentation
    // for where the view lives.
    PreferencesNotifications()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
