import AVKit
import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the `AirPlayRoutePicker` representable (#326): the resting-vs-
/// active button-color policy and the borderless transport styling.
///
/// The color decision is exercised through the pure `ButtonColorPlan` value so
/// the mapping is verified without realizing a live `AVRoutePickerView`, which
/// needs a window-server connection a headless test run doesn't have. A single
/// lightweight smoke test then confirms the representable's `makeNSView`
/// actually vends an `AVRoutePickerView` so the AVKit wrapper can't silently
/// rot — mirroring the static-helper approach in `MenuBarNowPlayingTests`.
final class AirPlayRoutePickerTests: XCTestCase {

    // MARK: - Button color policy

    func testRestingStatesUseRestingTint() {
        let plan = AirPlayRoutePicker.ButtonColorPlan(
            restingTint: .green,
            activeTint: .red
        )
        XCTAssertEqual(
            plan.color(for: .normal), .green,
            "at rest (no route / local output) the glyph uses the resting tint"
        )
        XCTAssertEqual(
            plan.color(for: .normalHighlighted), .green,
            "hovering the resting button keeps the resting tint"
        )
    }

    func testActiveStatesUseActiveTint() {
        let plan = AirPlayRoutePicker.ButtonColorPlan(
            restingTint: .green,
            activeTint: .red
        )
        XCTAssertEqual(
            plan.color(for: .active), .red,
            "with a route engaged the glyph lifts to the active tint"
        )
        XCTAssertEqual(
            plan.color(for: .activeHighlighted), .red,
            "hovering the active button keeps the active tint"
        )
    }

    func testPlanIsBorderlessByDefault() {
        let plan = AirPlayRoutePicker.ButtonColorPlan(
            restingTint: Theme.ink2,
            activeTint: Theme.ink
        )
        XCTAssertFalse(
            plan.bordered,
            "the picker reads as a bare transport control, not a bezeled button"
        )
    }

    // MARK: - Button-state enumeration

    func testButtonStatesAreExhaustive() {
        // All four AVRoutePickerView states must be covered so no state falls
        // through to AppKit's default (system blue) styling.
        XCTAssertEqual(
            AirPlayRoutePicker.ButtonState.allCases.count, 4,
            "the picker styles every AVRoutePickerView.ButtonState"
        )
    }

    func testButtonStateMapsToMatchingAVState() {
        XCTAssertEqual(AirPlayRoutePicker.ButtonState.normal.avState, .normal)
        XCTAssertEqual(AirPlayRoutePicker.ButtonState.normalHighlighted.avState, .normalHighlighted)
        XCTAssertEqual(AirPlayRoutePicker.ButtonState.active.avState, .active)
        XCTAssertEqual(AirPlayRoutePicker.ButtonState.activeHighlighted.avState, .activeHighlighted)
    }

    // MARK: - Representable smoke test

    /// Drive the AVKit wrapper end to end: build a live `AVRoutePickerView`,
    /// apply the picker's plan via the same entry point `makeNSView` /
    /// `updateNSView` use, and assert the styling lands. Realizing the view
    /// directly (rather than through `makeNSView(context:)`) avoids fabricating
    /// a `NSViewRepresentableContext`, which has no public initializer, while
    /// still exercising the real AVKit type and its `setRoutePickerButtonColor`
    /// surface so the wrapper can't silently rot against an SDK change.
    @MainActor
    func testApplyStylesRealRoutePickerView() {
        let view = AVRoutePickerView()
        // Start bordered so we can prove `apply` flips it off.
        view.isRoutePickerButtonBordered = true

        let plan = AirPlayRoutePicker().colorPlan
        AirPlayRoutePicker.apply(plan, to: view)

        XCTAssertFalse(
            view.isRoutePickerButtonBordered,
            "applying the plan leaves the realized picker borderless"
        )

        // The default picker tints rest with Theme.ink2 (a purple) and lift to
        // Theme.ink (white) when a route is engaged. Compare resolved sRGB
        // components rather than NSColor identity — both tokens are dynamic
        // `NSColor(name:)` providers whose `==` is unreliable, and AVKit may
        // normalize the color it stores. What must hold deterministically is
        // that the two states resolve to *different* colors, so the active
        // state is visibly distinct from rest.
        let resting = view.routePickerButtonColor(for: .normal).usingColorSpace(.sRGB)
        let active = view.routePickerButtonColor(for: .active).usingColorSpace(.sRGB)
        XCTAssertNotNil(resting, "resting tint resolves to an sRGB color")
        XCTAssertNotNil(active, "active tint resolves to an sRGB color")
        if let resting, let active {
            XCTAssertFalse(
                Self.sRGBEqual(resting, active),
                "active route tint must read distinctly from the resting tint"
            )
        }
    }

    /// Component-wise sRGB equality within a small tolerance — robust against
    /// the float round-tripping AVKit / NSColor do when storing a button color.
    private static func sRGBEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        let tol: CGFloat = 0.01
        return abs(a.redComponent - b.redComponent) < tol
            && abs(a.greenComponent - b.greenComponent) < tol
            && abs(a.blueComponent - b.blueComponent) < tol
            && abs(a.alphaComponent - b.alphaComponent) < tol
    }
}

// MARK: - RouteDetector

/// Coverage for the `RouteDetector` observable (#38): the singleton starts with
/// detection disabled and mirrors the underlying `AVRouteDetector` state.
///
/// We can't realistically observe an `AVRouteDetectorMultipleRoutesDetectedDidChange`
/// notification in a headless test run (there are no AirPlay devices to detect),
/// so this suite verifies the structural contract — initial state, the
/// `isEnabled` passthrough, and the singleton identity — without trying to fake
/// hardware.
@MainActor
final class RouteDetectorTests: XCTestCase {

    func testSharedIsSingleton() {
        XCTAssertTrue(
            RouteDetector.shared === RouteDetector.shared,
            "RouteDetector.shared must be a true singleton (same object reference)"
        )
    }

    func testInitialDetectionIsDisabled() {
        // The detector should be off at allocation time — scanning starts
        // only when `isEnabled` is explicitly set to `true` at app launch.
        // In a test process `RouteDetector.shared` hasn't had `isEnabled = true`
        // called, so `multipleRoutesDetected` must remain `false`.
        XCTAssertFalse(
            RouteDetector.shared.multipleRoutesDetected,
            "multipleRoutesDetected must be false before detection is enabled"
        )
    }

    func testIsEnabledReflectsState() {
        // Toggle on then off; the underlying AVRouteDetector mirrors the value.
        RouteDetector.shared.isEnabled = true
        XCTAssertTrue(RouteDetector.shared.isEnabled, "isEnabled must round-trip to true")
        RouteDetector.shared.isEnabled = false
        XCTAssertFalse(RouteDetector.shared.isEnabled, "isEnabled must round-trip to false")
    }
}
