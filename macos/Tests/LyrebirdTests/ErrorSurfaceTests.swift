import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Behaviour of the `AudioEngineDelegate` hooks that feed the global
/// `errorMessage` toast (mounted by `MainShell`):
///   * a stall surfaces the "Stalled, retrying…" banner,
///   * recovery clears exactly that banner — and only that banner,
///   * the transient-error hook (#806) actually lands its message rather
///     than falling into the protocol's default no-op, which is how
///     "Connection lost — skipping" used to vanish.
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; the core's
/// data dir is redirected to a throwaway temp dir via `XDG_DATA_HOME` so the
/// tests never touch the real app database.
@MainActor
final class ErrorSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    func testStallSurfacesBanner() throws {
        let model = try AppModel()
        model.audioEngineDidStall()
        XCTAssertEqual(model.errorMessage, AppModel.stallRetryingMessage)
    }

    func testRecoveryClearsStallBanner() throws {
        let model = try AppModel()
        model.audioEngineDidStall()
        model.audioEngineDidRecover()
        XCTAssertNil(model.errorMessage)
    }

    func testRecoveryPreservesUnrelatedError() throws {
        let model = try AppModel()
        model.errorMessage = "Couldn't add to playlist."
        model.audioEngineDidRecover()
        XCTAssertEqual(model.errorMessage, "Couldn't add to playlist.")
    }

    func testTerminalFailureSurfacesMessage() throws {
        let model = try AppModel()
        model.audioEngineDidFail("Couldn't play this track.")
        XCTAssertEqual(model.errorMessage, "Couldn't play this track.")
    }

    func testTransientErrorSurfacesMessage() throws {
        let model = try AppModel()
        model.audioEngineDidEncounterTransientError("Connection lost — skipping")
        XCTAssertEqual(model.errorMessage, "Connection lost — skipping")
    }

    func testStaleAutoDismissCannotClearNewerError() throws {
        let model = try AppModel()
        model.errorMessage = "New error"
        // A timer armed for the previous message fires late: it must not
        // wipe the newer message's display window.
        model.dismissError(ifStillShowing: "Old error")
        XCTAssertEqual(model.errorMessage, "New error")
    }

    func testMatchingAutoDismissClearsError() throws {
        let model = try AppModel()
        model.errorMessage = "Same error"
        model.dismissError(ifStillShowing: "Same error")
        XCTAssertNil(model.errorMessage)
    }
}
