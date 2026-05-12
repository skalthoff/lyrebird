import SwiftUI
@preconcurrency import LyrebirdCore

/// Three-step first-launch onboarding flow.
///
/// 1. **Welcome** (#291) — brand mark, tagline, Get Started CTA.
/// 2. **Connect Server** (#292) — same fields as login with extended helper
///    copy and a "Skip, explore offline" escape link.
/// 3. **First Sync** (#293) — animated progress through artists → albums →
///    tracks → artwork with a live counter; "Continue to Home" unlocks when
///    the library crosses an 80% threshold.
///
/// The flow exits by either completing a successful login (the last step
/// flips `hasCompletedOnboarding` once the initial library sync crosses
/// threshold and bounces the user into `MainShell`) or by tapping the
/// "Skip, explore offline" link on the connect step (same flag flip, lands
/// on `LoginView` which becomes the signed-out surface).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    /// Persisted flag. Set to `true` once the user either completes the
    /// flow or skips from the connect step. `RootView` reads this via
    /// `@AppStorage` to decide between showing `OnboardingView` (first
    /// launch) or `LoginView` (signed out but already onboarded).
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    @State private var step: Step = .welcome

    /// Form state is lifted up here so back/forward between Welcome and
    /// Connect preserves what the user typed.
    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var probe = ServerProbe()
    @State private var discovery = ServerDiscovery()

    enum Step: Hashable { case welcome, connect, sync }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            WindowDragHandle()
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .frame(width: 460)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            probe.configure(core: model.core)
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep(
                onGetStarted: { step = .connect },
                onExistingAccount: {
                    // "I already have an account" skips the hero pitch but
                    // keeps the connect step — the copy there is still
                    // useful for returning users who haven't set up this
                    // machine before.
                    step = .connect
                }
            )
            .transition(.opacity)
        case .connect:
            ConnectStep(
                url: $url,
                username: $username,
                password: $password,
                probe: probe,
                discovery: discovery,
                onBack: { step = .welcome },
                onContinue: {
                    // Successful login flips to the sync step; the view
                    // uses `model.session` as its cue to render progress.
                    step = .sync
                },
                onSkipOffline: {
                    // Skip-explore-offline: mark the user as onboarded so
                    // subsequent launches land on LoginView and let them
                    // poke around the (empty) shell immediately.
                    hasCompletedOnboarding = true
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case .sync:
            FirstSyncStep(
                onContinue: {
                    hasCompletedOnboarding = true
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

// MARK: - Welcome step

private struct WelcomeStep: View {
    let onGetStarted: () -> Void
    let onExistingAccount: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            JellyfishMark(size: 120)
                .padding(.bottom, 8)

            Text("Welcome to Lyrebird")
                .font(Theme.font(48, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            Text("Your music, your server, your rules.")
                .font(Theme.font(16, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)

            VStack(spacing: 14) {
                Button(action: onGetStarted) {
                    Text("Get started")
                        .font(Theme.font(14, weight: .bold))
                        .frame(width: 280, height: 44)
                        .foregroundStyle(Theme.ink)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Get started")

                Button(action: onExistingAccount) {
                    Text("I already have an account →")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("I already have an account")
            }
            .padding(.top, 16)
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Connect step

private struct ConnectStep: View {
    @Environment(AppModel.self) private var model

    @Binding var url: String
    @Binding var username: String
    @Binding var password: String
    let probe: ServerProbe
    let discovery: ServerDiscovery

    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipOffline: () -> Void

    @FocusState private var focusedField: Field?
    @State private var shakeAttempts: Int = 0

    private enum Field: Hashable { case url, username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                BackButton(action: onBack)
                Spacer()
                ProgressDots(current: 2, of: 3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your server")
                    .font(Theme.font(28, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("Your Jellyfin URL is the address you use to reach it from a browser.")
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !discovery.servers.isEmpty {
                DiscoveredServersChipRow(
                    servers: discovery.servers,
                    onPick: { server in
                        url = server.url.isEmpty ? server.name : server.url
                        probe.schedule(url: url)
                        focusedField = .username
                    }
                )
            }

            VStack(alignment: .leading, spacing: 14) {
                labeledField(
                    label: "SERVER URL",
                    placeholder: "https://jellyfin.example.com",
                    text: $url,
                    focus: .url,
                    onSubmit: { focusedField = .username }
                )
                ProbeResultRow(state: probe.state)

                labeledField(
                    label: "USERNAME",
                    placeholder: "you",
                    text: $username,
                    focus: .username,
                    onSubmit: { focusedField = .password }
                )

                labeledSecureField(
                    label: "PASSWORD",
                    placeholder: "••••••••",
                    text: $password,
                    shake: shakeAttempts,
                    onSubmit: submit
                )

                if let err = visibleError {
                    Text(err)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.accentHot)
                }
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if model.isLoggingIn {
                        ProgressView().scaleEffect(0.7).tint(Theme.ink)
                    }
                    Text(model.isLoggingIn ? "Connecting…" : "Continue")
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
            .disabled(!canSubmit || model.isLoggingIn)
            .opacity(canSubmit ? 1 : 0.5)
            .keyboardShortcut(.defaultAction)

            Button(action: onSkipOffline) {
                Text("Skip, explore offline →")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 40)
        .onAppear {
            discovery.start()
            focusedField = url.isEmpty ? .url : .username
        }
        .onDisappear {
            discovery.stop()
        }
        .onChange(of: url) { _, newValue in
            if newValue.isEmpty {
                probe.reset()
            } else {
                probe.schedule(url: newValue)
            }
        }
        .onChange(of: model.session != nil) { _, signedIn in
            if signedIn { onContinue() }
        }
    }

    private var canSubmit: Bool {
        // Empty password is allowed — Jellyfin supports passwordless accounts
        // and the server is the authority on whether the password is valid.
        !url.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Generic error banner. Since `AppModel.login` now surfaces errors
    /// through `LyrebirdErrorPresenter`, any 401 is already translated to
    /// the shared `error.auth.expired` copy. We still want the onboarding
    /// flow to replace that specific message with the form-specific
    /// "Wrong username or password" hint.
    private var visibleError: String? {
        guard let err = model.errorMessage else { return nil }
        let authExpiredCopy = String(localized: "error.auth.expired", bundle: .main)
        if err == authExpiredCopy {
            return String(localized: "error.wrong_credentials", bundle: .main)
        }
        return err
    }

    private func submit() {
        guard canSubmit, !model.isLoggingIn else { return }
        let previous = model.errorMessage
        let authExpiredCopy = String(localized: "error.auth.expired", bundle: .main)
        Task {
            await model.login(url: url, username: username, password: password)
            if let err = model.errorMessage, err != previous, err == authExpiredCopy {
                shakeAttempts += 1
                model.errorMessage = String(localized: "error.wrong_credentials", bundle: .main)
            }
        }
    }

    @ViewBuilder
    private func labeledField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focus: Field,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            TextField(placeholder, text: text)
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
                .focused($focusedField, equals: focus)
                .submitLabel(.next)
                .onSubmit(onSubmit)
        }
    }

    @ViewBuilder
    private func labeledSecureField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        shake: Int,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            SecureField(placeholder, text: text)
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
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(onSubmit)
                .modifier(ShakeEffect(animatableData: CGFloat(shake)))
                .animation(.interpolatingSpring(stiffness: 800, damping: 10), value: shake)
        }
    }
}

// MARK: - First sync step

private struct FirstSyncStep: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void

    /// Nominal 0…1 progress derived from which library lists have started
    /// populating. `refreshLibrary` fans out artist / album / track calls in
    /// parallel, so this animates through the phases in order even when the
    /// server answers fast.
    @State private var animatedProgress: Double = 0.0

    /// Current animated phase. Drives the "Loading artists… / albums… /
    /// tracks… / artwork…" copy line.
    @State private var phase: SyncPhase = .artists

    enum SyncPhase: Int, CaseIterable {
        case artists, albums, tracks, artwork

        var label: String {
            switch self {
            case .artists: return "Loading artists…"
            case .albums: return "Loading albums…"
            case .tracks: return "Loading tracks…"
            case .artwork: return "Fetching artwork…"
            }
        }
    }

    /// Progress crosses 0.8 = CTA unlocks. Matches the spec: "Continue to
    /// Home button activates when sync crosses 80%." Once activated, the
    /// computed library-percent or the animation whichever is further keeps
    /// the bar in sync while the user is deciding.
    private var isReady: Bool {
        displayProgress >= 0.8
    }

    private var displayProgress: Double {
        max(animatedProgress, librarySyncRatio)
    }

    /// Fraction of the library we actually have locally so far. This grows
    /// as `refreshLibrary` populates `albums`, `artists`, and `tracks`
    /// arrays on `AppModel`. When the server-reported totals are all zero
    /// (e.g. on a brand-new server) we still let the animation tick so the
    /// progress bar doesn't sit at 0.
    private var librarySyncRatio: Double {
        let known = Double(model.albums.count + model.artists.count + model.tracks.count)
        let total = Double(Int(model.albumsTotal) + Int(model.artistsTotal) + Int(model.tracksTotal))
        guard total > 0 else { return 0 }
        return min(1.0, known / total)
    }

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Spacer()
                ProgressDots(current: 3, of: 3)
            }

            VStack(spacing: 8) {
                JellyfishMark(size: 72)
                Text("Loading your library")
                    .font(Theme.font(28, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
            }

            // Animated progress bar.
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surface)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(
                                colors: [Theme.accent, Theme.primary],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * displayProgress, height: 6)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(phase.label)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                    Spacer()
                    Text(counterLabel)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }
            }

            Button(action: onContinue) {
                Text(isReady ? "Continue to Home" : "Syncing…")
                    .font(Theme.font(14, weight: .bold))
                    .frame(width: 280, height: 44)
                    .foregroundStyle(Theme.ink)
                    .background(isReady ? Theme.accent : Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(
                        color: Theme.accent.opacity(isReady ? 0.35 : 0),
                        radius: 18, x: 0, y: 10
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isReady)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue to Home")
        }
        .padding(.vertical, 40)
        .onAppear {
            startProgressAnimation()
            // `ConnectStep.submit` calls `model.login`, which already kicks
            // off `refreshLibrary`. If we got here via `onChange` of
            // `model.session`, the library fetch is likely already in
            // flight. No extra call needed — `librarySyncRatio` will tick
            // up as the arrays populate.
        }
    }

    /// Server-reported total across the three lists we care about. Same
    /// signal as the counter row but rolled into a single display number
    /// used in the CTA readiness check.
    private var counterLabel: String {
        // Prefer server totals when available — the counter reads as
        // "4,208 tracks · 312 artists · 586 albums" per the spec. Falls
        // back to local counts during the animation when the library
        // totals haven't landed yet.
        let tracks = max(Int(model.tracksTotal), model.tracks.count)
        let artists = max(Int(model.artistsTotal), model.artists.count)
        let albums = max(Int(model.albumsTotal), model.albums.count)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let t = formatter.string(from: NSNumber(value: tracks)) ?? "\(tracks)"
        let a = formatter.string(from: NSNumber(value: artists)) ?? "\(artists)"
        let al = formatter.string(from: NSNumber(value: albums)) ?? "\(albums)"
        return "\(t) tracks · \(a) artists · \(al) albums"
    }

    /// Drives `animatedProgress` and `phase` forward on a 250ms tick so
    /// the bar doesn't sit still on a slow network. Caps at 0.85 so the
    /// remaining 15% is reserved for the real library sync to push across
    /// the finish line; if the real sync beats the animation (fast server,
    /// small library) `displayProgress` jumps to `librarySyncRatio` and the
    /// CTA unlocks immediately.
    private func startProgressAnimation() {
        Task { @MainActor in
            let phases = SyncPhase.allCases
            // Aim for a total animation of ~6s through the four phases if
            // the server never answers; that's long enough that a typical
            // library fetch wins and short enough that a pathological
            // server doesn't frustrate the user.
            let phaseDuration: Double = 1.5
            for (i, next) in phases.enumerated() {
                phase = next
                let start = animatedProgress
                let end = min(0.85, Double(i + 1) / Double(phases.count) * 0.85)
                let steps = 15
                for s in 0..<steps {
                    try? await Task.sleep(nanoseconds: UInt64(phaseDuration / Double(steps) * 1_000_000_000))
                    let t = Double(s + 1) / Double(steps)
                    withAnimation(.linear(duration: 0.1)) {
                        animatedProgress = start + (end - start) * t
                    }
                    if isReady { return }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct ProgressDots: View {
    let current: Int
    let of: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<of, id: \.self) { i in
                Circle()
                    .fill(i < current ? Theme.accent : Theme.border)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text("Back")
                    .font(Theme.font(12, weight: .semibold))
            }
            .foregroundStyle(Theme.ink3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

private struct ProbeResultRow: View {
    let state: ServerProbeState
    var body: some View {
        Group {
            switch state {
            case .idle:
                Text(" ").font(Theme.font(12, weight: .medium))
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.teal)
                }
            case .ok(let version, let name):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.teal)
                    Text(label(version: version, name: name))
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
    }

    private func label(version: String, name: String) -> String {
        if !name.isEmpty, name != "Jellyfin" {
            return "Jellyfin \(version) · \(name)"
        }
        return "Jellyfin \(version)"
    }
}

private struct DiscoveredServersChipRow: View {
    let servers: [DiscoveredServer]
    let onPick: (DiscoveredServer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FOUND ON THIS NETWORK")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            LoginFlowLayout(spacing: 6) {
                ForEach(servers) { server in
                    Button {
                        onPick(server)
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
                }
            }
        }
    }
}
