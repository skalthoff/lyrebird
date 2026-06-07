import XCTest
@testable import Lyrebird

/// Guards the Tab / Shift+Tab region-cycle ordering wired into `MainShell`.
/// The view-level `@FocusState` wiring can't be introspected without
/// booting a scene, so these tests pin the part that carries the behaviour: the
/// pure `FocusRegionCycle` ordering (Sidebar → Content → Up Next → Player Bar →
/// Search → wrap) and its rule that the Up Next inspector is skipped when it
/// isn't mounted. Each assertion is falsifiable — reorder the regions, drop the
/// wrap-around, or stop skipping the closed inspector and one of these fails.
final class FocusRegionCycleTests: XCTestCase {

    // MARK: - Enum constants

    /// The five regions must keep their stable order + spoken labels so the
    /// cycle and the region focus ring read off one source of truth.
    func testFocusRegionOrderAndLabels() {
        XCTAssertEqual(
            FocusRegion.allCases,
            [.sidebar, .content, .upNext, .playerBar, .search]
        )
        XCTAssertEqual(FocusRegion.sidebar.rawValue, "Sidebar")
        XCTAssertEqual(FocusRegion.content.rawValue, "Content")
        XCTAssertEqual(FocusRegion.upNext.rawValue, "Up Next")
        XCTAssertEqual(FocusRegion.playerBar.rawValue, "Player Bar")
        XCTAssertEqual(FocusRegion.search.rawValue, "Search")
    }

    // MARK: - Reachable order

    /// With the inspector open, all five regions participate in the cycle.
    func testOrderIncludesInspectorWhenOpen() {
        XCTAssertEqual(
            FocusRegionCycle.order(inspectorPresent: true),
            [.sidebar, .content, .upNext, .playerBar, .search]
        )
    }

    /// With the inspector closed, Up Next drops out — the other four stay in
    /// order.
    func testOrderSkipsInspectorWhenClosed() {
        XCTAssertEqual(
            FocusRegionCycle.order(inspectorPresent: false),
            [.sidebar, .content, .playerBar, .search]
        )
    }

    // MARK: - Forward cycle (Tab), inspector open

    func testForwardCycleWithInspector() {
        func fwd(_ r: FocusRegion?) -> FocusRegion {
            FocusRegionCycle.next(from: r, direction: .forward, inspectorPresent: true)
        }
        XCTAssertEqual(fwd(.sidebar), .content)
        XCTAssertEqual(fwd(.content), .upNext)
        XCTAssertEqual(fwd(.upNext), .playerBar)
        XCTAssertEqual(fwd(.playerBar), .search)
        // Wrap-around: Search → Sidebar.
        XCTAssertEqual(fwd(.search), .sidebar)
    }

    // MARK: - Forward cycle (Tab), inspector closed

    /// Content must skip straight to Player Bar (not Up Next) when the inspector
    /// is closed, and the wrap still lands on Sidebar.
    func testForwardCycleSkipsClosedInspector() {
        func fwd(_ r: FocusRegion?) -> FocusRegion {
            FocusRegionCycle.next(from: r, direction: .forward, inspectorPresent: false)
        }
        XCTAssertEqual(fwd(.sidebar), .content)
        XCTAssertEqual(fwd(.content), .playerBar)
        XCTAssertEqual(fwd(.playerBar), .search)
        XCTAssertEqual(fwd(.search), .sidebar)
    }

    // MARK: - Backward cycle (Shift+Tab)

    func testBackwardCycleWithInspector() {
        func back(_ r: FocusRegion?) -> FocusRegion {
            FocusRegionCycle.next(from: r, direction: .backward, inspectorPresent: true)
        }
        // Wrap-around: Sidebar → Search.
        XCTAssertEqual(back(.sidebar), .search)
        XCTAssertEqual(back(.content), .sidebar)
        XCTAssertEqual(back(.upNext), .content)
        XCTAssertEqual(back(.playerBar), .upNext)
        XCTAssertEqual(back(.search), .playerBar)
    }

    func testBackwardCycleSkipsClosedInspector() {
        func back(_ r: FocusRegion?) -> FocusRegion {
            FocusRegionCycle.next(from: r, direction: .backward, inspectorPresent: false)
        }
        // Player Bar steps back over the absent Up Next to Content.
        XCTAssertEqual(back(.playerBar), .content)
        XCTAssertEqual(back(.sidebar), .search)
        XCTAssertEqual(back(.content), .sidebar)
        XCTAssertEqual(back(.search), .playerBar)
    }

    // MARK: - Entry from no / stale focus

    /// The very first Tab (nothing focused yet) enters at Sidebar; the very
    /// first Shift+Tab enters at Search — so the cycle never dead-ends on a
    /// fresh window.
    func testEntryFromNilFocus() {
        XCTAssertEqual(
            FocusRegionCycle.next(from: nil, direction: .forward, inspectorPresent: true),
            .sidebar
        )
        XCTAssertEqual(
            FocusRegionCycle.next(from: nil, direction: .backward, inspectorPresent: true),
            .search
        )
    }

    /// If focus was parked on the inspector and it then closed, the next Tab
    /// treats the stale region as "no current region" and re-enters at the
    /// natural end rather than getting stuck.
    func testEntryFromStaleInspectorRegion() {
        XCTAssertEqual(
            FocusRegionCycle.next(from: .upNext, direction: .forward, inspectorPresent: false),
            .sidebar
        )
        XCTAssertEqual(
            FocusRegionCycle.next(from: .upNext, direction: .backward, inspectorPresent: false),
            .search
        )
    }
}
