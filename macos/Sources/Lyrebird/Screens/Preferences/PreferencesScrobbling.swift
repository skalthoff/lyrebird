import SwiftUI

/// Scrobbling preferences pane (#46).
///
/// MVP target is **ListenBrainz**, the simplest token-based scrobbler: the user
/// pastes their token from <https://listenbrainz.org/profile/> and Lyrebird
/// submits a `playing_now` when a track starts plus a durable listen once it
/// passes the scrobble threshold (half the track, or four minutes).
///
/// Security: the token is a secret. It is written straight through to the Rust
/// core's settings table via `AppModel.connectScrobbler(token:)` and is **never**
/// stored in `UserDefaults`, never logged, and never included in the diagnostic
/// bundle. The pane only ever learns *whether* a token is configured
/// (`model.scrobbleConnected`), never its value — there is no FFI that returns
/// the token. The text field is cleared the moment it is saved.
///
/// Last.fm is shown as a clearly-disabled "Coming soon" section: it needs an
/// API key + shared-secret signing handshake and a web-auth session token,
/// which is follow-up work. The disabled section documents the intent without
/// pretending to function.
struct PreferencesScrobbling: View {
    @Environment(AppModel.self) private var model

    @AppStorage(ScrobblePreference.enabledKey) private var enabled: Bool = false

    /// Local editing buffer for the token. Never pre-filled from storage (the
    /// token can't be read back), so it starts empty and the user pastes a
    /// fresh token to (re)connect.
    @State private var tokenDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Scrobbling",
                footnote: "When on, Lyrebird reports each track you play to your scrobbling service. A track counts once you've listened to at least half of it, or four minutes — whichever comes first."
            ) {
                PreferenceRow(
                    label: "Enable scrobbling",
                    help: enabled
                        ? (model.scrobbleConnected
                            ? "On — plays are submitted to ListenBrainz."
                            : "On, but no ListenBrainz token is connected yet.")
                        : "Off — Lyrebird won't submit any plays."
                ) {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable scrobbling")
                }
            }

            listenBrainzSection

            lastFmSection

            Spacer(minLength: 0)
        }
    }

    // MARK: - ListenBrainz

    @ViewBuilder
    private var listenBrainzSection: some View {
        PreferenceSection(
            title: "ListenBrainz",
            footnote: "Paste your user token from listenbrainz.org/profile. The token is stored securely on this Mac and is never shown again or included in diagnostics."
        ) {
            if model.scrobbleConnected {
                connectedRow
            } else {
                connectRow
            }
        }
    }

    /// Shown when a token is already stored: confirmation + a Disconnect button.
    private var connectedRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferenceRow(
                label: "Account",
                help: "A ListenBrainz token is connected."
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Connected")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("ListenBrainz connected")
            }

            Divider()
                .background(Theme.border)
                .padding(.vertical, 10)

            PreferenceRow(
                label: "Disconnect",
                help: "Removes the stored token. You can reconnect at any time."
            ) {
                Button("Disconnect") {
                    model.disconnectScrobbler()
                    tokenDraft = ""
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Disconnect ListenBrainz")
            }
        }
    }

    /// Shown when no token is stored: a secure field + Connect button.
    private var connectRow: some View {
        PreferenceRow(
            label: "User token",
            help: "Find it on your ListenBrainz profile page."
        ) {
            HStack(spacing: 8) {
                SecureField("Paste token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("ListenBrainz user token")
                Button("Connect") {
                    model.connectScrobbler(token: tokenDraft)
                    // Clear the buffer immediately — the secret is now in the
                    // core and must not linger in view state.
                    tokenDraft = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Connect ListenBrainz")
            }
        }
    }

    // MARK: - Last.fm (not yet available)

    /// Last.fm requires an API key + shared secret and a signed web-auth session
    /// handshake (`auth.getSession`), none of which is implemented yet. Render a
    /// clearly-disabled section rather than a working control so the roadmap is
    /// visible without misleading the user.
    @ViewBuilder
    private var lastFmSection: some View {
        PreferenceSection(
            title: "Last.fm",
            footnote: "Last.fm scrobbling is planned. It needs an API key and a sign-in handshake, which isn't available in this build yet."
        ) {
            PreferenceRow(
                label: "Last.fm",
                help: "Coming soon."
            ) {
                Button("Connect") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityLabel("Connect Last.fm (coming soon)")
            }
            .opacity(0.55)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scrobbling")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Report the tracks you play to ListenBrainz.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

#Preview {
    // Real rendering requires an `AppModel` in the environment; the Settings
    // scene in `LyrebirdApp` injects one. Kept as documentation for where the
    // view lives — see `PreferencesNotifications` for the same note.
    PreferencesScrobbling()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
