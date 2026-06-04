import AppKit
import SwiftUI

/// Full-screen chrome handling for the main window (#20).
///
/// The main `WindowGroup` runs with `.windowStyle(.hiddenTitleBar)` +
/// `.windowToolbarStyle(.unifiedCompact)`, which flips
/// `titlebarAppearsTransparent` on and adds `.fullSizeContentView` so the
/// sidebar/content flow edge-to-edge under the traffic lights (see
/// `LyrebirdApp`). That layout is right in a windowed frame, but on the
/// full-screen transition it leaves two rough edges:
///
///   1. The unified toolbar + menu bar stay pinned at the top of the
///      full-screen space, eating vertical room the content should own.
///   2. The transparent title bar keeps a `fullSizeContentView` inset, so the
///      content sits a hair below where the now-absent traffic lights were
///      rather than filling the space cleanly.
///
/// macOS gives no `Scene` hook for either, so — exactly like
/// `MiniPlayerWindowConfigurator` reaches the host `NSWindow` for the mini
/// player's borderless chrome — we bridge through an invisible
/// `NSViewRepresentable` (`FullScreenChromeObserver`) mounted at the root.
/// It watches `NSWindow.willEnterFullScreenNotification` /
/// `willExitFullScreenNotification` for *its own* host window and applies the
/// chrome the pure `FullScreenChrome` reducer decides for each phase:
///
///   * **Enter**: request `[.autoHideToolbar, .autoHideMenuBar]` so the
///     unified toolbar and menu bar slide away and reveal on a top-edge
///     hover (the standard full-screen reveal), and drop the transparent
///     title bar so the content fills the full-screen surface without the
///     windowed inset.
///   * **Exit**: clear the presentation options back to `.default` and
///     restore `titlebarAppearsTransparent` so the windowed
///     hidden-title-bar layout returns intact.
///
/// All of the decision logic lives in `FullScreenChrome` so the chrome state
/// machine is unit-testable headlessly — realizing a live full-screen
/// `NSWindow` needs a window-server connection a CI run doesn't have.
enum FullScreenChrome {
    /// Which chrome phase the host window is in. Driven by the full-screen
    /// enter/exit notifications; `.windowed` is the resting state.
    enum Phase: Equatable {
        case windowed
        case fullScreen
    }

    /// The concrete chrome to apply for a phase. Split out of the AppKit
    /// side-effects so the mapping is a pure function and can be asserted
    /// without a window server.
    struct Decision: Equatable {
        /// Application presentation options to install. In full-screen this
        /// auto-hides the toolbar + menu bar (they reveal on a top-edge
        /// hover); windowed it's `.default` (empty) so the normal menu bar
        /// and toolbar stay put.
        var presentationOptions: NSApplication.PresentationOptions

        /// Whether the host window's title bar should be transparent. The
        /// hidden-title-bar windowed layout wants this `true` so content flows
        /// under the traffic lights; full-screen wants it `false` so the
        /// `fullSizeContentView` inset collapses and the content fills cleanly.
        var titlebarAppearsTransparent: Bool
    }

    /// Pure reducer: map a chrome `phase` to the `Decision` the observer
    /// applies to `NSApp` + the host `NSWindow`.
    ///
    /// Contract:
    ///   * `.fullScreen` -> auto-hide toolbar + menu bar, opaque title bar.
    ///   * `.windowed`   -> no presentation overrides, transparent title bar
    ///     (the `.hiddenTitleBar` resting look).
    ///
    /// Side-effect-free and allocation-free beyond the returned value; the
    /// observer owns all AppKit mutation and feeds the phase in.
    static func decide(phase: Phase) -> Decision {
        switch phase {
        case .fullScreen:
            return Decision(
                presentationOptions: [.autoHideToolbar, .autoHideMenuBar],
                titlebarAppearsTransparent: false
            )
        case .windowed:
            return Decision(
                presentationOptions: [],
                titlebarAppearsTransparent: true
            )
        }
    }
}

/// Invisible `NSViewRepresentable` that observes the host window's full-screen
/// transitions and applies `FullScreenChrome`'s decision. Mounted as a
/// `.background` in `RootView` so it contributes no visual element of its own —
/// the same one-shot AppKit-bridge shape `MiniPlayerWindowConfigurator` uses.
///
/// Observation is scoped to the *specific* host window (the notification's
/// `object`), not all windows, so the detached mini player / preferences /
/// shortcuts windows entering full-screen never drive the main window's chrome.
struct FullScreenChromeObserver: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't attached to a window yet during `makeNSView`
        // (`view.window` is nil until SwiftUI mounts it), so resolve the host
        // window on the next runloop tick — the same deferral
        // `MiniPlayerWindowConfigurator` relies on.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // If SwiftUI moves the view to a different window (rare, but possible
        // across scene rebuilds), re-target the observers at the new host.
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Owns the notification observers + the host-window weak reference, and
    /// performs the AppKit mutation the reducer decides. A class (not the
    /// struct `NSViewRepresentable`) so the observers have a stable lifetime
    /// across SwiftUI re-evaluations.
    final class Coordinator {
        private weak var window: NSWindow?
        private var enterObserver: NSObjectProtocol?
        private var exitObserver: NSObjectProtocol?

        /// Begin observing full-screen transitions for `window`. Idempotent:
        /// re-attaching to the same window is a no-op; attaching to a new one
        /// tears down the old observers first.
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window

            let center = NotificationCenter.default
            enterObserver = center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.apply(phase: .fullScreen)
            }
            exitObserver = center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.apply(phase: .windowed)
            }
        }

        /// Stop observing and clear any presentation overrides this observer
        /// installed, so a windowed teardown never leaves the menu bar hidden.
        func detach() {
            if let observer = enterObserver {
                NotificationCenter.default.removeObserver(observer)
                enterObserver = nil
            }
            if let observer = exitObserver {
                NotificationCenter.default.removeObserver(observer)
                exitObserver = nil
            }
            // Defensive: if we're torn down mid-full-screen, restore default
            // presentation so the app never gets stuck with a hidden menu bar.
            if NSApp.presentationOptions != [] {
                NSApp.presentationOptions = []
            }
            window = nil
        }

        /// Apply the reducer's decision for `phase` to `NSApp` + the host
        /// window. `NSApp.presentationOptions` only accepts auto-hide options
        /// while a full-screen window exists and must be cleared on exit, so
        /// the empty windowed set is exactly what AppKit wants back.
        private func apply(phase: FullScreenChrome.Phase) {
            let decision = FullScreenChrome.decide(phase: phase)
            NSApp.presentationOptions = decision.presentationOptions
            window?.titlebarAppearsTransparent = decision.titlebarAppearsTransparent
        }
    }
}
