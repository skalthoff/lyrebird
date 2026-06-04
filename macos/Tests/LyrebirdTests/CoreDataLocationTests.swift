import XCTest

@testable import Lyrebird

/// Coverage for `CoreDataLocation` (audit L31). The core-init failure recovery
/// screen offers a "Reset Local Data" affordance that moves the core's data
/// directory aside. To target the *right* directory, the Swift side must mirror
/// `core/src/storage.rs::default_data_dir()` exactly; these tests pin that
/// derivation plus the quarantine move.
final class CoreDataLocationTests: XCTestCase {

    // MARK: - resolve (mirrors default_data_dir)

    /// A non-empty `XDG_DATA_HOME` wins and the app folder is appended — exactly
    /// what the core does, and what the test harness relies on to redirect data.
    func testPrefersXdgDataHome() {
        let url = CoreDataLocation.resolve(
            environment: ["XDG_DATA_HOME": "/tmp/xdg"],
            home: "/Users/someone"
        )
        XCTAssertEqual(url?.path, "/tmp/xdg/lyrebird-desktop")
    }

    /// An empty `XDG_DATA_HOME` is ignored (matching the core's `!val.is_empty()`
    /// guard) and we fall back to Application Support.
    func testEmptyXdgFallsBackToApplicationSupport() {
        let url = CoreDataLocation.resolve(
            environment: ["XDG_DATA_HOME": ""],
            home: "/Users/someone"
        )
        XCTAssertEqual(
            url?.path,
            "/Users/someone/Library/Application Support/lyrebird-desktop"
        )
    }

    /// No XDG var → Application Support under the home directory.
    func testFallsBackToApplicationSupport() {
        let url = CoreDataLocation.resolve(
            environment: [:],
            home: "/Users/someone"
        )
        XCTAssertEqual(
            url?.path,
            "/Users/someone/Library/Application Support/lyrebird-desktop"
        )
    }

    /// Neither XDG nor a home dir → nil (matching `dirs_next_like()` → None).
    func testReturnsNilWithoutXdgOrHome() {
        XCTAssertNil(CoreDataLocation.resolve(environment: [:], home: nil))
        XCTAssertNil(CoreDataLocation.resolve(environment: [:], home: ""))
    }

    // MARK: - quarantineDataDirectory

    /// Moving an existing directory aside returns the timestamped backup, leaves
    /// the original gone, and preserves the contents at the new location.
    func testQuarantineMovesExistingDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lyrebird-quarantine-\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("lyrebird-desktop", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let marker = dataDir.appendingPathComponent("db.sqlite")
        try Data("corrupt".utf8).write(to: marker)
        defer { try? fm.removeItem(at: root) }

        let backup = try CoreDataLocation.quarantineDataDirectory(dataDir, fileManager: fm)

        let unwrapped = try XCTUnwrap(backup, "an existing directory must report its backup location")
        XCTAssertFalse(fm.fileExists(atPath: dataDir.path), "the original data dir should be moved away")
        XCTAssertTrue(fm.fileExists(atPath: unwrapped.path), "the backup directory should exist")
        XCTAssertTrue(
            fm.fileExists(atPath: unwrapped.appendingPathComponent("db.sqlite").path),
            "contents should survive the move so the user can recover them"
        )
        XCTAssertTrue(
            unwrapped.lastPathComponent.hasPrefix("lyrebird-desktop.corrupt-"),
            "backup folder should be a clearly-labelled sibling, got \(unwrapped.lastPathComponent)"
        )
    }

    /// Quarantining a directory that doesn't exist is a no-op (returns nil), so
    /// the recovery screen can show a "nothing to reset" message instead of
    /// throwing.
    func testQuarantineMissingDirectoryIsNoOp() throws {
        let fm = FileManager.default
        let missing = fm.temporaryDirectory
            .appendingPathComponent("lyrebird-missing-\(UUID().uuidString)", isDirectory: true)
        let backup = try CoreDataLocation.quarantineDataDirectory(missing, fileManager: fm)
        XCTAssertNil(backup)
    }
}
