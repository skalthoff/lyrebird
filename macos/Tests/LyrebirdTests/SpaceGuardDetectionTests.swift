import AppKit
import XCTest

@testable import Lyrebird

/// Coverage for the space-bar text-field guard (#585).
///
/// The detection logic is factored into `SpaceGuardDetection` so the
/// "is this a bare space?" and "is the first responder an editable text
/// control?" decisions can be verified directly. `SpaceGuardMonitor`'s
/// ref-counting is exercised so we know exactly one process-level monitor
/// exists no matter how many guarded views mount.
final class SpaceGuardDetectionTests: XCTestCase {

    // MARK: isBareSpace

    func testBareSpaceIsDetected() {
        XCTAssertTrue(SpaceGuardDetection.isBareSpace(keyCode: 49, modifierFlags: []))
    }

    func testNonSpaceKeyIsRejected() {
        XCTAssertFalse(SpaceGuardDetection.isBareSpace(keyCode: 0, modifierFlags: []))
    }

    func testModifiedSpaceIsRejected() {
        // Command/Option/Control/Shift + Space are deliberate combos and must
        // pass through untouched (e.g. ⌃Space for input-source switching).
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertFalse(
                SpaceGuardDetection.isBareSpace(keyCode: 49, modifierFlags: flag),
                "space + \(flag) should not be treated as a bare space"
            )
        }
    }

    func testSpaceIgnoresNonInputModifierFlags() {
        // CapsLock / numeric-pad / function bits aren't in the intercept set,
        // so a space carrying only those is still a bare space.
        XCTAssertTrue(
            SpaceGuardDetection.isBareSpace(keyCode: 49, modifierFlags: [.capsLock])
        )
    }

    // MARK: editableTextView — window-free cases

    @MainActor
    func testStandaloneEditableTextViewIsDetected() {
        let window = NSWindow()
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40))
        textView.isEditable = true
        XCTAssertTrue(SpaceGuardDetection.editableTextView(for: textView, in: window) === textView)
    }

    @MainActor
    func testNonEditableTextViewIsRejected() {
        let window = NSWindow()
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40))
        textView.isEditable = false
        XCTAssertNil(SpaceGuardDetection.editableTextView(for: textView, in: window))
    }

    @MainActor
    func testNonTextResponderIsRejected() {
        let window = NSWindow()
        // A plain button is a control but not editable text — space must pass
        // through so it can activate the button / fire the transport shortcut.
        let button = NSButton(frame: .init(x: 0, y: 0, width: 40, height: 20))
        XCTAssertNil(SpaceGuardDetection.editableTextView(for: button, in: window))
    }

    @MainActor
    func testNonEditableTextFieldIsRejected() {
        let window = NSWindow()
        let label = NSTextField(labelWithString: "read-only")
        XCTAssertNil(SpaceGuardDetection.editableTextView(for: label, in: window))
    }

    // MARK: editableTextView — field-editor path (the L101 broadening)

    /// When a field-style control owns the first responder, detection must
    /// resolve its shared field editor. This is the case that the old
    /// NSTextField-delegate check missed for NSSearchField. We exercise both a
    /// plain editable NSTextField and an NSSearchField to prove the single
    /// NSTextField-subclass cast covers the search field too.
    @MainActor
    func testEditableFieldControlsResolveFieldEditor() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let field = NSTextField(string: "")
        let search = NSSearchField(string: "")
        let container = NSView(frame: .init(x: 0, y: 0, width: 200, height: 60))
        container.addSubview(field)
        container.addSubview(search)
        window.contentView = container

        for control in [field, search] {
            XCTAssertTrue(
                window.makeFirstResponder(control),
                "could not focus \(type(of: control)) — skipping field-editor assertion"
            )
            // The active field editor for the focused control should be the
            // editable NSTextView we route the space into.
            let resolved = SpaceGuardDetection.editableTextView(for: window.firstResponder!, in: window)
            XCTAssertNotNil(
                resolved,
                "\(type(of: control)) should resolve to an editable field editor"
            )
            XCTAssertTrue(resolved?.isEditable ?? false)
        }
    }

    // MARK: SpaceGuardMonitor ref-counting

    @MainActor
    func testMonitorIsRefCountedAcrossHosts() {
        let monitor = SpaceGuardMonitor.shared
        // Other tests in the suite may have mounted guarded views; capture the
        // baseline so this test is order-independent.
        let baseline = monitor.activeRetainCount

        monitor.retain()
        XCTAssertEqual(monitor.activeRetainCount, baseline + 1)
        XCTAssertTrue(monitor.isInstalled, "first retain should install the monitor")

        monitor.retain()
        XCTAssertEqual(monitor.activeRetainCount, baseline + 2)
        XCTAssertTrue(monitor.isInstalled, "a second host must not install a second monitor")

        monitor.release()
        XCTAssertEqual(monitor.activeRetainCount, baseline + 1)
        XCTAssertTrue(monitor.isInstalled, "monitor stays installed while a host remains")

        monitor.release()
        XCTAssertEqual(monitor.activeRetainCount, baseline)
        // Only assert removal when nothing else holds the monitor.
        if baseline == 0 {
            XCTAssertFalse(monitor.isInstalled, "last release should remove the monitor")
        }
    }

    @MainActor
    func testMonitorReleaseBelowZeroIsSafe() {
        let monitor = SpaceGuardMonitor.shared
        let baseline = monitor.activeRetainCount
        // Unbalanced release must not drive the count negative or crash.
        monitor.release()
        XCTAssertGreaterThanOrEqual(monitor.activeRetainCount, 0)
        // Restore baseline if we actually decremented a pre-existing retain.
        if monitor.activeRetainCount < baseline {
            monitor.retain()
        }
        XCTAssertEqual(monitor.activeRetainCount, baseline)
    }
}
