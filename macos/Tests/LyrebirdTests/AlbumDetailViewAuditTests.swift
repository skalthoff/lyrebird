import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the AlbumDetailView audit-fix pass:
///
/// - #475: "Read more" on the editorial "About this album" blurb is shown only
///   when the overview actually overflows its 4-line clamp. The truncation
///   decision lives in the pure `AboutOverviewTruncation` type (mirroring
///   `LinerNotesDrawerPresentation`) and is exercised directly here.
/// - #67 / #83: album-scoped `@State` (tracks / detail / moreByArtist /
///   fetchedAlbum) is reset at the start of the `.task(id:)` so a prior
///   album's data never paints during the reload window, and `moreByArtist` is
///   cleared when the new album has no artist so the old shelf can't persist.
/// - #176: the hero "Minutes" stat and the liner-note "Runtime" row read the
///   same `totalRuntimeTicks(album:)` source so they can't disagree.
///
/// The pure decision is unit-tested; the view wiring is asserted against the
/// source text (the `LinerNotesDrawerTests` idiom) so a regression that drops a
/// reset or re-shows the unconditional button is caught here, not in the field.
final class AlbumDetailViewAuditTests: XCTestCase {

    // MARK: - #475 About-overview truncation decision

    /// A full text taller than the clamped text means the overview is cut off,
    /// so "Read more" should appear.
    func testTruncatedWhenFullExceedsClamped() {
        XCTAssertTrue(
            AboutOverviewTruncation.isTruncated(clamped: 80, full: 240),
            "A full height well above the clamp must register as truncated")
    }

