import XCTest
@testable import Lyrebird

/// Guards the Switch Control "Group items" grouping wired into `MainShell`
/// for #344. SwiftUI offers no public API to introspect
/// `.accessibilityElement` / `.accessibilityLabel` / `.accessibilitySortPriority`
/// off a `some View` without booting a scene or pulling in ViewInspector, so
/// these tests assert two complementary things:
///   1. the `SwitchControlGroup` enum constants (the spoken group labels), and
///   2. the structural invariants of how `MainShell.swift` applies the
///      grouping modifiers — read directly from source.
/// They are falsifiable: each one fails if the corresponding modifier is
/// removed, relabelled, or reordered — exactly the class of regression that
/// silently breaks the Switch Control group scan.
final class SwitchControlGroupingTests: XCTestCase {

    // MARK: - Enum constants

    /// The three top-level groups must keep their stable spoken labels so
    /// Switch Control's group scan reads Sidebar / Content / Player Bar.
    func testSwitchControlGroupLabels() {
        XCTAssertEqual(SwitchControlGroup.sidebar.rawValue, "Sidebar")
        XCTAssertEqual(SwitchControlGroup.content.rawValue, "Content")
        XCTAssertEqual(SwitchControlGroup.playerBar.rawValue, "Player Bar")
        XCTAssertEqual(SwitchControlGroup.allCases.count, 3)
    }

    // MARK: - MainShell source invariants

    /// MainShell must apply a named grouping container for both the sidebar
    /// and the content column (via the `SwitchControlGroup` enum). (#344)
    func testMainShellNamesTheSidebarAndContentGroups() throws {
        let code = strippingLineComments(try mainShellSource())
        XCTAssertTrue(code.contains(".accessibilityLabel(SwitchControlGroup.sidebar.rawValue)"),
                      "MainShell must label the sidebar group via SwitchControlGroup.sidebar")
        XCTAssertTrue(code.contains(".accessibilityLabel(SwitchControlGroup.content.rawValue)"),
                      "MainShell must label the content group via SwitchControlGroup.content")
    }

    /// The sidebar and content columns must each be wrapped in a single
    /// grouping container so Switch Control can scan each as one top-level
    /// group and descend on demand. The player bar's container lives in
    /// PlayerBar.swift, NOT here — see `testPlayerBarIsNotDoubleWrapped`. (#344)
    func testSidebarAndContentAreGroupedContainers() throws {
        let code = strippingLineComments(try mainShellSource())
        let containers = ranges(of: ".accessibilityElement(children: .contain)", in: code).count
        XCTAssertEqual(containers, 2,
                       "MainShell should declare exactly two grouping containers (sidebar + content); found \(containers)")
    }

    /// Regression guard for review finding #1: `PlayerBar` already wraps
    /// itself in a `.accessibilityElement(children: .contain)` +
    /// `.accessibilityLabel("Playback controls")` container. MainShell must
    /// NOT add a second container around `PlayerBar()`, or Switch Control's
    /// group scan nests two groups and steps through an empty outer group
    /// before reaching the transport. (#344)
    func testPlayerBarIsNotDoubleWrapped() throws {
        let code = strippingLineComments(try mainShellSource())
        // The shell must not re-label the player bar as its own group. Checked
        // against comment-stripped source so the explanatory comment that
        // mentions "Player Bar" / SwitchControlGroup.playerBar never trips the
        // guard — only a live modifier counts.
        XCTAssertFalse(code.contains(".accessibilityLabel(SwitchControlGroup.playerBar.rawValue)"),
                       "MainShell must not add a second 'Player Bar' container around PlayerBar() — PlayerBar already names its own group")
        // PlayerBar()'s only live accessibility modifier in MainShell is the
        // sort priority pinning it last in the #334 tab order; it must not
        // re-wrap PlayerBar() in a second grouping container.
        let playerBarBlock = try slice(code, from: "PlayerBar()", upTo: ".background(Theme.bg)")
        XCTAssertFalse(playerBarBlock.contains(".accessibilityElement(children: .contain)"),
                       "MainShell must not wrap PlayerBar() in a second grouping container")
        XCTAssertTrue(playerBarBlock.contains(".accessibilitySortPriority(50)"),
                      "MainShell must keep PlayerBar()'s tab-order sort priority")
    }

    /// Regression guard for review finding #2: `.accessibilitySortPriority`
    /// must be applied AFTER `.accessibilityElement(children: .contain)` /
    /// `.accessibilityLabel(...)` so the priority lands on the grouping
    /// container, not the wrapped child — otherwise the #334 tab-traversal
    /// order is read off the inner element and the container falls back to
    /// default priority. (#344)
    func testSortPriorityIsAppliedAfterTheGroupingContainer() throws {
        let code = strippingLineComments(try mainShellSource())
        // Sidebar: label(sidebar) then sortPriority(100).
        try assertContainerPrecedesSortPriority(
            in: code,
            container: ".accessibilityLabel(SwitchControlGroup.sidebar.rawValue)",
            sortPriority: ".accessibilitySortPriority(100)")
        // Content: label(content) then sortPriority(90).
        try assertContainerPrecedesSortPriority(
            in: code,
            container: ".accessibilityLabel(SwitchControlGroup.content.rawValue)",
            sortPriority: ".accessibilitySortPriority(90)")
    }

    // MARK: - Helpers

    /// Loads the `MainShell.swift` source relative to this test file. Using
    /// `#filePath` keeps the lookup stable regardless of the working directory
    /// the test runner is launched from.
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

    private func assertContainerPrecedesSortPriority(
        in src: String,
        container: String,
        sortPriority: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let containerRange = src.range(of: container) else {
            XCTFail("Expected to find grouping container \(container)", file: file, line: line)
            return
        }
        guard let sortRange = src.range(of: sortPriority) else {
            XCTFail("Expected to find \(sortPriority)", file: file, line: line)
            return
        }
        XCTAssertTrue(containerRange.lowerBound < sortRange.lowerBound,
                      "\(sortPriority) must come AFTER \(container) so the priority lands on the grouping container",
                      file: file, line: line)
    }

    private func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }

    /// Drops `//`-style line comments so source-invariant assertions match
    /// live code rather than explanatory prose (several MainShell comments
    /// quote the very modifiers under test). Block comments aren't used in the
    /// regions exercised here, so a line-comment strip is sufficient.
    private func strippingLineComments(_ src: String) -> String {
        src
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") {
                    return line[line.startIndex..<r.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private func slice(_ src: String, from start: String, upTo end: String) throws -> String {
        guard let s = src.range(of: start) else {
            XCTFail("Expected to find \(start) in MainShell source")
            return ""
        }
        guard let e = src.range(of: end, range: s.upperBound..<src.endIndex) else {
            return String(src[s.lowerBound...])
        }
        return String(src[s.lowerBound..<e.lowerBound])
    }
}
