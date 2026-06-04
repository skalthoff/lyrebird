import XCTest

@testable import Lyrebird

/// Coverage for the multiple-main-windows wiring (#11).
///
/// File ▸ "New Window" (⌘⇧N) summons another instance of the primary
/// `WindowGroup` via `openWindow(id: MainWindowScene.id)`. SwiftUI's
/// `openWindow(id:)` only resolves a scene whose id is declared and unique, so
/// the load-bearing, regression-prone facts are:
///
///   1. `MainWindowScene.id` is stable and non-empty — `WindowGroup`'s id is
///      part of the scene's restoration identity, so churning it would orphan
///      every user's saved window placement, and an empty id wouldn't resolve.
///   2. It is distinct from every other scene id in the app. SwiftUI routes
///      `openWindow(id:)` purely by id; a collision with the Mini Player,
///      About, or Keyboard Shortcuts windows would summon the wrong scene.
///
/// The menu plumbing and the `WindowGroup` declaration themselves can't be
/// exercised headlessly, so these constant-level invariants are the unit-test
/// surface; the per-window navigation behaviour is deliberately shared (every
/// window mirrors the single `AppModel`), so there is no per-window nav helper
/// to test here.
final class MultipleWindowsTests: XCTestCase {

    /// The primary window's scene id must be a fixed, non-empty string. The id
    /// is an on-disk contract (scene restoration keys off it) and `openWindow`
    /// can't resolve an empty id, so both properties are pinned.
    func testMainWindowSceneIDIsStableAndNonEmpty() {
        XCTAssertEqual(
            MainWindowScene.id,
            "main",
            "MainWindowScene.id is a scene-restoration contract; renaming it orphans saved window state."
        )
        XCTAssertFalse(
            MainWindowScene.id.isEmpty,
            "openWindow(id:) cannot resolve an empty scene id."
        )
    }

    /// New Window routes `openWindow(id:)` by id alone, so the main-window id
    /// must not collide with any other declared scene (Mini Player, About,
    /// Keyboard Shortcuts) — a collision would summon the wrong window.
    func testMainWindowSceneIDIsDistinctFromOtherScenes() {
        let otherSceneIDs: Set<String> = [
            MiniPlayerScene.id,
            AboutView.windowID,
            AppShortcuts.windowID,
        ]
        XCTAssertFalse(
            otherSceneIDs.contains(MainWindowScene.id),
            "MainWindowScene.id collides with another scene id: \(MainWindowScene.id)"
        )
    }

    /// All four declared scene ids must be mutually unique. Pinned as a set so
    /// that adding a future scene whose id duplicates an existing one trips
    /// this test rather than silently mis-routing `openWindow`.
    func testAllSceneIDsAreUnique() {
        let ids = [
            MainWindowScene.id,
            MiniPlayerScene.id,
            AboutView.windowID,
            AppShortcuts.windowID,
        ]
        XCTAssertEqual(
            Set(ids).count,
            ids.count,
            "Scene ids must be unique so openWindow(id:) resolves the intended window."
        )
    }
}