    /// When the overview fits inside the clamp the two heights match, so there
    /// is nothing to expand and the button must be omitted.
    func testNotTruncatedWhenHeightsMatch() {
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: 80, full: 80),
            "Equal clamped/full heights mean the text fits — no Read more")
    }

    /// A short overview (one or two lines, well under the 4-line clamp) is not
    /// truncated — the clamped Text renders the whole thing.
    func testNotTruncatedForShortOverview() {
        // A single line is shorter than the four-line clamp budget, so the
        // clamped render equals the full render.
        XCTAssertFalse(AboutOverviewTruncation.isTruncated(clamped: 20, full: 20))
    }

    /// Sub-point rounding between the two independent measurements must not
    /// register a fits-exactly overview as truncated — the epsilon absorbs it.
    func testEpsilonAbsorbsSubPointRounding() {
        let clamped: CGFloat = 80
        let full = clamped + AboutOverviewTruncation.epsilon - 0.01
        XCTAssertFalse(
            AboutOverviewTruncation.isTruncated(clamped: clamped, full: full),
            "A difference under epsilon must not count as truncation")
    }

    /// A difference comfortably above epsilon (e.g. one extra wrapped line) is
    /// truncated.
    func testDifferenceAboveEpsilonIsTruncated() {
        let clamped: CGFloat = 80
        let full = clamped + AboutOverviewTruncation.epsilon + 18 // ~one line
        XCTAssertTrue(AboutOverviewTruncation.isTruncated(clamped: clamped, full: full))
    }

    /// Before measurement settles either height is zero; the button must stay
    /// hidden so it never flashes in during the first layout pass.
    func testNotTruncatedBeforeMeasurement() {
        XCTAssertFalse(AboutOverviewTruncation.isTruncated(clamped: 0, full: 0),
                       "Unmeasured (0/0) must not be truncated")
        XCTAssertFalse(AboutOverviewTruncation.isTruncated(clamped: 0, full: 200),
                       "Clamp unmeasured must not be truncated")
        XCTAssertFalse(AboutOverviewTruncation.isTruncated(clamped: 80, full: 0),
                       "Full unmeasured must not be truncated")
    }

    // MARK: - #475 View wiring

    /// The "Read more" button must be gated behind the truncation flag, not
    /// rendered unconditionally — the core of the #475 fix.
    func testReadMoreButtonIsConditional() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains("@State private var isOverviewTruncated = false"),
            "AlbumDetailView must own a truncation flag, default false")
        XCTAssertTrue(
            code.contains("if isOverviewTruncated {"),
            "The Read more button must be gated behind isOverviewTruncated")
        // The Read more label must live inside the gated branch.
        XCTAssertTrue(code.contains("\"Read more\""),
                      "The conditional CTA must still be labelled \"Read more\"")
    }

    /// The truncation flag must be driven by the pure `AboutOverviewTruncation`
    /// policy fed by the measured clamped vs. full heights — never a hard-coded
    /// `true`.
    func testTruncationRoutesThroughPolicy() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains("AboutOverviewTruncation.isTruncated("),
            "Truncation must be derived from the testable policy")
        XCTAssertTrue(code.contains("ClampedOverviewHeightKey"),
                      "The clamped height must be measured via a preference key")
        XCTAssertTrue(code.contains("FullOverviewHeightKey"),
                      "The full height must be measured via a preference key")
    }

    // MARK: - #67 / #83 Stale-state reset on album change

    /// Every album-scoped `@State` must be reset at the top of `.task(id:)`
    /// before the awaits so a prior album's data can't paint during the reload
    /// (#67) and a new album can't inherit the old `moreByArtist` (#83).
    func testTaskResetsAlbumScopedState() throws {
        let code = try albumDetailSource()
        let task = try taskBody()
        // The resets must appear, and they must come before the first await so
        // they take effect during the reload window rather than after it.
        for marker in [
            "tracks = []",
            "moreByArtist = []",
            "fetchedAlbum = nil",
            "detail = AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)",
        ] {
            XCTAssertTrue(task.contains(marker),
                          "The .task must reset album-scoped state: \(marker)")
        }
        // Sanity: the existing popover/drawer resets are still there.
        XCTAssertTrue(code.contains("isAboutExpanded = false"))
        XCTAssertTrue(code.contains("isLinerNotesDrawerPresented = false"))
    }

    /// The first `tracks = []` reset must precede the first `await` so stale
    /// tracks don't render while the new ones load.
    func testStateResetHappensBeforeAwaits() throws {
        let task = try taskBody()
        guard let resetRange = task.range(of: "tracks = []"),
              let firstAwait = task.range(of: "await ") else {
            XCTFail("Expected both a reset and an await in the .task body")
            return
        }
        XCTAssertTrue(
            resetRange.lowerBound < firstAwait.lowerBound,
            "Album-scoped state must be reset before the first await")
    }

    /// When the new album has no artist, `moreByArtist` must be explicitly
    /// cleared (the `else` branch of the artistId guard) so the previous
    /// album's shelf can't persist under the new header (#83).
    func testMoreByArtistClearedWhenNoArtist() throws {
        let task = try taskBody()
        // The artistId guard opens with the populate branch and must carry an
        // else branch that zeroes the shelf. Locate the guard, then assert an
        // `else` clearing `moreByArtist` follows it within the task body.
        guard let guardRange = task.range(of: "if let artistId = album?.artistId") else {
            XCTFail("Expected the artistId guard in the .task body")
            return
        }
        let afterGuard = task[guardRange.upperBound...]
        guard let elseRange = afterGuard.range(of: "} else {") else {
            XCTFail("The artistId guard must have an else branch")
            return
        }
        let elseBody = afterGuard[elseRange.upperBound...]
        // The first statement of the else branch clears the shelf (before the
        // closing brace of the else).
        guard let braceRange = elseBody.range(of: "}") else {
            XCTFail("Malformed else branch")
            return
        }
        XCTAssertTrue(
            elseBody[..<braceRange.lowerBound].contains("moreByArtist = []"),
            "The artistId guard's else branch must clear moreByArtist (#83)")
    }

    // MARK: - #176 Hero / runtime-row consistency

    /// Both the hero "Minutes" stat and the liner-note "Runtime" row must read
    /// the shared `totalRuntimeTicks(album:)` source so they can never disagree.
    func testRuntimeSourceIsShared() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains("func totalRuntimeTicks(album: Album)"),
            "A single runtime-ticks source must back both runtime surfaces")
        // The hero stat feeds the shared source into formatMinutes.
        XCTAssertTrue(
            code.contains("formatMinutes(totalRuntimeTicks(album: album))"),
            "The hero Minutes stat must use the shared track-sum source")
        // The liner-note Runtime row consumes the same source.
        XCTAssertTrue(
            code.contains("let ticks = totalRuntimeTicks(album: album)"),
            "The Runtime row must use the shared track-sum source")
        // Guard against a regression back to the album-only hero value.
        XCTAssertFalse(
            code.contains("formatMinutes(album.runtimeTicks)"),
            "The hero must not read album.runtimeTicks directly (would diverge)")
    }

    // MARK: - Helpers

    /// Loads `AlbumDetailView.swift` relative to this test file via `#filePath`.
    private func albumDetailSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let source = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent("Sources/Lyrebird/Screens/AlbumDetailView.swift")
        guard let data = try? Data(contentsOf: source),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read AlbumDetailView.swift at \(source.path)", file: file, line: line)
            return ""
        }
        return text
    }

    /// Extracts the body of the `.task(id: albumID)` closure so order-sensitive
    /// assertions (resets before awaits) aren't fooled by matches elsewhere in
    /// the file.
    private func taskBody(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let code = try albumDetailSource()
        guard let start = code.range(of: ".task(id: albumID) {") else {
            XCTFail("Could not locate the .task(id:) closure", file: file, line: line)
            return ""
        }
        // The task closure runs until the next top-level "// MARK: - Hero" which
        // immediately follows `body` in this file.
        let rest = code[start.upperBound...]
        guard let end = rest.range(of: "// MARK: - Hero") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }
}
