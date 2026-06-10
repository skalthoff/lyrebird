import SwiftUI
@preconcurrency import LyrebirdCore

/// Three-step first-launch onboarding flow.
///
/// 1. **Welcome** (#291) — brand mark, tagline, Get Started CTA.
/// 2. **Connect Server** (#292) — same fields as login with extended helper
///    copy and a "Skip, explore offline" escape link.
/// 3. **First Sync** (#293) — animated progress through artists → albums →
///    tracks → artwork with a live counter; "Continue to Home" unlocks only
///    once the library has *actually* loaded (see `FirstSyncGate`), not when
///    the cosmetic timer finishes.
///
/// The flow exits by either completing a successful login (the last step
/// flips `hasCompletedOnboarding` once the initial library sync has produced
/// real data and bounces the user into `MainShell`) or by tapping the
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

            Text("onboarding.welcome.title")
                .font(Theme.font(48, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            Text("onboarding.welcome.subtitle")
                .font(Theme.font(16, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)

            VStack(spacing: 14) {
                Button(action: onGetStarted) {
                    Text("onboarding.welcome.get_started")
                        .font(Theme.font(14, weight: .bold))
                        .frame(width: 280, height: 44)
                        .foregroundStyle(Theme.ink)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("onboarding.welcome.get_started")

                Button(action: onExistingAccount) {
                    Text("onboarding.welcome.existing_account")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("onboarding.welcome.existing_account.a11y")
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
                Text("onboarding.connect.title")
                    .font(Theme.font(28, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("onboarding.connect.subtitle")
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
                    label: "login.field.url",
                    a11yLabel: "login.a11y.server_url",
                    // URL placeholder is a sample host, not a translatable phrase.
                    placeholder: String("https://jellyfin.example.com"),
                    text: $url,
                    focus: .url,
                    onSubmit: { focusedField = .username }
                )
                ProbeResultRow(state: probe.state)

                labeledField(
                    label: "login.field.username",
                    a11yLabel: "login.a11y.username",
                    placeholder: String(localized: "login.username.placeholder"),
                    text: $username,
                    focus: .username,
                    onSubmit: { focusedField = .password }
                )

                labeledSecureField(
                    label: "login.field.password",
                    a11yLabel: "login.a11y.password",
                    // Bullet glyphs are the masked-input affordance; not a phrase.
                    placeholder: String("••••••••"),
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
                    Text(model.isLoggingIn ? LocalizedStringKey("onboarding.connect.connecting") : LocalizedStringKey("onboarding.connect.continue"))
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
                Text("onboarding.connect.skip_offline")
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
            // Re-onboarding while already authenticated (e.g. a returning
            // user who reset onboarding but kept a live session): advance
            // straight to the sync step instead of stranding them on a
            // Connect form they've already satisfied. The `onChange` below
            // can't catch this case because the session is non-nil from the
            // first render, so the value never *changes*.
            if model.session != nil { onContinue() }
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
        // Observe the session *identity* rather than a nil-ness Bool: a fresh
        // login that replaces an already-non-nil session leaves the Bool
        // unchanged, so the auto-advance would never fire. The user id flips
        // on any sign-in (including signing in as a different account), which
        // is the real signal we want to advance on.
        .onChange(of: model.session?.user.id) { _, userId in
            if userId != nil { onContinue() }
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
        label: LocalizedStringKey,
        a11yLabel: LocalizedStringKey,
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
                .accessibilityLabel(a11yLabel)
        }
    }

    @ViewBuilder
    private func labeledSecureField(
        label: LocalizedStringKey,
        a11yLabel: LocalizedStringKey,
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
                .accessibilityLabel(a11yLabel)
        }
    }
}

// MARK: - First sync step

/// Pure decision logic for when the "Continue to Home" CTA may unlock.
///
/// Split out from the view so it can be unit-tested without rendering: the
/// regression we're guarding against is the CTA opening on a *cosmetic*
/// timer regardless of whether any real data loaded (#293). The gate is now
/// driven exclusively by `AppModel` signals.
enum FirstSyncGate {
    /// `true` only when the initial library load has actually finished
    /// successfully *and* there's something to show (or the server genuinely
    /// has an empty library, in which case there's nothing to wait for).
    ///
    /// - Parameters:
    ///   - finishedLoading: the initial `refreshLibrary` round-trip completed
    ///     (whether it succeeded or failed). Until this latches, the gate is
    ///     closed no matter what the cosmetic progress bar shows.
    ///   - hasError: `model.errorMessage` is non-nil — the load failed, so we
    ///     must not strand the user in an empty library.
    ///   - hasAnyData: at least one album / artist / track landed locally.
    ///   - librarySyncRatio: fraction of the server-reported totals we hold
    ///     locally. Crosses the 0.8 threshold only for libraries that fit in
    ///     the initial page; large libraries unlock via `hasAnyData` instead
    ///     (Home is paginated and loads more on scroll).
    ///   - serverReportsEmptyLibrary: the server's totals are all zero, so a
    ///     completed-but-empty load is a legitimate "nothing to sync" state.
    static func isReady(
        finishedLoading: Bool,
        hasError: Bool,
        hasAnyData: Bool,
        librarySyncRatio: Double,
        serverReportsEmptyLibrary: Bool
    ) -> Bool {
        guard finishedLoading, !hasError else { return false }
        return librarySyncRatio >= readyThreshold || hasAnyData || serverReportsEmptyLibrary
    }

    /// Spec threshold: "Continue to Home activates when sync crosses 80%."
    /// Only reachable for single-page libraries; see `isReady`.
    static let readyThreshold: Double = 0.8
}

private struct FirstSyncStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutDirection) private var layoutDirection
    let onContinue: () -> Void

    /// Nominal 0…1 progress used purely to animate the bar so it doesn't sit
    /// still on a slow network. This is *cosmetic only* — it never gates the
    /// CTA (see `FirstSyncGate`). The real fraction (`librarySyncRatio`) is
    /// blended in so a fast server visibly fills the bar.
    @State private var animatedProgress: Double = 0.0

    /// Current animated phase. Drives the "Loading artists… / albums… /
    /// tracks… / artwork…" copy line.
    @State private var phase: SyncPhase = .artists

    /// Latches `true` once the initial library load has finished (success or
    /// failure). The CTA stays disabled until this flips, regardless of the
    /// cosmetic progress bar. Guarded so the pre-load render (when no fetch
    /// has started yet) can't open the gate.
    @State private var didFinishInitialLoad = false

    enum SyncPhase: Int, CaseIterable {
        case artists, albums, tracks, artwork

        var labelKey: LocalizedStringKey {
            switch self {
            case .artists: return "onboarding.sync.phase.artists"
            case .albums: return "onboarding.sync.phase.albums"
            case .tracks: return "onboarding.sync.phase.tracks"
            case .artwork: return "onboarding.sync.phase.artwork"
            }
        }
    }

    /// Whether the load failed — drives the error row + retry affordance.
    private var hasError: Bool {
        model.errorMessage != nil
    }

    /// At least one album / artist / track has landed locally.
    private var hasAnyData: Bool {
        !model.albums.isEmpty || !model.artists.isEmpty || !model.tracks.isEmpty
    }

    /// The server reports a genuinely empty library (all totals zero). Only
    /// meaningful once `didFinishInitialLoad` is set — before that the totals
    /// are simply unresolved.
    private var serverReportsEmptyLibrary: Bool {
        model.albumsTotal == 0 && model.artistsTotal == 0 && model.tracksTotal == 0
    }

    /// CTA readiness, driven entirely by real load signals.
    private var isReady: Bool {
        FirstSyncGate.isReady(
            finishedLoading: didFinishInitialLoad,
            hasError: hasError,
            hasAnyData: hasAnyData,
            librarySyncRatio: librarySyncRatio,
            serverReportsEmptyLibrary: serverReportsEmptyLibrary
        )
    }

    /// Cosmetic bar fill: the further of the animation and the real fraction
    /// while loading; pinned full once the data is actually ready.
    private var displayProgress: Double {
        if isReady { return 1.0 }
        return max(animatedProgress, librarySyncRatio)
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
                Text("onboarding.sync.title")
                    .font(Theme.font(28, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
            }

            // Animated progress bar.
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    // Anchor fill to the reading-start edge so it grows in
                    // the correct direction in RTL locales.
                    ZStack(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.surface)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(
                                colors: [Theme.accent, Theme.primary],
                                startPoint: layoutDirection == .rightToLeft ? .trailing : .leading,
                                endPoint: layoutDirection == .rightToLeft ? .leading : .trailing
                            ))
                            .frame(width: geo.size.width * displayProgress, height: 6)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    if hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accentHot)
                        Text("onboarding.sync.error")
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.accentHot)
                        Button(action: retry) {
                            Text("onboarding.sync.retry")
                                .font(Theme.font(12, weight: .bold))
                                .foregroundStyle(Theme.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("onboarding.sync.retry")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(phase.labelKey)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.teal)
                    }
                    Spacer()
                    Text(counterLabel)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }
            }

            Button(action: onContinue) {
                Text(isReady ? LocalizedStringKey("onboarding.sync.continue") : LocalizedStringKey("onboarding.sync.syncing"))
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
            .accessibilityLabel("onboarding.sync.continue")
        }
        .padding(.vertical, 40)
        .onAppear {
            startProgressAnimation()
            ensureLibraryLoad()
        }
        .onChange(of: model.isLoadingLibrary) { _, loading in
            // The initial fetch kicked off by `model.login` (or by
            // `ensureLibraryLoad` below) completes when this flips back to
            // false. That's the real "sync finished" edge that unlocks the
            // CTA — never the cosmetic timer.
            if !loading { didFinishInitialLoad = true }
        }
    }

    /// Make sure a library load actually runs. `ConnectStep.submit` →
    /// `model.login` already kicks off `refreshLibrary`, so in the common
    /// path a fetch is in flight (or finished) by the time we get here and we
    /// just observe its completion via `onChange(of: isLoadingLibrary)`. The
    /// fallbacks cover paths that reach the sync step without a fetch having
    /// been triggered (so the CTA can't hang forever).
    private func ensureLibraryLoad() {
        if model.isLoadingLibrary {
            // A fetch (login's) is in flight; the onChange handler latches
            // completion. Nothing to do.
            return
        }
        if hasAnyData || hasError {
            // The fetch already finished before this view appeared (data
            // present) or failed (error surfaced). Either way it's done.
            didFinishInitialLoad = true
            return
        }
        // No fetch in flight and nothing loaded — drive one ourselves so the
        // CTA can eventually unlock. `onChange(of: isLoadingLibrary)` latches
        // completion once `refreshLibrary` finishes.
        Task { await model.refreshLibrary() }
    }

    /// Retry a failed initial load. Clears the error so the progress row
    /// returns to its loading state, then re-fetches.
    private func retry() {
        didFinishInitialLoad = false
        model.errorMessage = nil
        Task { await model.refreshLibrary() }
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
        // Look up the positional template ("%1$@ tracks · %2$@ artists ·
        // %3$@ albums") by key and fill in the pre-formatted, grouping-
        // separated counts. Using the format-string form (rather than
        // interpolating into the key) keeps the catalog key stable and lets
        // translators reorder the clauses.
        let template = String(localized: "onboarding.sync.counter")
        return String(format: template, t, a, al)
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
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Back chevron points toward the reading start; in RTL that is the right.
                Image(systemName: layoutDirection == .rightToLeft ? "chevron.right" : "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text("onboarding.back")
                    .font(Theme.font(12, weight: .semibold))
            }
            .foregroundStyle(Theme.ink3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("onboarding.back")
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
                    Text("login.probe.checking")
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
            Text("login.discovered_servers")
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
                    .accessibilityLabel("Use discovered server \(server.name)")
                }
            }
        }
    }
}
