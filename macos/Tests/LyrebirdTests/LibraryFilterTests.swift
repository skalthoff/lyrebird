import XCTest

@testable import Lyrebird

/// Coverage for the pure value logic behind the Library filter popover (#214):
/// format-container matching, duration bucketing, and the active-group count
/// that drives the pink dot on the filter icon. These are deliberately
/// `AppModel`-free — the per-item `passesFilter` predicates that consult the
/// model live on `LibraryView`; here we lock down the standalone primitives.
final class LibraryFilterTests: XCTestCase {

    // MARK: - TrackFormat

    func testFlacMatchesOnlyFlacContainer() {
        XCTAssertTrue(TrackFormat.flac.matches(container: "flac"))
        XCTAssertTrue(TrackFormat.flac.matches(container: "FLAC"))
        XCTAssertFalse(TrackFormat.flac.matches(container: "mp3"))
        XCTAssertFalse(TrackFormat.flac.matches(container: nil))
        XCTAssertFalse(TrackFormat.flac.matches(container: "  "))
    }

    func testAlacMatchesM4aAndMp4Containers() {
        // Jellyfin ships ALAC inside an m4a/mp4 container, so both spellings
        // plus the codec name itself must count.
        XCTAssertTrue(TrackFormat.alac.matches(container: "m4a"))
        XCTAssertTrue(TrackFormat.alac.matches(container: "MP4"))
        XCTAssertTrue(TrackFormat.alac.matches(container: "alac"))
        XCTAssertFalse(TrackFormat.alac.matches(container: "flac"))
    }

    func testMp3MatchesMpegSpelling() {
        XCTAssertTrue(TrackFormat.mp3.matches(container: "mp3"))
        XCTAssertTrue(TrackFormat.mp3.matches(container: "MPEG"))
        XCTAssertFalse(TrackFormat.mp3.matches(container: "aac"))
    }

    // MARK: - DurationBucket

    func testDurationBucketBoundaries() {
        // < 3m
        XCTAssertTrue(DurationBucket.short.matches(seconds: 179))
        XCTAssertFalse(DurationBucket.short.matches(seconds: 180))
        // 3–6m inclusive on both ends
        XCTAssertTrue(DurationBucket.medium.matches(seconds: 180))
        XCTAssertTrue(DurationBucket.medium.matches(seconds: 360))
        XCTAssertFalse(DurationBucket.medium.matches(seconds: 179))
        XCTAssertFalse(DurationBucket.medium.matches(seconds: 361))
        // > 6m
        XCTAssertTrue(DurationBucket.long.matches(seconds: 361))
        XCTAssertFalse(DurationBucket.long.matches(seconds: 360))
    }

    func testDurationBucketsArePartition() {
        // Every positive runtime falls in exactly one bucket.
        for seconds in stride(from: 0.0, through: 1200.0, by: 7.0) {
            let hits = DurationBucket.allCases.filter { $0.matches(seconds: seconds) }
            XCTAssertEqual(hits.count, 1, "seconds=\(seconds) hit \(hits.count) buckets")
        }
    }

    // MARK: - LibraryFilter.activeGroupCount

    func testEmptyFilterIsInactive() {
        let f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.activeGroupCount, 0)
    }

    func testActiveGroupCountCountsEachGroupOnce() {
        var f = LibraryFilter()
        f.genres = ["Rock", "Jazz"]   // one group despite two selections
        f.formats = [.flac, .mp3]     // one group despite two selections
        XCTAssertEqual(f.activeGroupCount, 2)
        XCTAssertTrue(f.isActive)

        f.onlyFavorited = true
        f.yearRange = 1990...2000
        f.durations = [.short]
        XCTAssertEqual(f.activeGroupCount, 5)
    }

    /// `onlyDownloaded` must NOT count toward the active-group total: no
    /// `passesFilter` overload can honor it until a download-state query
    /// exists, and the toggle is UI-gated off, so counting it would light the
    /// dot badge and trip the no-results path while filtering nothing. See
    /// audit L724.
    func testOnlyDownloadedDoesNotMarkFilterActive() {
        var f = LibraryFilter()
        f.onlyDownloaded = true
        XCTAssertEqual(
            f.activeGroupCount, 0,
            "onlyDownloaded is inert until a download-state query lands; it must not count as an active group"
        )
        XCTAssertFalse(
            f.isActive,
            "a filter whose only set flag is the unhonorable onlyDownloaded must read as inactive"
        )
    }

    func testOnlyDownloadedDoesNotInflateAlongsideRealGroups() {
        var f = LibraryFilter()
        f.onlyFavorited = true
        f.genres = ["Rock"]
        let withoutDownloaded = f.activeGroupCount
        f.onlyDownloaded = true
        XCTAssertEqual(
            f.activeGroupCount, withoutDownloaded,
            "toggling the inert onlyDownloaded flag must not change the active-group count"
        )
    }
}
