import AppKit
import SwiftUI

// MARK: - Bare-Space Play/Pause (audit L383)
//
// The Play/Pause transport used to be bound to the bare Space key as a
// `CommandMenu` shortcut. SwiftUI registers `CommandMenu` shortcuts as
// `NSMenuItem` key equivalents, and `NSMenu.performKeyEquivalent` runs *before*
// the event reaches the first responder — so the global Play/Pause fired even
// while the user was typing a space into a `TextField` / `TextEditor`. SwiftUI
// does not auto-suppress a bare-key command while a text field is focused, and
// the per-view `spaceKeyGuardForTextField()` patch only covered the handful of
// screens it was applied to.
//
// The fix moves the bare-Space binding off the menu entirely and onto a single
// process-level `NSEvent` local monitor installed for the app's lifetime. The
// monitor reads the current first responder at key-press time (so there is no
// stale-state problem) and:
//   • lets the event through untouched when a text editor is focused, so Space
//     types a space exactly as it should; and
//   • otherwise consumes it and toggles playback.
//
// Because the shortcut is no longer an `NSMenuItem` key equivalent, NSMenu no
// longer swallows it ahead of text fields, which is the root cause the older
// guard was working around.

/// Pure decision for the bare-Space monitor, split out so it can be unit-tested
/// without constructing real AppKit responders. Given whether a track is
/// loaded and whether a text editor currently owns focus, decide what the
/// Space key should do.
enum SpaceKeyAction: Equatable {
    /// Toggle play/pause and swallow the event.
    case togglePlayback
    /// Let the event continue normal dispatch (e.g. type a literal space).
    case passThrough
}

enum PlayPauseSpaceDecision {
    /// - Parameters:
    ///   - hasModifiers: whether any of ⌘/⌥/⌃/⇧ were held (a deliberate combo,
    ///     never a transport toggle).
    ///   - isTextEditing: whether a text field / text view currently has focus.
    ///   - hasCurrentTrack: whether a track is loaded (nothing to toggle when not).
    static func decide(
        hasModifiers: Bool,
        isTextEditing: Bool,
        hasCurrentTrack: Bool
    ) -> SpaceKeyAction {
        // A modified Space (e.g. ⌥Space) is never a transport toggle — leave it
        // for whatever owns that combo.
        if hasModifiers { return .passThrough }
        // While editing text, Space must always type a space.
        if isTextEditing { return .passThrough }
        // Nothing loaded → nothing to toggle; don't eat the key.
        if !hasCurrentTrack { return .passThrough }
        return .togglePlayback
    }
}

extension View {
    /// Installs the app-wide bare-Space Play/Pause monitor for this view's
    /// lifetime. Mount once on a long-lived ancestor (`RootView`). The toggle
    /// fires only when a track is loaded and no text editor is focused.
    func playPauseSpaceMonitor(_ toggle: @escaping () -> Void,
                               hasCurrentTrack: @escaping () -> Bool) -> some View {
        self.background(
            PlayPauseSpaceMonitorHost(toggle: toggle, hasCurrentTrack: hasCurrentTrack)
        )
    }
}

/// Zero-size `NSViewRepresentable` that installs / removes the bare-Space
/// `NSEvent` local monitor for its parent view's lifetime. Mirrors the
/// representable-not-onAppear approach used by `SpaceKeyGuardHost` so the
/// monitor token is owned by the coordinator and torn down deterministically.
private struct PlayPauseSpaceMonitorHost: NSViewRepresentable {
    let toggle: () -> Void
    let hasCurrentTrack: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Keep the closures fresh so the monitor always sees current state.
        context.coordinator.toggle = toggle
        context.coordinator.hasCurrentTrack = hasCurrentTrack
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(toggle: toggle, hasCurrentTrack: hasCurrentTrack)
    }

    final class Coordinator {
        var toggle: () -> Void
        var hasCurrentTrack: () -> Bool
        private var monitor: Any?

        init(toggle: @escaping () -> Void, hasCurrentTrack: @escaping () -> Bool) {
            self.toggle = toggle
            self.hasCurrentTrack = hasCurrentTrack
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event: event) ?? event
            }
        }

        func remove() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        /// Returns `nil` when the Space was consumed (playback toggled), or the
        /// original event when it should continue normal dispatch.
        private func handle(event: NSEvent) -> NSEvent? {
            guard event.keyCode == 49 else { return event } // kVK_Space
            let hasModifiers = !event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty
            let action = PlayPauseSpaceDecision.decide(
                hasModifiers: hasModifiers,
                isTextEditing: Self.isTextEditing(),
                hasCurrentTrack: hasCurrentTrack()
            )
            switch action {
            case .passThrough:
                return event
            case .togglePlayback:
                toggle()
                return nil
            }
        }

        /// Whether the key window's first responder is an editable text surface.
        /// SwiftUI `TextField` renders as `NSTextField`; once focused the field
        /// editor (`NSTextView`) becomes first responder. `TextEditor` is a
        /// standalone editable `NSTextView`. Treat any editable text view as
        /// "editing" so Space types rather than toggling.
        private static func isTextEditing() -> Bool {
            guard
                let window = NSApp.keyWindow,
                let responder = window.firstResponder
            else { return false }
            if responder is NSTextField { return true }
            if let tv = responder as? NSTextView { return tv.isEditable }
            return false
        }
    }
}
