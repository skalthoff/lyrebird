import SwiftUI

/// First-run feature tour (coach marks) — issue #113.
///
/// A short, dismissible sequence of callout cards shown **once** on the
/// first launch *after* the user connects a server, pointing out four power
/// features that aren't obvious from the chrome alone: right-click context
/// menus, the Space play/pause shortcut, ⌘F search, and the detachable mini
/// player.
///
/// This is deliberately distinct from `OnboardingView` (the server *connect*
/// flow, #291/#292/#293). Onboarding gets the user signed in; the tour
/// teaches the app once they're in. They never appear at the same time —
/// `MainShell` only mounts the tour, and `MainShell` only renders for a live
/// `model.session`, which by definition means onboarding has already exited.
///
/// The whole surface is self-contained: a pure step model (`FeatureTourStep`
/// + the `FeatureTour.steps` catalog), a tiny persistence wrapper
/// (`FeatureTourSeenStore`) that records whether the tour has been shown, and
/// a single overlay view (`FeatureTourOverlay`). The only outside touch is a
/// one-line `@AppStorage` first-run flag plus a Help ▸ "Show Tour" entry that
/// re-opens it on demand.

// MARK: - Step model

/// One coach-mark card in the tour. Pure value type — carries only display
/// data so the catalog can be asserted in tests without booting any UI.
struct FeatureTourStep: Identifiable, Equatable {
    /// Stable identifier, also the dedupe / diff key.
    let id: String
    /// SF Symbol shown in the card's leading badge.
    let symbol: String
    /// Localization key for the card title (e.g. "Right-click for more").
    let titleKey: LocalizedStringKey
    /// Localization key for the explanatory body copy.
    let bodyKey: LocalizedStringKey
    /// Optional chord rendered as a glyph pill (e.g. "␣", "⌘F"). `nil` for
    /// steps whose gesture isn't a keyboard shortcut (right-click).
    let shortcut: String?

    /// Raw title key string, retained separately from `titleKey` so tests can
    /// assert catalog integrity without reflecting into the opaque
    /// `LocalizedStringKey` type. Mirrors the `AppShortcuts.Shortcut`
    /// `nameKeyString` / `nameKey` split.
    let titleKeyString: String
}

/// The first-run feature tour catalog.
///
/// Static data, so it can be rendered (and tested) without a live
/// `AppModel`. Adding a step is a single entry here; the overlay's
/// progress dots, Next/Done button label, and step counter all derive from
/// `steps.count`, so nothing else needs touching.
enum FeatureTour {
    /// Four cards, in presentation order. Each names a feature that's real
    /// and wired today (see `LyrebirdCommands` for the Space / ⌘F / ⌘⌥P
    /// bindings and the various `*ContextMenu` components for right-click).
    static let steps: [FeatureTourStep] = [
        FeatureTourStep(
            id: "right_click",
            symbol: "cursorarrow.click.2",
            titleKey: "tour.right_click.title",
            bodyKey: "tour.right_click.body",
            shortcut: nil,
            titleKeyString: "tour.right_click.title"
        ),
        FeatureTourStep(
            id: "space_play_pause",
            symbol: "playpause.fill",
            titleKey: "tour.space.title",
            bodyKey: "tour.space.body",
            shortcut: "␣",
            titleKeyString: "tour.space.title"
        ),
        FeatureTourStep(
            id: "search",
            symbol: "magnifyingglass",
            titleKey: "tour.search.title",
            bodyKey: "tour.search.body",
            shortcut: "⌘F",
            titleKeyString: "tour.search.title"
        ),
        FeatureTourStep(
            id: "mini_player",
            symbol: "pip.fill",
            titleKey: "tour.mini_player.title",
            bodyKey: "tour.mini_player.body",
            shortcut: "⌘⌥P",
            titleKeyString: "tour.mini_player.title"
        ),
    ]
}

// MARK: - Seen-persistence

/// Records whether the first-run tour has already been shown.
///
/// Wraps a `UserDefaults` instance so the production path keys against the
/// standard domain (same channel `@AppStorage` reads) while tests can inject
/// an isolated suite and assert the persisted flag without polluting the real
/// app's preferences — the same isolation pattern `MiniPlayerStateTests` uses
/// for the always-on-top preference.
///
/// The store deliberately owns only the *primitive* read/write of the flag.
/// Deciding *whether* to show the tour (first-run vs. an explicit Help ▸ Show
/// Tour re-open) lives in `FeatureTourOverlay`, which composes this with the
/// app's session/first-run state.
struct FeatureTourSeenStore {
    /// Stable on-disk key. Must not be renamed without a migration — a rename
    /// re-shows the tour to every existing user. Namespaced under `tour.` to
    /// sit alongside the other feature-scoped `@AppStorage` keys.
    static let seenKey = "tour.firstRunSeen"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the tour has been shown at least once.
    var hasSeen: Bool {
        defaults.bool(forKey: Self.seenKey)
    }

