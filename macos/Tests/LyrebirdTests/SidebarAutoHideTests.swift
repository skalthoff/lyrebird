import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the resizable / auto-hiding sidebar (#318).
///
/// SwiftUI exposes no public hook to introspect `columnVisibility` transitions
/// off a `some View` without booting a scene, so the behaviour lives in the
/// pure `SidebarAutoHide` reducer and is exercised here directly. A second
/// group asserts the structural wiring in `MainShell.swift` (read from source)
/// so a regression that detaches the reducer from the view — or drops the
/// drag-resize bounds — is caught here rather than in the field.
final class SidebarAutoHideTests: XCTestCase {

    // MARK: - Threshold reducer

    /// A wide window with the sidebar shown and no manual override is a no-op:
    /// the reducer returns `nil` (leave visibility untouched) and doesn't claim
    /// an auto-collapse it never made.
    func testWideWindowShownLeavesSidebarAlone() {
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold + 200,
            visibility: .all,
            state: SidebarAutoHide.State()
        )
        XCTAssertNil(decision.visibility)
        XCTAssertFalse(decision.state.didAutoCollapse)
        XCTAssertFalse(decision.state.userDidOverride)
    }

    /// Narrowing past the threshold collapses a shown sidebar and records that
    /// the collapse was automatic (so it's eligible for auto-restore later).
    func testNarrowWindowAutoCollapsesShownSidebar() {
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold - 100,
            visibility: .all,
            state: SidebarAutoHide.State()
        )
        XCTAssertEqual(decision.visibility, .detailOnly)
        XCTAssertTrue(decision.state.didAutoCollapse)
        XCTAssertFalse(decision.state.userDidOverride)
    }

    /// Widening past the threshold restores a sidebar that *we* auto-collapsed.
    func testWideningRestoresAutoCollapsedSidebar() {
        let collapsed = SidebarAutoHide.State(didAutoCollapse: true, userDidOverride: false)
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold + 100,
            visibility: .detailOnly,
            state: collapsed
        )
        XCTAssertEqual(decision.visibility, .all)
        XCTAssertFalse(decision.state.didAutoCollapse)
    }

    /// A sidebar already collapsed on a narrow window stays collapsed and the
    /// reducer doesn't retroactively claim it as an auto-collapse (which would
    /// make a later widen reopen a rail the reducer never closed).
    func testNarrowWindowAlreadyCollapsedIsNoOp() {
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold - 100,
            visibility: .detailOnly,
            state: SidebarAutoHide.State()
        )
        XCTAssertNil(decision.visibility)
        XCTAssertFalse(decision.state.didAutoCollapse)
    }

    /// A wide window with the sidebar shown but no recorded auto-collapse has
    /// nothing to restore — the reducer leaves it alone.
    func testWideWindowWithoutAutoCollapseDoesNotRestore() {
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold + 100,
            visibility: .all,
            state: SidebarAutoHide.State(didAutoCollapse: false, userDidOverride: false)
        )
        XCTAssertNil(decision.visibility)
    }

    // MARK: - Manual override never fights auto-hide

    /// Once the user has manually toggled the sidebar, narrowing the window
    /// must NOT auto-collapse it — the explicit choice wins.
    func testManualOverrideBlocksAutoCollapse() {
        let overridden = SidebarAutoHide.State(didAutoCollapse: false, userDidOverride: true)
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold - 200,
            visibility: .all,
            state: overridden
        )
        XCTAssertNil(decision.visibility, "Manual override must not be auto-collapsed")
        XCTAssertTrue(decision.state.userDidOverride, "Override flag must persist across width changes")
    }

    /// The fighting scenario: a user manually reveals the sidebar in a narrow
    /// window. The next width tick must not immediately re-collapse it.
    func testManualRevealInNarrowWindowIsNotReCollapsed() {
        // Manual toggle records the override and clears any auto-collapse.
        let afterToggle = SidebarAutoHide.registeringManualToggle(
            SidebarAutoHide.State(didAutoCollapse: true, userDidOverride: false)
        )
        XCTAssertTrue(afterToggle.userDidOverride)
        XCTAssertFalse(afterToggle.didAutoCollapse)

        // A subsequent width change at a narrow width leaves the rail shown.
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold - 50,
            visibility: .all,
            state: afterToggle
        )
        XCTAssertNil(decision.visibility)
    }

    /// Symmetric guard: a user who manually hid the sidebar isn't force-reopened
    /// when the window widens.
    func testManualHideOnWideWindowIsNotAutoRestored() {
        let overridden = SidebarAutoHide.State(didAutoCollapse: false, userDidOverride: true)
        let decision = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold + 300,
            visibility: .detailOnly,
            state: overridden
        )
        XCTAssertNil(decision.visibility, "A user-hidden sidebar must not be auto-restored")
    }

    // MARK: - Threshold boundary

    /// The boundary is inclusive on the collapse side (`<=`): a window exactly
    /// at the threshold collapses, and one a single point wider restores.
    func testThresholdBoundaryIsInclusiveOnCollapse() {
        let atThreshold = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold,
            visibility: .all,
            state: SidebarAutoHide.State()
        )
        XCTAssertEqual(atThreshold.visibility, .detailOnly,
                       "Width == threshold should collapse (inclusive boundary)")

        let justAbove = SidebarAutoHide.decide(
            width: SidebarAutoHide.collapseThreshold + 1,
            visibility: .detailOnly,
            state: SidebarAutoHide.State(didAutoCollapse: true, userDidOverride: false)
        )
        XCTAssertEqual(justAbove.visibility, .all,
                       "Width one point above threshold should restore")
    }

    /// The threshold is a sane positive width — a zero/negative or absurd value
    /// would either never auto-hide or always hide.
    func testCollapseThresholdIsReasonable() {
        XCTAssertGreaterThan(SidebarAutoHide.collapseThreshold, 252,
                             "Threshold must exceed the ideal sidebar width or it could never show both columns")
        XCTAssertLessThan(SidebarAutoHide.collapseThreshold, 1200,
                          "Threshold should trigger only on genuinely cramped windows")
    }

    // MARK: - Manual-toggle folding

    /// `registeringManualToggle` always lands in the "user owns it" state
    /// regardless of the prior bookkeeping.
    func testRegisteringManualToggleSetsOverrideAndClearsAutoCollapse() {
        for prior in [
            SidebarAutoHide.State(didAutoCollapse: false, userDidOverride: false),
            SidebarAutoHide.State(didAutoCollapse: true, userDidOverride: false),
            SidebarAutoHide.State(didAutoCollapse: false, userDidOverride: true),
            SidebarAutoHide.State(didAutoCollapse: true, userDidOverride: true),
        ] {
            let folded = SidebarAutoHide.registeringManualToggle(prior)
            XCTAssertTrue(folded.userDidOverride)
            XCTAssertFalse(folded.didAutoCollapse)
        }
    }

    // MARK: - Preference gating (sidebar audit)

    /// Width-driven auto-hide is opt-in: only the `.autoHide` Appearance
    /// preference enables it. `.visible` and `.hidden` skip the reducer so the
    /// rail stays put — which is what makes the three picker options
    /// behaviourally distinct (previously `.autoHide` was a no-op alias for
    /// `.visible` because the reducer ran for everyone).
    func testAutoHideIsEnabledOnlyForAutoHidePreference() {
        XCTAssertTrue(SidebarAutoHide.isEnabled(for: .autoHide))
        XCTAssertFalse(SidebarAutoHide.isEnabled(for: .visible))
        XCTAssertFalse(SidebarAutoHide.isEnabled(for: .hidden))
    }

    /// Every `AppearanceSidebar` case has a defined enablement, and exactly one
    /// (`.autoHide`) opts in — a guard so a future case added to the enum is
    /// forced to make an explicit choice here rather than silently defaulting.
    func testExactlyOneSidebarPreferenceEnablesAutoHide() {
        let enabled = AppearanceSidebar.allCases.filter { SidebarAutoHide.isEnabled(for: $0) }
        XCTAssertEqual(enabled, [.autoHide])
    }

    // MARK: - Persistence key stability

    /// The `@AppStorage` key is a stable on-disk identifier; renaming it
    /// silently resets every user's manual-override preference.
    func testSidebarOverrideKeyIsStable() {
        XCTAssertEqual(SidebarDefaults.userDidOverrideAutoHideKey, "sidebar.userDidOverrideAutoHide")
    }

    // MARK: - MainShell source invariants

    /// The sidebar column must be drag-resizable with explicit bounds (#318) —
    /// the fixed `.navigationSplitViewColumnWidth(252)` is replaced by the
    /// `min/ideal/max` overload so the separator can be dragged.
    func testMainShellSidebarIsResizableWithBounds() throws {
        let code = try mainShellSource()
        XCTAssertTrue(
            code.contains(".navigationSplitViewColumnWidth(min: 200, ideal: 252, max: 360)"),
            "MainShell must declare a resizable sidebar with min/ideal/max bounds")
        XCTAssertFalse(
            code.contains(".navigationSplitViewColumnWidth(252)"),
            "The fixed-width sidebar must be replaced by the resizable overload")
    }

    /// The width-driven auto-hide must be wired: MainShell observes its width
    /// and feeds it to the `SidebarAutoHide` reducer (#318).
    func testMainShellWiresWidthDrivenAutoHide() throws {
        let code = try mainShellSource()
        XCTAssertTrue(code.contains("GeometryReader"),
                      "MainShell must observe its width via GeometryReader to drive auto-hide")
        XCTAssertTrue(code.contains("SidebarAutoHide.decide("),
                      "MainShell must run the SidebarAutoHide reducer on width changes")
        XCTAssertTrue(code.contains("applySidebarAutoHide(width:"),
                      "MainShell must apply the reducer's decision from a width observer")
    }

    /// The toolbar toggle must record a manual override so auto-hide stops
    /// fighting the user (#318).
    func testMainShellToggleRecordsManualOverride() throws {
        let code = try mainShellSource()
        XCTAssertTrue(code.contains("SidebarAutoHide.registeringManualToggle("),
                      "The Toggle Sidebar button must register a manual override")
        XCTAssertTrue(code.contains("userDidOverrideAutoHide = true"),
                      "The manual override must be persisted via @AppStorage")
    }

    /// The width-driven auto-hide must be gated on the Appearance `Sidebar`
    /// preference so the reducer only runs for `.autoHide` (sidebar audit). A
    /// regression that drops the gate would make `.autoHide` a no-op alias for
    /// `.visible` again.
    func testMainShellGatesAutoHideOnPreference() throws {
        let code = try mainShellSource()
        XCTAssertTrue(code.contains("SidebarAutoHide.isEnabled(for:"),
                      "applySidebarAutoHide must gate the reducer on the Sidebar preference")
    }

    // MARK: - Helpers

    /// Loads `MainShell.swift` relative to this test file via `#filePath`, so
    /// the lookup is independent of the test runner's working directory.
    private func mainShellSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let mainShell = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird/Screens/MainShell.swift")
        guard let data = try? Data(contentsOf: mainShell),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read MainShell.swift at \(mainShell.path)", file: file, line: line)
            return ""
        }
        return text
    }
}
