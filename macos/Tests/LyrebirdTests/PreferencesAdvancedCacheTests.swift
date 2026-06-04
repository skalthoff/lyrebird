import XCTest

@testable import Lyrebird

/// Coverage for `PreferencesAdvanced`'s "Clear Caches" filesystem contract.
///
/// The earlier implementation recursively deleted the entire user caches
/// root, which also destroyed offline downloads stored at `Caches/Downloads`
/// (see `PreferencesDownloads`) — a p0 because the dialog explicitly promises
/// the library isn't affected. The fix narrows the clear to the artwork
/// `DataCache` subdirectory and surfaces failures instead of always reporting
/// success. These tests pin three invariants:
///
///  1. The operation never targets the caches root or a downloads store.
///  2. Clearing the artwork directory leaves a sibling `Downloads` intact.
///  3. Failures and degenerate inputs produce honest `Result` outcomes.
final class PreferencesAdvancedCacheTests: XCTestCase {

    private let fm = FileManager.default

    /// Make a throwaway directory tree mirroring the sandbox shape:
    /// `…/<root>/Caches/<artwork>` alongside `…/<root>/Caches/Downloads`.
    private func makeCachesTree() throws -> (caches: URL, artwork: URL, downloads: URL) {
        let root = fm.temporaryDirectory
            .appendingPathComponent("PrefAdvCacheTests-\(UUID().uuidString)", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let artwork = caches.appendingPathComponent("com.lyrebird.macos.artwork", isDirectory: true)
        let downloads = caches.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        return (caches, artwork, downloads)
    }

    // MARK: - Safety guard

    /// The guard must reject the caches root itself so a config drift can never
    /// turn the clear back into the download-destroying recursive nuke.
    func testGuardRejectsCachesRoot() {
        let caches = URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true)
        XCTAssertFalse(PreferencesAdvanced.isSafeArtworkCacheDirectory(caches))
    }

    /// The guard must reject any `Downloads` directory — that's where offline
    /// tracks live and they must survive a cache clear.
    func testGuardRejectsDownloadsDirectory() {
        let downloads = URL(fileURLWithPath: "/Users/test/Library/Caches/Downloads", isDirectory: true)
        XCTAssertFalse(PreferencesAdvanced.isSafeArtworkCacheDirectory(downloads))
    }

    /// A named artwork subdirectory is the intended, safe target.
    func testGuardAllowsNamedArtworkSubdirectory() {
        let artwork = URL(
            fileURLWithPath: "/Users/test/Library/Caches/com.lyrebird.macos.artwork",
            isDirectory: true
        )
        XCTAssertTrue(PreferencesAdvanced.isSafeArtworkCacheDirectory(artwork))
    }

    // MARK: - Clearing behaviour

    /// Clearing the artwork directory removes its contents, recreates the empty
    /// directory, and — critically — leaves the sibling `Downloads` and its
    /// contents untouched.
    func testClearRemovesArtworkButPreservesDownloads() throws {
        let tree = try makeCachesTree()
        defer { try? fm.removeItem(at: tree.caches.deletingLastPathComponent()) }

        // Seed both directories with a file so we can prove what survived.
        let artworkFile = tree.artwork.appendingPathComponent("tile.dat")
        let downloadFile = tree.downloads.appendingPathComponent("song.flac")
        try Data("art".utf8).write(to: artworkFile)
        try Data("audio".utf8).write(to: downloadFile)

        let result = PreferencesAdvanced.clearArtworkCacheDirectory(at: tree.artwork)

        guard case .success = result else {
            return XCTFail("Expected success, got \(result)")
        }
        // Artwork dir still exists (recreated) but is empty.
        XCTAssertTrue(fm.fileExists(atPath: tree.artwork.path))
        XCTAssertFalse(fm.fileExists(atPath: artworkFile.path), "Cached artwork should be gone")
        let remaining = try fm.contentsOfDirectory(atPath: tree.artwork.path)
        XCTAssertTrue(remaining.isEmpty, "Artwork dir should be empty after clear")

        // Offline downloads must be completely untouched.
        XCTAssertTrue(fm.fileExists(atPath: tree.downloads.path), "Downloads dir must survive")
        XCTAssertTrue(fm.fileExists(atPath: downloadFile.path), "Downloaded track must survive")
        XCTAssertEqual(try Data(contentsOf: downloadFile), Data("audio".utf8))
    }

    /// Pointing the clear at the caches root must refuse and remove nothing,
    /// returning a failure rather than wiping the tree.
    func testClearRefusesCachesRootAndRemovesNothing() throws {
        let tree = try makeCachesTree()
        defer { try? fm.removeItem(at: tree.caches.deletingLastPathComponent()) }

        let downloadFile = tree.downloads.appendingPathComponent("song.flac")
        try Data("audio".utf8).write(to: downloadFile)

        let result = PreferencesAdvanced.clearArtworkCacheDirectory(at: tree.caches)

        guard case .failure(let error) = result else {
            return XCTFail("Expected failure for caches root, got \(result)")
        }
        XCTAssertTrue(error is PreferencesAdvanced.CacheClearError)
        // Nothing under the caches root may have been touched.
        XCTAssertTrue(fm.fileExists(atPath: tree.downloads.path))
        XCTAssertTrue(fm.fileExists(atPath: downloadFile.path))
        XCTAssertTrue(fm.fileExists(atPath: tree.artwork.path))
    }

    /// A `nil` directory (no on-disk cache configured) is a no-op success — the
    /// in-memory eviction in `clearCaches()` already did the meaningful work.
    func testClearWithNilDirectoryIsSuccess() {
        let result = PreferencesAdvanced.clearArtworkCacheDirectory(at: nil)
        guard case .success = result else {
            return XCTFail("nil directory should be a no-op success, got \(result)")
        }
    }

    /// Clearing a not-yet-created artwork directory still succeeds and leaves an
    /// empty directory ready for the next write.
    func testClearCreatesMissingDirectory() throws {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("PrefAdvCacheTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("com.lyrebird.macos.artwork", isDirectory: true)
        defer { try? fm.removeItem(at: dir.deletingLastPathComponent()) }

        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        let result = PreferencesAdvanced.clearArtworkCacheDirectory(at: dir)
        guard case .success = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "Directory should be recreated")
    }

    /// The refusal error carries a user-readable message so the surfaced alert
    /// isn't blank.
    func testRefusalErrorHasDescription() {
        let error = PreferencesAdvanced.CacheClearError.refusedUnsafePath("/tmp/Caches")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
}
