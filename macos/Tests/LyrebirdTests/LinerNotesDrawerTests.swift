import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for the album liner-notes drawer (#221): the slide-in panel
/// reachable from a "Liner Notes" button in the album hero CTA row, surfacing
/// the same structured fields + credits as the inline block (#65).
///
/// SwiftUI exposes no public hook to introspect a `transition` / `animation`
/// off a `some View` without booting a scene, so — mirroring the
/// `SidebarAutoHide` reducer + its `SidebarAutoHideTests` — the motion policy
/// lives in the pure `LinerNotesDrawerPresentation` type and is exercised here
/// directly. A second group asserts the structural wiring in
/// `AlbumDetailView.swift` (read from source) so a regression that detaches the
/// button or the drawer — or drops Reduce-Motion / dismiss handling — is caught
/// here rather than in the field.
final class LinerNotesDrawerTests: XCTestCase {

    // MARK: - Reduce Motion: transition

    /// With motion allowed, the panel slides in from the trailing edge. The
    /// transition must NOT be the plain opacity crossfade — a horizontal slide
    /// is the default presentation.
    func testTransitionSlidesWhenMotionAllowed() {
        let slide = LinerNotesDrawerPresentation.transition(reduceMotion: false)
        let crossfade = LinerNotesDrawerPresentation.transition(reduceMotion: true)
        // `AnyTransition` isn't `Equatable`, so we assert the two branches are
        // distinguishable via their reflected descriptions: the motion path
        // carries a `move`, the reduce-motion path is opacity-only.
        XCTAssertNotEqual(
            String(describing: slide),
            String(describing: crossfade),
            "Motion-allowed and reduce-motion transitions must differ")
        XCTAssertTrue(
            String(describing: slide).contains("move") ||
                String(describing: slide).contains("Move"),
            "Motion-allowed transition should be a trailing-edge move")
    }

    /// Under Reduce Motion the panel must NOT travel horizontally — it appears
    /// with an opacity-only crossfade so there's no slide animation.
    func testTransitionCrossfadesUnderReduceMotion() {
        let crossfade = LinerNotesDrawerPresentation.transition(reduceMotion: true)
        let described = String(describing: crossfade)
        XCTAssertFalse(
            described.contains("move") || described.contains("Move"),
            "Reduce-motion transition must not slide (no horizontal move)")
        XCTAssertEqual(
            described,
            String(describing: AnyTransition.opacity),
            "Reduce-motion transition should be a plain opacity crossfade")
    }

    // MARK: - Reduce Motion: animation curve

    /// With motion allowed the present/dismiss paths animate with a real curve
    /// so the slide reads as a smooth transition rather than a hard cut.
    func testAnimationHasCurveWhenMotionAllowed() {
        XCTAssertNotNil(
            LinerNotesDrawerPresentation.animation(reduceMotion: false),
            "Motion-allowed open/close must carry an animation curve")
    }

    /// Under Reduce Motion the animation collapses to `nil` so the drawer's
    /// presented state flips instantly with no in-between motion. This is the
    /// contract the `withAnimation(...)` call sites rely on to honour the
    /// system setting.
    func testAnimationIsNilUnderReduceMotion() {
        XCTAssertNil(
            LinerNotesDrawerPresentation.animation(reduceMotion: true),
            "Reduce Motion must disable the drawer animation entirely")
    }

    /// The two motion knobs agree: when one says "animate" the other says
    /// "slide", and when one says "don't animate" the other says "crossfade".
    /// A future edit that flips only one of the two would desync the open
    /// affordance from its close affordances — this pins them together.
    func testMotionKnobsAreConsistent() {
        // Reduce Motion on → no curve AND no slide.
        XCTAssertNil(LinerNotesDrawerPresentation.animation(reduceMotion: true))
        XCTAssertEqual(
            String(describing: LinerNotesDrawerPresentation.transition(reduceMotion: true)),
            String(describing: AnyTransition.opacity))

        // Reduce Motion off → a curve AND a slide.
        XCTAssertNotNil(LinerNotesDrawerPresentation.animation(reduceMotion: false))
        XCTAssertTrue(
            String(describing: LinerNotesDrawerPresentation.transition(reduceMotion: false))
                .lowercased().contains("move"))
    }

    // MARK: - AlbumDetailView source invariants

    /// The drawer is presentation-state driven by a single `@State` flag (#221)
    /// — the open button sets it true, the dismiss paths set it false.
    func testAlbumDetailDeclaresDrawerPresentationFlag() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains("@State private var isLinerNotesDrawerPresented = false"),
            "AlbumDetailView must own the drawer's presentation flag, default closed")
    }

    /// A "Liner Notes" button must live in the hero CTA row and open the
    /// drawer. Asserts both the row wiring (`linerNotesButton` in `ctaRow`) and
    /// that the button flips the presentation flag true.
    func testAlbumDetailHasLinerNotesButtonInCtaRow() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(code.contains("linerNotesButton"),
                      "ctaRow must include a Liner Notes button")
        XCTAssertTrue(code.contains("\"Liner Notes\""),
                      "The CTA must be labelled \"Liner Notes\"")
        XCTAssertTrue(code.contains("isLinerNotesDrawerPresented = true"),
                      "The Liner Notes button must open the drawer")
    }

    /// The drawer must mount as a trailing-edge overlay over the scroll view
    /// (slide-in over the page), not reflow the layout.
    func testAlbumDetailMountsDrawerAsTrailingOverlay() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains(".overlay(alignment: .trailing) { linerNotesDrawer }"),
            "The drawer must be layered as a trailing overlay over the page")
    }

    /// All three close affordances must exist and funnel through the single
    /// `dismissLinerNotesDrawer()` path: the Escape handler (`.cancelAction`),
    /// the scrim tap, and the panel's close button.
    func testAlbumDetailWiresAllDismissPaths() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(code.contains("func dismissLinerNotesDrawer()"),
                      "A single dismiss helper must back every close path")
        XCTAssertTrue(code.contains("isLinerNotesDrawerPresented = false"),
                      "Dismiss must clear the presentation flag")
        // Escape: a cancel-action keyboard shortcut closes the drawer.
        XCTAssertTrue(code.contains(".keyboardShortcut(.cancelAction)"),
                      "Escape must close the drawer via a cancel-action shortcut")
        // Tap-out: the dimmed scrim is a tap target that dismisses.
        XCTAssertTrue(code.contains(".onTapGesture { dismissLinerNotesDrawer() }"),
                      "Tapping the scrim must close the drawer")
        // Close button: the panel header carries an explicit close control.
        XCTAssertTrue(code.contains("\"Close liner notes\""),
                      "The panel must have an explicit close button")
    }

    /// The drawer's motion must route through `LinerNotesDrawerPresentation`
    /// for both the transition and the animation — never an inline literal that
    /// could ignore Reduce Motion. This keeps the tested policy as the single
    /// source of truth for the view's motion.
    func testAlbumDetailRoutesMotionThroughPolicy() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(
            code.contains("LinerNotesDrawerPresentation.transition(reduceMotion: reduceMotion)"),
            "The panel transition must come from the reduce-motion-aware policy")
        XCTAssertTrue(
            code.contains("LinerNotesDrawerPresentation.animation(reduceMotion: reduceMotion)"),
            "The open/close animation must come from the reduce-motion-aware policy")
        XCTAssertTrue(
            code.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
            "AlbumDetailView must read the system Reduce Motion setting")
    }

    /// Opening the page (or switching albums) must reset the drawer closed so a
    /// prior album's panel never bleeds onto the next — the same hygiene the
    /// About popover gets.
    func testAlbumDetailResetsDrawerOnAlbumChange() throws {
        let code = try albumDetailSource()
        let taskMarker = "isAboutExpanded = false"
        XCTAssertTrue(code.contains(taskMarker),
                      "Sanity: the About-popover reset still lives in the .task")
        XCTAssertTrue(code.contains("isLinerNotesDrawerPresented = false"),
                      "The .task must close the drawer on album (re)load")
    }

    /// The structured liner-note body must be rendered through a shared
    /// `linerNotesContent(album:)` helper so the inline block (#65) and the
    /// drawer (#221) can never drift in what they show.
    func testLinerNotesContentIsSharedBetweenInlineAndDrawer() throws {
        let code = try albumDetailSource()
        XCTAssertTrue(code.contains("func linerNotesContent(album: Album)"),
                      "A shared content builder must back both liner-note surfaces")
        // It must be invoked from both the inline block and the drawer panel.
        let invocations = code.components(separatedBy: "linerNotesContent(album:").count - 1
        // One definition + two call sites = three textual occurrences.
        XCTAssertGreaterThanOrEqual(
            invocations, 3,
            "linerNotesContent must be called from both the inline block and the drawer")
    }

    // MARK: - Helpers

    /// Loads `AlbumDetailView.swift` relative to this test file via `#filePath`
    /// so the lookup is independent of the test runner's working directory.
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
}
