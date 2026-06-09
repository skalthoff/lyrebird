import SwiftUI
@preconcurrency import LyrebirdCore

/// Full-window login surface for the macOS app.
///
/// This is the view the user lands on when they've gone through onboarding
/// once (so `OnboardingView` is skipped) but are currently signed out —
/// either because they logged out, because `forgetToken` fired from the
/// auth-expired sheet (#303), or because the keyring lost its token.
///
/// Design (#200):
/// - Full-window `Theme.bg` background, no sidebar, no player bar.
/// - Centered 420pt-wide column with the brand lockup top-anchored.
/// - `_jellyfin._tcp` Bonjour discovery surfaces a chip row above the URL
///   field when at least one server is visible on the LAN (#111).
/// - 400ms debounced probe against `core.probeServer` shows "Jellyfin vX.Y.Z"
///   on success or "Couldn't reach server" on failure (#201).
/// - 401 on submit shakes the password field + shows "Wrong username or
///   password" (#203). Network offline shows a top banner. Repeated
///   unreachable failures swap the error message for a "Last connected …"
///   hint.
struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var url: String = ""
    @State private var password: String = ""
    // Username is read from / written through `AppModel.username` (which is
    // `@Observable`) so the typed value is captured into model state on
    // every keystroke and survives any view re-render — including the one
    // triggered by `model.errorMessage` flipping on a failed sign-in. A
    // local `@State` mirror would render the placeholder "you" again when
    // SwiftUI re-evaluated the form after auth fail (#791).

    @State private var discovery = ServerDiscovery()
    @State private var probe = ServerProbe()

    /// Per-submit count that drives the password-field shake on 401. Each
    /// failed attempt increments the value; the field observes
    /// `.animation(value:)` on it so the animation re-runs every time.
    @State private var shakeAttempts: Int = 0

    /// When `true`, we've seen the server reachability dip below threshold
    /// during this app session. Flip the "no such server" language for the
    /// "Last connected {date}. Trying offline mode." copy on subsequent
    /// failures (#203).
    @State private var hasSeenRepeatedUnreachable: Bool = false

    /// Presents the Quick Connect pairing sheet (#202).
    @State private var showQuickConnect: Bool = false

    /// Presents the device-name editing popover anchored on the gear (#202).
    @State private var showDeviceName: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, username, password
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            // Invisible drag handle spanning the full title-bar area so
            // users can drag the window by the chrome — the rewrite spec
            // (#200) keeps the standard traffic lights on a draggable title
            // bar even though the shell sidebar is hidden.
            WindowDragHandle()
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !model.network.isOnline {
                    LoginNetworkBanner()
                        .padding(.top, 40)
                        .padding(.horizontal, 40)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                loginColumn
                    .frame(width: 420)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: model.network.isOnline)
        }
        .onAppear {
            probe.configure(core: model.core)
            discovery.start()
            // Prefill from the last successful sign-in. This also covers the
            // post-auth-expired bounce (#303): the auth-expired sheet drops
            // the token but keeps `serverURL` / `username` around so the
            // user only has to re-enter their password.
            if url.isEmpty, !model.serverURL.isEmpty {
                url = model.serverURL
                // Prefilled URLs should show server version right away —
                // schedule a probe so the success row populates on appear.
                probe.schedule(url: url)
            }
            focusedField = model.username.isEmpty ? .url : .password
        }
        .onDisappear {
            discovery.stop()
            probe.reset()
        }
        .onChange(of: url) { _, newValue in
            if newValue.isEmpty {
                probe.reset()
            } else {
                probe.schedule(url: newValue)
            }
        }
        .onChange(of: model.serverReachability.isServerReachable) { _, reachable in
            if !reachable { hasSeenRepeatedUnreachable = true }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var loginColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            brand
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            if !discovery.servers.isEmpty {
                discoveredServersRow
            }

            VStack(alignment: .leading, spacing: 14) {
                urlField
                probeResultRow
                usernameField
                passwordField

                if let error = loginErrorMessage {
                    Text(error)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.accentHot)
                        .padding(.top, 2)
                }
            }

            signInButton

            secondaryActions
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 40)
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet(serverURL: url)
        }
    }

    /// "Use Jellyfin Quick Connect" link plus the device-name gear, sitting just
    /// below the primary sign-in button (#202). The gear opens a popover so the
    /// user can rename the device Jellyfin shows for this client.
    @ViewBuilder
    private var secondaryActions: some View {
        HStack(spacing: 12) {
            Button {
                showQuickConnect = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 11, weight: .bold))
                    Text("login.quick_connect.link")
                        .font(Theme.font(13, weight: .semibold))
                }
                .foregroundStyle(Theme.teal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("login.quick_connect.link")
            .accessibilityHint("login.quick_connect.a11y_hint")

            Spacer(minLength: 0)

            deviceNameGear
        }
        .frame(maxWidth: .infinity)
    }

    /// Gear button that reveals the device-name editor. Shows the current name
    /// in its accessibility label so VoiceOver users know what's editable.
    @ViewBuilder
    private var deviceNameGear: some View {
        Button {
            showDeviceName = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.deviceName)
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: 180, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help("login.device_name.help")
        .accessibilityLabel(deviceNameA11yLabel)
        .popover(isPresented: $showDeviceName, arrowEdge: .bottom) {
            DeviceNamePopover()
                .environment(model)
        }
    }

    @ViewBuilder
    private var brand: some View {
        VStack(spacing: 4) {
            JellyfishMark(size: 72)
                .padding(.bottom, 4)
            Text("app.name")
                .font(Theme.font(40, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("app.subtitle.desktop")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(3)
        }
    }

    @ViewBuilder
    private var discoveredServersRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("login.discovered_servers")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            LoginFlowLayout(spacing: 6) {
                ForEach(discovery.servers) { server in
                    Button {
                        url = server.url.isEmpty ? server.name : server.url
                        probe.schedule(url: url)
                        focusedField = .username
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wifi")
                                .font(.system(size: 10, weight: .bold))
                            Text(server.name)
                                .font(Theme.font(12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use discovered server \(server.name)")
                }
            }
        }
    }

    @ViewBuilder
    private var urlField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("login.field.url")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            // URL placeholder is a sample host, not a translatable phrase.
            TextField(String("https://jellyfin.example.com"), text: $url)
                .textFieldStyle(.plain)
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .focused($focusedField, equals: .url)
                .submitLabel(.next)
                .onSubmit { focusedField = .username }
                .accessibilityLabel("login.a11y.server_url")
        }
    }

    @ViewBuilder
    private var probeResultRow: some View {
        // Reserve space so the field layout doesn't jump when the row
        // appears/disappears. Empty text still counts as a 1-line frame.
        Group {
            switch probe.state {
            case .idle:
                Text(" ")
                    .font(Theme.font(12, weight: .medium))
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("login.probe.checking")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.teal)
                }
            case .ok(let version, let name):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.teal)
                    Text(probeOkLabel(version: version, name: name))
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                }
            case .failed(let message):
                Text(message)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.accentHot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: probeStateKey)
    }

    @ViewBuilder
    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("login.field.username")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            TextField(
                LocalizedStringKey("login.username.placeholder"),
                text: Binding(get: { model.username }, set: { model.username = $0 })
            )
                .textFieldStyle(.plain)
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .accessibilityLabel("login.a11y.username")
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("login.field.password")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            // Bullet glyphs are the masked-input affordance; not a phrase.
            SecureField(String("••••••••"), text: $password)
                .textFieldStyle(.plain)
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(passwordBorderColor, lineWidth: 1)
                )
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .modifier(ShakeEffect(animatableData: CGFloat(shakeAttempts)))
                .animation(.interpolatingSpring(stiffness: 800, damping: 10), value: shakeAttempts)
                .accessibilityLabel("login.a11y.password")
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if model.isLoggingIn {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.ink)
                }
                // Toggle between the two catalog keys rather than the raw
                // literals so translators never see "Signing in…" in a
                // ternary — each shows up as its own extractable row.
                Text(model.isLoggingIn ? LocalizedStringKey("auth.signing_in") : LocalizedStringKey("auth.sign_in"))
                    .font(Theme.font(14, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(Theme.ink)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .disabled(model.isLoggingIn || !canSubmit)
        .opacity(canSubmit ? 1 : 0.5)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("auth.sign_in")
    }

    // MARK: - Actions

    private func submit() {
        guard canSubmit, !model.isLoggingIn else { return }
        let previousError = model.errorMessage
        // Snapshot the localized copy that `LyrebirdErrorPresenter` emits for
        // auth failures (401 / NotAuthenticated / AuthExpired). When the
        // model surfaces this exact string we're dealing with a credential
        // problem at submit-time, so replace it with the friendlier shake +
        // wrong-credentials copy. See `LyrebirdErrorPresenter.key(for:)`.
        let authExpiredCopy = String(localized: "error.auth.expired", bundle: .main)
        Task {
            await model.login(url: url, username: model.username, password: password)
            if let err = model.errorMessage, err != previousError {
                if err == authExpiredCopy {
                    shakeAttempts += 1
                    // Overwrite the generic "Please sign in again." with the
                    // form-specific "Wrong username or password" so the row
                    // under the fields reads cleanly.
                    model.errorMessage = String(localized: "error.wrong_credentials", bundle: .main)
                }
            }
        }
    }

    // MARK: - Derived state

    private var canSubmit: Bool {
        // Empty password is allowed — Jellyfin supports passwordless accounts
        // and the server is the authority on whether the password is valid.
        !url.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var loginErrorMessage: String? {
        if !model.network.isOnline {
            // The banner at the top already covers offline; skip the inline
            // row so we don't double up.
            return nil
        }
        if hasSeenRepeatedUnreachable && !model.serverReachability.isServerReachable {
            if let relative = LastConnectedStore.relativeLastConnected() {
                return "Last connected \(relative). Trying offline mode."
            }
            return "Trying offline mode."
        }
        return model.errorMessage
    }

    private var passwordBorderColor: Color {
        // Compare against the localized `error.wrong_credentials` copy so the
        // border-tint heuristic continues to work regardless of language.
        let wrongCreds = String(localized: "error.wrong_credentials", bundle: .main)
        if let err = model.errorMessage, err == wrongCreds {
            return Theme.accentHot
        }
        return Theme.border
    }

    /// Collapses the probe state into a small value so `.animation(value:)`
    /// fires only on meaningful transitions (not every `ok` with an equal
    /// version).
    private var probeStateKey: Int {
        switch probe.state {
        case .idle: return 0
        case .checking: return 1
        case .ok: return 2
        case .failed: return 3
        }
    }

    /// VoiceOver label for the device-name gear, naming the current device so
    /// the user knows what tapping it edits. Built via `String(localized:)` with
    /// an argument so the device name isn't baked into the catalog key.
    private var deviceNameA11yLabel: Text {
        Text("login.device_name.a11y_label \(model.deviceName)")
    }

    private func probeOkLabel(version: String, name: String) -> String {
        let versionLabel = "Jellyfin \(version)"
        if !name.isEmpty, name != "Jellyfin" {
            return "\(versionLabel) · \(name)"
        }
        return versionLabel
    }
}

// MARK: - Helpers

/// Small NSView wrapper that lets the user drag the window by the invisible
/// bar we place at the top of `LoginView`. The standard macOS behaviour
/// requires the title bar chrome; hiding the sidebar leaves the top 28pt
/// region as the only drag surface.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Repeating horizontal shake applied to the password field on 401. Uses
/// `animatableData` so SwiftUI can interpolate between the discrete
/// attempt-count values.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat = 0

    func effectValue(size: CGSize) -> ProjectionTransform {
        let amplitude: CGFloat = 6
        // Three oscillations across the animation duration gives a visible
        // but brief shake; clamp the phase to the fractional part so the
        // effect starts/ends at zero.
        let phase = animatableData.truncatingRemainder(dividingBy: 1.0)
        let translationX = amplitude * sin(phase * .pi * 6)
        return ProjectionTransform(CGAffineTransform(translationX: translationX, y: 0))
    }
}

