import SwiftUI

/// Modal sheet shown when a server call returns 401 on a token that used to
/// be valid. Offers a single "Sign in" CTA that drops the stored token and
/// bounces the user back to `LoginView` with the server URL and username
/// prefilled (stored on `AppModel` from the last successful sign-in).
///
/// This is strictly a prompt — silent re-auth using a remembered password is
/// tracked separately in #440. See issue #303.
struct AuthExpiredSheet: View {
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.slash")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text("auth.session.expired.title")
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)

                Text("auth.session.expired.body")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onSignIn) {
                Text("auth.sign_in")
                    .font(Theme.font(14, weight: .bold))
                    .frame(width: 260, height: 40)
                    .foregroundStyle(Theme.bg)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("auth.sign_in.again.a11y")
        }
        .padding(32)
        .frame(width: 360)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

#Preview("Auth expired sheet") {
    AuthExpiredSheet(onSignIn: {})
        .preferredColorScheme(.dark)
}
