import AVKit
import Observation
import SwiftUI

/// SwiftUI wrapper around `AVRoutePickerView` so the `PlayerBar` can offer the
/// system AirPlay / output-route picker without dropping to AppKit at the call
/// site. Tapping the button presents the system's standard list of AirPlay
/// receivers and output targets — the same popover Music.app shows.
///
/// Scope is **system audio routing only** (#326): this is the OS route picker,
/// not Jellyfin SyncPlay / remote-session casting (tracked separately). It does
/// not need a Jellyfin core FFI — `AVRoutePickerView` talks straight to the
/// AirPlay / Core Audio routing stack.
///
/// Styled to sit flush in the transport row next to the volume slider: the
/// chrome border is dropped (`isRoutePickerButtonBordered = false`) so the
/// glyph reads as a bare transport control like the shuffle / repeat buttons,
/// and the button colors track Lyrebird's ink tokens — `ink2` at rest, the
/// brighter `ink` when a non-local route is active — instead of the default
/// system blue. Mirrors the `VisualEffectView` representable pattern.
struct AirPlayRoutePicker: NSViewRepresentable {
    /// Resting glyph color. Matches the volume speaker glyph beside it.
    var restingTint: Color = Theme.ink2
    /// Glyph color while a route is engaged. Lifts to the brighter ink so an
    /// active AirPlay destination reads as "on", echoing how the transport
    /// row tints shuffle / repeat with the accent when engaged.
    var activeTint: Color = Theme.ink

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        Self.apply(colorPlan, to: view)
        // The route glyph is square; pin it to the transport row's icon
        // footprint so it lines up with the other 28×28 controls.
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        Self.apply(colorPlan, to: nsView)
    }

    /// The styling policy derived from this picker's tints.
    var colorPlan: ButtonColorPlan {
        ButtonColorPlan(restingTint: restingTint, activeTint: activeTint)
    }

    /// Apply a `ButtonColorPlan` to a live `AVRoutePickerView`. Factored out so
    /// `makeNSView` and `updateNSView` can't drift, and so a smoke test can
    /// drive the AVKit wrapper directly (no SwiftUI `Context` needed) and
    /// assert the styling actually lands on a realized view.
    static func apply(_ plan: ButtonColorPlan, to view: AVRoutePickerView) {
        view.isRoutePickerButtonBordered = plan.bordered
        for state in plan.states {
            view.setRoutePickerButtonColor(NSColor(plan.color(for: state)), for: state.avState)
        }
    }

    /// Pure description of how the picker button is painted across its four
    /// `AVRoutePickerView.ButtonState`s. Splitting the policy out from the live
    /// AppKit view keeps the resting-vs-active color decision deterministic and
    /// testable without realizing an `AVRoutePickerView` (a window-server
    /// dependency a headless test run doesn't have) — the same pure-helper
    /// approach `MenuBarNowPlaying` uses for its transport-icon decision.
    struct ButtonColorPlan: Equatable {
        var restingTint: Color
        var activeTint: Color
        /// Borderless so the glyph reads as a bare transport control, not a
        /// bezeled push button, next to the volume slider.
        var bordered: Bool = false

        /// The four button states the route picker paints, in a stable order.
        var states: [ButtonState] { ButtonState.allCases }

        /// Color for a given button state. `normal` / `normalHighlighted` use
        /// the resting tint (no route, or local output); `active` /
        /// `activeHighlighted` use the brighter active tint (a route engaged).
        func color(for state: ButtonState) -> Color {
            switch state {
            case .normal, .normalHighlighted:
                return restingTint
            case .active, .activeHighlighted:
                return activeTint
            }
        }
    }

    /// Local mirror of `AVRoutePickerView.ButtonState` so the color policy can
    /// be enumerated and asserted without importing AVKit into a test that only
    /// cares about the decision, and so `allCases` is guaranteed exhaustive.
    enum ButtonState: CaseIterable {
        case normal
        case normalHighlighted
        case active
        case activeHighlighted

        var avState: AVRoutePickerView.ButtonState {
            switch self {
            case .normal: return .normal
            case .normalHighlighted: return .normalHighlighted
            case .active: return .active
            case .activeHighlighted: return .activeHighlighted
            }
        }
    }
}

// MARK: - Route detection

/// Observable wrapper around `AVRouteDetector` that publishes whether multiple
/// audio output routes are available (i.e. at least one AirPlay / Bluetooth
/// destination besides the local speaker). Views observe this to auto-hide the
/// `AirPlayRoutePicker` button when no alternate routes are reachable — matching
/// the behaviour Apple Music uses to avoid showing a dead picker (#38).
///
/// Enable detection once on app start by setting
/// `RouteDetector.shared.isEnabled = true`; it survives for the app lifetime.
/// Detection scans for nearby wireless receivers so it is intentionally a
/// singleton rather than one instance per player-bar instance.
@MainActor
@Observable
final class RouteDetector {
    /// Shared singleton. Enable once from the app's root scene or AppModel init.
    static let shared = RouteDetector()

    /// True when at least one non-local audio output (AirPlay, Bluetooth) is
    /// within range. Mirrors `AVRouteDetector.multipleRoutesDetected`. The
    /// `AirPlayRoutePicker` button in the transport bar is hidden when false —
    /// the same auto-hide contract Apple Music applies.
    private(set) var multipleRoutesDetected: Bool = false

    /// Forward `isRouteDetectionEnabled` to the underlying detector. Turn on
    /// once at startup; turning off stops the radio scan and resets
    /// `multipleRoutesDetected` to `false`.
    var isEnabled: Bool {
        get { detector.isRouteDetectionEnabled }
        set { detector.isRouteDetectionEnabled = newValue }
    }

    private let detector = AVRouteDetector()
    /// Registration token from `NotificationCenter.addObserver(forName:…)`.
    /// Marked `nonisolated(unsafe)` so Swift's strict-concurrency checker does
    /// not flag the `deinit` (which runs off the main actor) accessing a
    /// `@MainActor`-isolated property. The token is written exactly once in
    /// `init` (on the main actor, since `shared` initialises on first access
    /// and singletons evaluate their initialiser on the calling actor) and read
    /// only in `deinit` after the object's lifetime ends — no concurrent access
    /// is possible, so the suppression is safe. A singleton that lives for the
    /// app's lifetime makes `deinit` unreachable in practice, but the compiler
    /// still requires a conformant implementation.
    nonisolated(unsafe) private var observerToken: NSObjectProtocol?

    private init() {
        // Mirror the initial value synchronously before registering the
        // observer so the UI doesn't flash "hidden" on the first layout pass.
        multipleRoutesDetected = detector.multipleRoutesDetected

        observerToken = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange,
            object: detector,
            queue: .main
        ) { [weak self] _ in
            // The notification fires on the main queue (we requested `.main`
            // above) so the MainActor property write is safe without a
            // detached task.
            self?.multipleRoutesDetected = self?.detector.multipleRoutesDetected ?? false
        }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
