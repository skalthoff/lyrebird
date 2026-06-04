import AppKit
import SwiftUI

// MARK: - #585: Space-bar key guard for focused TextFields
//
// SwiftUI's `CommandMenu` registers shortcuts as NSMenuItem key equivalents,
// which `NSMenu.performKeyEquivalent` processes *before* forwarding unhandled
// events to the first responder. This means the global Play/Pause ⎵ shortcut
// (LyrebirdApp's Playback menu, `.keyboardShortcut(.space, modifiers: [])`)
// fires even when the user is typing in a TextField, eating the space.
//
// The fix: a single process-level `NSEvent` local monitor. The monitor runs
// during event dispatch *before* `NSApp.sendEvent` hands the key equivalent
// to `NSMenu`, so when a bare Space arrives while an editable text control
// owns the first responder we:
//
//   1. route the event through the field editor's `interpretKeyEvents(_:)`,
//      which is AppKit's real text-input entry point — it preserves IME /
//      marked-text composition, undo coalescing, and selection-replacement
//      semantics (unlike a raw `insertText(" ")`), and
//   2. return `nil` so the event never reaches the menu and the Play/Pause
//      equivalent doesn't also fire.
//
// When the first responder is *not* an editable text control the event is
// returned unchanged so normal dispatch (including the Play/Pause shortcut)
// proceeds.
//
// Only one monitor exists no matter how many guarded views are mounted: each
// `.spaceKeyGuardForTextField()` host retains the shared monitor on appear
// and releases it on disappear (see `SpaceGuardMonitor`). Earlier revisions
// installed one app-global monitor *per host*, so every guarded field
// multiplied the keyDown handlers firing across the whole app.
//
// Applied via `.spaceKeyGuardForTextField()` on any view that hosts a
// focused TextField (Sidebar, SearchView, CommandPalette, InstantMixSheet).

extension View {
    /// Installs the space-key guard for the lifetime of this view.
    ///
    /// Use this on the nearest common ancestor of any `TextField` that should
    /// receive space-bar input even when the global Play/Pause ⎵ shortcut is
    /// registered. The guard is a no-op when no editable text control has
    /// first-responder status. The underlying monitor is shared and
    /// ref-counted, so applying this on several views installs exactly one
    /// process-level monitor.
    func spaceKeyGuardForTextField() -> some View {
        self.background(SpaceKeyGuardHost())
    }
}

/// Zero-size `NSViewRepresentable` that retains / releases the shared
/// `NSEvent` local monitor for its parent view's lifetime. Using a
/// representable rather than an `onAppear`/`onDisappear` pair avoids
/// retain-cycle risks that come with capturing a monitor token in a SwiftUI
/// closure.
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

    /// Holds a single retain on the shared monitor. Balancing
    /// `install()` / `remove()` keeps the ref count correct even if SwiftUI
    /// re-creates the representable. Main-actor isolated because the shared
    /// monitor is, and representable lifecycle runs on the main thread.
    @MainActor
    final class Coordinator {
        private var retained = false

        func install() {
            guard !retained else { return }
            retained = true
            SpaceGuardMonitor.shared.retain()
        }

        func remove() {
            guard retained else { return }
            retained = false
            SpaceGuardMonitor.shared.release()
        }
    }
}

/// Process-wide, ref-counted owner of the single `.keyDown` local monitor.
///
/// The first guarded host to mount installs the monitor; the last to unmount
/// removes it. All access is funnelled through the main actor (guarded hosts
/// appear/disappear on the main thread, and the monitor closure runs on the
/// main thread), so a plain counter is sufficient — no extra locking.
@MainActor
final class SpaceGuardMonitor {
    static let shared = SpaceGuardMonitor()

    private var monitor: Any?
    private var refCount = 0

    private init() {}

    /// Number of live retains. Exposed for tests.
    var activeRetainCount: Int { refCount }

    /// Whether the underlying `NSEvent` monitor is currently installed.
    /// Exposed for tests.
    var isInstalled: Bool { monitor != nil }

    func retain() {
        refCount += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            SpaceGuardMonitor.handle(event: event)
        }
    }

    func release() {
        guard refCount > 0 else { return }
        refCount -= 1
        guard refCount == 0, let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }

    /// Returns `nil` if the event was consumed (space routed straight to the
    /// active text control's field editor), or the original event if it
    /// should continue normal dispatch.
    static func handle(event: NSEvent) -> NSEvent? {
        guard SpaceGuardDetection.isBareSpace(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            return event
        }
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder else { return event }

        // Resolve the editable text view (the field editor for NSTextField &
        // its subclasses — search / combo / secure fields — or a standalone
        // editable NSTextView) that should receive the space.
        guard let textView = SpaceGuardDetection.editableTextView(for: responder, in: window) else {
            return event
        }

        // Route through AppKit's text-input pipeline so IME composition,
        // undo coalescing, and selection-replacement all behave exactly as
        // they would for a key that reached the field editor normally. Then
        // swallow the event so the menu's Play/Pause equivalent can't fire.
        textView.interpretKeyEvents([event])
        return nil
    }
}

/// Pure detection logic for the space guard, factored out so the
/// "is this a bare space?" and "is the first responder an editable text
/// control?" decisions can be unit-tested without a live window server.
enum SpaceGuardDetection {
    /// `kVK_Space`.
    static let spaceKeyCode: UInt16 = 49

    /// True for an unmodified Space (any of Command/Option/Control/Shift set
    /// means a deliberate combo we shouldn't intercept).
    static func isBareSpace(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == spaceKeyCode
            && modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty
    }

    /// The editable `NSTextView` that should receive a guarded space when
    /// `responder` owns the first responder, or `nil` when the responder
    /// isn't an editable text control.
    ///
    /// While editing, the first responder is the field editor (an
    /// `NSTextView`) shared by the focused `NSTextField` / `NSSearchField` /
    /// `NSComboBox` / `NSSecureTextField`; a standalone editable text area is
    /// itself an `NSTextView`. We therefore accept any editable `NSTextView`
    /// directly, and fall back to the window's field editor when the control
    /// itself is first responder (e.g. just before its editor is installed).
    /// Detection is by `isEditable`, not by hard-coding a delegate class, so
    /// search / combo / secure fields and bare text views are all covered.
    static func editableTextView(for responder: NSResponder, in window: NSWindow) -> NSTextView? {
        if let textView = responder as? NSTextView {
            return textView.isEditable ? textView : nil
        }
        // NSSearchField / NSComboBox / NSSecureTextField are all NSTextField
        // subclasses, so this single cast covers every editable field-style
        // control when the control itself (not its field editor) is the
        // first responder.
        if let field = responder as? NSTextField, field.isEditable {
            if let editor = window.fieldEditor(false, for: field) as? NSTextView,
               editor.isEditable {
                return editor
            }
        }
        return nil
    }
}
