import AVKit
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
