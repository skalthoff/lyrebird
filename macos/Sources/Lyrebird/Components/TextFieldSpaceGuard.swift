import AppKit
import SwiftUI

// MARK: - #585: Space-bar key guard for focused TextFields
//
// SwiftUI's `CommandMenu` registers shortcuts as NSMenuItem key equivalents,
// which `NSMenu.performKeyEquivalent` processes *before* forwarding unhandled
// events to the first responder. This means the global Play/Pause ⎵ shortcut
// fires even when the user is typing in a TextField.
//
// The fix: install a process-level `NSEvent` local monitor. When a Space key-
// down arrives and the first responder is an `NSTextField` (or its cell
// subclass), we let the event reach the text field directly by posting it
// through `NSApp.sendEvent` after the command handler has already consumed
// the original. We do this by detecting the situation in the monitor and
// inserting a literal space via the text field's text-input API so the
// character lands without a second `sendEvent` round-trip that might loop.
//
// Applied via `.spaceKeyGuardForTextField()` on any view that hosts a
// focused TextField (Sidebar, SearchView, CommandPalette).

extension View {
    /// Installs the space-key guard for the lifetime of this view.
    ///
    /// Use this on the nearest common ancestor of any `TextField` that should
    /// receive space-bar input even when the global Play/Pause ⎵ shortcut is
    /// registered. The guard is a no-op when no text field has first-responder
    /// status.
    func spaceKeyGuardForTextField() -> some View {
        self.background(SpaceKeyGuardHost())
    }
}

/// Zero-size `NSViewRepresentable` that installs / removes the `NSEvent`
/// local monitor for its parent view's lifetime. Using a representable
/// rather than an `onAppear`/`onDisappear` pair avoids retain-cycle risks
/// that come with capturing a monitor token in a SwiftUI closure.
private struct SpaceKeyGuardHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = .zero
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            // `.keyDown` at the default priority (0) fires after the main
            // NSApplication `sendEvent` has already given `NSMenu` a first
            // crack at the event. We need to catch it *before* that, so we
            // use a window-level event monitor via addLocalMonitorForEvents
            // which intercepts events before they reach NSApp.sendEvent.
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

        /// Returns `nil` if the event was consumed (space delivered directly
        /// to the active text field), or the original event if it should
        /// continue normal dispatch.
        private func handle(event: NSEvent) -> NSEvent? {
            // Only intercept bare space (no modifier flags that would
            // indicate a deliberate key combo).
            guard
                event.keyCode == 49, // kVK_Space
                event.modifierFlags
                    .intersection([.command, .option, .control, .shift])
                    .isEmpty
            else {
                return event
            }

            // Check whether the first responder is an NSTextField or one of
            // its editor variants. SwiftUI TextField renders as NSTextField;
            // when focused, the field editor (NSTextView) becomes first
            // responder with the NSTextField as the field editor's delegate.
            guard let window = NSApp.keyWindow,
                  let responder = window.firstResponder else { return event }

            let isTextField: Bool
            if responder is NSTextField {
                isTextField = true
            } else if let tv = responder as? NSTextView, tv.delegate is NSTextField {
                isTextField = true
            } else {
                isTextField = false
            }

            guard isTextField else { return event }

            // Deliver the space directly via the responder chain text-input
            // API so the character is inserted at the current insertion
            // point without a second sendEvent round-trip. Returning nil
            // prevents the event from reaching NSApp.sendEvent, which would
            // otherwise hand it to NSMenu again.
            responder.insertText(" ")
            return nil
        }
    }
}
