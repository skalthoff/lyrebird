import XCTest

@testable import Lyrebird

/// Coverage for the lyric active-line scan that drives the Now Playing inline
/// snippet. The scan resolves the most-recent line at or before the playback
/// position over a timestamp-ordered list.
final class InlineLyricsSnippetTests: XCTestCase {
    private func lines() -> [LyricLine] {
        [
            LyricLine(id: 0, timestamp: 0.0, text: "intro"),
            LyricLine(id: 1, timestamp: 5.0, text: "verse"),
            LyricLine(id: 2, timestamp: 10.0, text: "chorus"),
            LyricLine(id: 3, timestamp: 15.0, text: "outro"),
        ]
    }

    func testBeforeFirstTimestampReturnsNil() {
        XCTAssertNil(InlineLyricsSnippet.activeLineIndex(in: lines(), at: -1.0))
    }

    func testExactTimestampSelectsThatLine() {
        XCTAssertEqual(InlineLyricsSnippet.activeLineIndex(in: lines(), at: 10.0), 2)
    }

    func testBetweenTimestampsSelectsEarlierLine() {
        XCTAssertEqual(InlineLyricsSnippet.activeLineIndex(in: lines(), at: 7.5), 1)
    }

    func testAfterLastTimestampSelectsLastLine() {
        XCTAssertEqual(InlineLyricsSnippet.activeLineIndex(in: lines(), at: 999.0), 3)
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(InlineLyricsSnippet.activeLineIndex(in: [], at: 3.0))
    }

    func testUntimedLinesAreSkipped() {
        let mixed = [
            LyricLine(id: 0, timestamp: nil, text: "[no timestamp]"),
            LyricLine(id: 1, timestamp: 2.0, text: "timed"),
            LyricLine(id: 2, timestamp: nil, text: "[no timestamp]"),
        ]
        XCTAssertEqual(InlineLyricsSnippet.activeLineIndex(in: mixed, at: 3.0), 1)
        XCTAssertNil(InlineLyricsSnippet.activeLineIndex(in: mixed, at: 1.0))
    }
}