/// Inline banner shown above the login column when the system reports no
/// network. Narrower and less persistent than the in-app `OfflineBanner`
/// used inside `MainShell` — login has no sidebar to anchor against.
struct LoginNetworkBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text("login.network_banner")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.danger).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Stylised jellyfish brand mark. Pure SwiftUI (no asset catalog required)
/// so `macos/` ships the same binary on any machine. Rendered as a glowing
/// dome with trailing tendrils; the forms are abstract enough to read at
/// both onboarding (120pt) and login (72pt) sizes.
struct JellyfishMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let center = CGPoint(x: w / 2, y: h * 0.40)
            let domeRadius = w * 0.32

            // Soft outer glow.
            let glowRadius = domeRadius * 1.4
            let glowRect = CGRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )
            ctx.fill(
                Path(ellipseIn: glowRect),
                with: .color(Theme.primary.opacity(0.18))
            )

            // Inner glow.
            let innerGlowRect = CGRect(
                x: center.x - domeRadius * 1.1,
                y: center.y - domeRadius * 1.1,
                width: domeRadius * 2.2,
                height: domeRadius * 2.2
            )
            ctx.fill(
                Path(ellipseIn: innerGlowRect),
                with: .color(Theme.accent.opacity(0.25))
            )

            // Dome.
            let domeRect = CGRect(
                x: center.x - domeRadius,
                y: center.y - domeRadius * 0.95,
                width: domeRadius * 2,
                height: domeRadius * 1.5
            )
            let dome = Path { p in
                p.addArc(
                    center: center,
                    radius: domeRadius,
                    startAngle: .degrees(200),
                    endAngle: .degrees(340),
                    clockwise: false
                )
                p.addLine(to: CGPoint(x: center.x + domeRadius * 0.95, y: center.y + domeRadius * 0.12))
                p.addQuadCurve(
                    to: CGPoint(x: center.x - domeRadius * 0.95, y: center.y + domeRadius * 0.12),
                    control: CGPoint(x: center.x, y: center.y + domeRadius * 0.55)
                )
                p.closeSubpath()
            }
            ctx.fill(
                dome,
                with: .linearGradient(
                    Gradient(colors: [Theme.primary, Theme.accent]),
                    startPoint: CGPoint(x: domeRect.minX, y: domeRect.minY),
                    endPoint: CGPoint(x: domeRect.maxX, y: domeRect.maxY)
                )
            )

            // Tendrils — four wavy tails below the dome.
            let tendrilCount = 4
            let tendrilSpacing = (domeRadius * 1.6) / CGFloat(tendrilCount - 1)
            let tendrilTop = center.y + domeRadius * 0.1
            let tendrilBottom = center.y + domeRadius * 1.7
            for i in 0..<tendrilCount {
                let x = center.x - domeRadius * 0.8 + CGFloat(i) * tendrilSpacing
                let amp: CGFloat = domeRadius * 0.12 * (i.isMultiple(of: 2) ? 1 : -1)
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: tendrilTop))
                    p.addCurve(
                        to: CGPoint(x: x, y: tendrilBottom),
                        control1: CGPoint(x: x + amp, y: tendrilTop + (tendrilBottom - tendrilTop) * 0.33),
                        control2: CGPoint(x: x - amp, y: tendrilTop + (tendrilBottom - tendrilTop) * 0.66)
                    )
                }
                ctx.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [Theme.accent, Theme.primary.opacity(0.4)]),
                        startPoint: CGPoint(x: x, y: tendrilTop),
                        endPoint: CGPoint(x: x, y: tendrilBottom)
                    ),
                    style: StrokeStyle(lineWidth: domeRadius * 0.10, lineCap: .round)
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Simple wrap-to-next-line layout for the discovered-servers chip row.
/// SwiftUI's stock `HStack` would clip on narrow columns; this lays each
/// child out in reading order and wraps when the running width exceeds the
/// available width. Named `LoginFlowLayout` to avoid collision with the
/// private `FlowLayout` in `AlbumDetailView.swift`.
struct LoginFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        guard !rows.isEmpty else { return .zero }
        let totalHeight = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let fallbackWidth = rows.map(\.width).max() ?? 0
        return CGSize(
            width: width.isFinite ? width : fallbackWidth,
            height: totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.sizeThatFits(.unspecified)
                item.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [LayoutSubview] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows.removeLast()
            let projected = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if projected > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            if row.items.isEmpty {
                row.items = [subview]
                row.width = size.width
            } else {
                row.items.append(subview)
                row.width += spacing + size.width
            }
            row.height = max(row.height, size.height)
            rows.append(row)
        }
        return rows
    }
}