    /// Mark the tour as shown so it doesn't auto-appear on the next launch.
    func markSeen() {
        defaults.set(true, forKey: Self.seenKey)
    }

    /// Clear the flag. Used by tests; the production re-open path goes through
    /// `AppModel.presentFeatureTour()` instead, which shows the tour without
    /// disturbing the persisted first-run flag.
    func reset() {
        defaults.removeObject(forKey: Self.seenKey)
    }
}

// MARK: - Overlay

/// The dismissible coach-mark overlay. A single centered callout card that
/// advances through `FeatureTour.steps`, dimming the rest of the shell behind
/// it. Esc or "Skip" closes immediately; the last step's button reads "Done".
///
/// Closing always marks the tour seen (so it never re-auto-appears) and clears
/// the presentation flag via `onClose`, which the host (`MainShell`) wires to
/// `AppModel`. Honours Reduce Motion by dropping the card's slide transition.
struct FeatureTourOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Invoked when the tour finishes or is skipped. The host clears whatever
    /// flag drove presentation; the seen flag is persisted here before this
    /// fires so a host that only flips a transient flag still records it.
    let onClose: () -> Void

    /// Persistence wrapper. Defaulted so the production overlay records into
    /// the standard domain; tests construct the overlay with an isolated
    /// store. The card view never reads this except to `markSeen()` on close.
    var seenStore = FeatureTourSeenStore()

    @State private var index: Int = 0

    private var steps: [FeatureTourStep] { FeatureTour.steps }
    private var step: FeatureTourStep { steps[min(index, steps.count - 1)] }
    private var isLast: Bool { index >= steps.count - 1 }
    private var isFirst: Bool { index == 0 }

    var body: some View {
        ZStack {
            // Scrim. Tapping outside the card skips the tour, matching the
            // command palette's tap-to-dismiss feel.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)

            card
                .frame(width: 360)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                .id(step.id)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: index)
        // Esc closes the tour. A hidden, zero-frame cancel button is the
        // standard SwiftUI way to bind `.escape` without an explicit key
        // handler; `.cancelAction` also routes Esc to it.
        .background(
            Button(action: close) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .hidden()
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(Text("tour.a11y.container"))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text(step.titleKey)
                    .font(Theme.font(20, weight: .bold))
                    .foregroundStyle(Theme.ink)

                Text(step.bodyKey)
                    .font(Theme.font(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(24)
        .background(Theme.bgAlt)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 18)
    }

    private var header: some View {
        HStack(alignment: .top) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: step.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)

            if let shortcut = step.shortcut {
                Spacer()
                Text(shortcut)
                    .font(Theme.font(13, weight: .bold))
                    .monospaced()
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .accessibilityLabel(Text("tour.a11y.shortcut \(shortcut)"))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Step dots — same affordance as the onboarding `ProgressDots`,
            // reproduced here so this overlay stays self-contained.
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Theme.accent : Theme.border)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("tour.a11y.progress \(index + 1) \(steps.count)"))

            Spacer()

            if !isFirst {
                Button(action: back) {
                    Text("tour.back")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("tour.back"))
            }

            Button(action: advance) {
                Text(isLast ? "tour.done" : "tour.next")
                    .font(Theme.font(13, weight: .bold))
                    .frame(minWidth: 72)
                    .frame(height: 34)
                    .padding(.horizontal, 14)
                    .foregroundStyle(Theme.ink)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(isLast ? Text("tour.done") : Text("tour.next"))
        }
        .overlay(alignment: .center) {
            // "Skip" sits centered under the dots only while there's still a
            // step left to skip; on the last card "Done" already closes.
            if !isLast {
                Button(action: close) {
                    Text("tour.skip")
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .offset(y: 30)
                .accessibilityLabel(Text("tour.skip"))
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        if isLast {
            close()
        } else {
            index += 1
        }
    }

    private func back() {
        guard !isFirst else { return }
        index -= 1
    }

    /// Persist the seen flag and hand control back to the host. Idempotent —
    /// marking an already-seen tour seen again is a harmless no-op.
    private func close() {
        seenStore.markSeen()
        onClose()
    }
}

#Preview("Feature tour") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        FeatureTourOverlay(onClose: {})
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.dark)
}
