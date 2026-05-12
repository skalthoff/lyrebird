import AppKit
import NukeUI
import SwiftUI

/// Server preferences pane.
///
/// Shows the connected server — URL, product name, version — and the signed-
/// in user (avatar + display name). Three actions: **Switch Server** (drops
/// server URL + username so the login form is blank), **Change User** (keeps
/// the server URL but clears the username so the login form skips straight
/// to the credentials step), and **Sign Out** (keeps both so the user only
/// re-enters the password).
///
/// Server info is pulled from `model.session` (the record handed back by
/// `core.login` / `core.resumeSession`). When those fields are `nil` — e.g.
/// the Jellyfin server didn't return a `version` — the UI renders an em-dash
/// rather than an empty string so the row still has a visible value.
///
/// This pane replaces the standalone "Account" entry from the pre-#114 layout
/// by incorporating the same sign-out / change-server flows. The old
/// `PreferencesAccount` remains in the module as a smaller subset view any
/// non-preferences caller can reuse, but the sidebar no longer routes to it.
///
/// Issue: #115.
struct PreferencesServer: View {
    @Environment(AppModel.self) private var model

    @State private var confirmSwitchServer: Bool = false
    @State private var confirmChangeUser: Bool = false
    @State private var confirmSignOut: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Connected Server",
                footnote: "Server info is reported by the connected Jellyfin instance. A dash means the server didn't include that field in its public info."
            ) {
                PreferenceRow(label: "URL") {
                    valueText(serverURLText)
                        .textSelection(.enabled)
                        .accessibilityLabel("Server URL: \(serverURLText)")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(label: "Name") {
                    valueText(serverNameText)
                        .accessibilityLabel("Server name: \(serverNameText)")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(label: "Version") {
                    valueText(serverVersionText)
                        .monospacedDigit()
                        .accessibilityLabel("Server version: \(serverVersionText)")
                }
            }

            PreferenceSection(
                title: "Signed In As",
                footnote: "Your avatar comes from the Jellyfin server. If you haven't uploaded one, the default monogram shows your initial."
            ) {
                HStack(spacing: 14) {
                    userAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(userDisplayName)
                            .font(Theme.font(15, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text(userSubtitle)
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed in as \(userDisplayName) on \(serverURLText)")
            }

            actions

            Spacer(minLength: 0)
        }
        .alert("Switch to a different server?", isPresented: $confirmSwitchServer) {
            Button("Cancel", role: .cancel) {}
            Button("Switch Server", role: .destructive) { switchServer() }
        } message: {
            Text("You'll be signed out and returned to the login screen so you can connect to a different Jellyfin server.")
        }
        .alert("Sign in as a different user?", isPresented: $confirmChangeUser) {
            Button("Cancel", role: .cancel) {}
            Button("Change User", role: .destructive) { changeUser() }
        } message: {
            Text("You'll be signed out of \(displayServer). The server URL stays remembered so you can sign in as someone else with just their credentials.")
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { signOut() }
        } message: {
            Text("You'll be signed out of \(displayServer). Your server URL and username are remembered so you can sign back in with just your password.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("The Jellyfin server you're connected to and the user you're signed in as.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Circular avatar rendered at 48pt. Uses the Jellyfin `Users/{id}/Images/
    /// Primary` endpoint via `AppModel.imageURL` when a primary image tag is
    /// set on the session user; otherwise falls back to a monogram sitting on
    /// `Theme.surface2`. Downloaded through Nuke's shared pipeline so it
    /// benefits from the same cache + coalescing as the rest of the app's
    /// artwork.
    @ViewBuilder
    private var userAvatar: some View {
        let size: CGFloat = 48
        ZStack {
            Circle()
                .fill(Theme.surface2)
                .overlay(
                    Circle().stroke(Theme.border, lineWidth: 1)
                )
            if let url = userAvatarURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        monogram
                    }
                }
                .clipShape(Circle())
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
    }

    private var monogram: some View {
        Text(monogramCharacter)
            .font(Theme.font(20, weight: .heavy))
            .foregroundStyle(Theme.ink2)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            secondaryButton(label: "Switch Server") { confirmSwitchServer = true }
                .accessibilityHint("Signs out and clears the remembered server so you can connect to a different Jellyfin instance.")
            secondaryButton(label: "Change User") { confirmChangeUser = true }
                .accessibilityHint("Signs out of this server while keeping the URL so you can sign in as a different user.")
            primaryButton(label: "Sign Out") { confirmSignOut = true }
                .accessibilityHint("Signs out of the current server. URL and username are remembered so sign-in only asks for a password.")
        }
    }

    private func secondaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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
        .accessibilityLabel(label)
    }

    private func primaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Display values

    private var serverURLText: String {
        model.serverURL.isEmpty ? "—" : model.serverURL
    }

    private var serverNameText: String {
        if let name = model.session?.server.name, !name.isEmpty {
            return name
        }
        return "—"
    }

    private var serverVersionText: String {
        if let version = model.session?.server.version, !version.isEmpty {
            return version
        }
        return "—"
    }

    private var userDisplayName: String {
        let fromSession = model.session?.user.name ?? ""
        if !fromSession.isEmpty { return fromSession }
        return model.username.isEmpty ? "—" : model.username
    }

    /// Shown under the user's name. Keep it short and factual — which server
    /// this user is signed in on.
    private var userSubtitle: String {
        if serverNameText != "—" {
            return serverNameText
        }
        return serverURLText
    }

    private var monogramCharacter: String {
        let name = userDisplayName
        guard let first = name.first, first.isLetter else { return "?" }
        return String(first).uppercased()
    }

    private var userAvatarURL: URL? {
        guard
            let user = model.session?.user,
            let tag = user.primaryImageTag, !tag.isEmpty,
            !model.serverURL.isEmpty,
            var components = URLComponents(string: model.serverURL)
        else { return nil }
        // The core's `imageUrl` only knows about `/Items/{id}/Images/Primary`;
        // user avatars live at `/Users/{id}/Images/Primary`. Build the URL
        // manually so we don't need a new FFI just for this one surface.
        // TODO(core-#568): promote this to `core.userImageUrl(userId:tag:)`
        // so the URL gets the same signing + device-id plumbing as item art.
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(base)/Users/\(user.id)/Images/Primary"
        components.queryItems = [
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "maxWidth", value: "120"),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return components.url
    }

    /// Server string used in confirmation dialog bodies. Prefer the server's
    /// product name so "this server" reads naturally, falling back to the URL
    /// when name isn't known, and finally to "this server" if both are empty.
    private var displayServer: String {
        if serverNameText != "—" { return serverNameText }
        if !model.serverURL.isEmpty { return model.serverURL }
        return "this server"
    }

    // MARK: - Helper views

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(Theme.font(14, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    // MARK: - Actions

    /// Drop the stored token + session but keep the remembered server URL
    /// and username on disk so the login form prefills on return — user only
    /// re-enters the password.
    private func signOut() {
        model.forgetToken()
        model.session = nil
        model.authExpired = false
        closePreferencesWindow()
    }

    /// Sign out and also clear the remembered username so the login form
    /// keeps the server URL but lands on the credentials step empty. The user
    /// can then sign in as a different user against the same Jellyfin
    /// instance without retyping the URL.
    private func changeUser() {
        model.forgetToken()
        model.session = nil
        model.username = ""
        model.authExpired = false
        closePreferencesWindow()
    }

    /// Sign out and also clear the server URL + username so the login form
    /// comes up blank, ready for a different Jellyfin instance.
    private func switchServer() {
        model.forgetToken()
        model.session = nil
        model.serverURL = ""
        model.username = ""
        model.authExpired = false
        closePreferencesWindow()
    }

    /// Close the Preferences window after signing out — otherwise it sits on
    /// top of LoginView, which is jarring. Running on the next runloop tick
    /// gives SwiftUI a chance to commit the session=nil state change first so
    /// the user sees Login under the (closing) Preferences rather than a
    /// brief flash of MainShell.
    private func closePreferencesWindow() {
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.performClose(nil)
        }
    }
}

#Preview {
    // Real rendering requires an `AppModel` in the environment; the Settings
    // scene in `LyrebirdApp` injects one. Previews without a model will crash
    // on `@Environment(AppModel.self)` — this preview is kept as documentation
    // for where the view lives.
    PreferencesServer()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
}
