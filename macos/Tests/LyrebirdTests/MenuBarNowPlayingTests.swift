import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the menu-bar Now Playing rendering decisions: the
/// idle-vs-playing panel branch, the centre transport play↔pause icon swap,
/// and the status-bar label's at-a-glance icon.
///
/// Each decision is exercised through a pure static helper
/// (`MenuBarNowPlaying.showsNowPlaying`, `MenuBarNowPlaying.transportIcon`,
/// `MenuBarNowPlayingLabel.icon(for:)`) so the precedence is verified without
/// realizing a live SwiftUI view or a window-server connection, which a
/// headless test run doesn't have.
final class MenuBarNowPlayingTests: XCTestCase {

    private func makeTrack(name: String = "Song") -> Track {
        Track(
            id: "t1",
            name: name,
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - Idle vs. now-playing panel

    func testShowsIdleWhenNoTrack() {
        XCTAssertFalse(
            MenuBarNowPlaying.showsNowPlaying(currentTrack: nil),
            "with no current track the panel must fall back to the idle state"
        )
    }

    func testShowsNowPlayingWhenTrackPresent() {
        XCTAssertTrue(
            MenuBarNowPlaying.showsNowPlaying(currentTrack: makeTrack()),
            "a current track must render the rich now-playing card"
        )
    }

    // MARK: - Centre transport icon

    func testTransportIconShowsPauseWhilePlaying() {
        XCTAssertEqual(
            MenuBarNowPlaying.transportIcon(isPlaying: true),
            "pause.fill",
            "while playing, the centre button offers pause"
        )
    }

    func testTransportIconShowsPlayWhilePaused() {
        XCTAssertEqual(
            MenuBarNowPlaying.transportIcon(isPlaying: false),
            "play.fill",
            "while not playing, the centre button offers play"
        )
    }

    // MARK: - Status-bar label icon

    func testLabelIconIsWaveformWhilePlaying() {
        XCTAssertEqual(
            MenuBarNowPlayingLabel.icon(for: .playing),
            "waveform",
            "the label animates a waveform while audio is running"
        )
    }

    func testLabelIconIsRestingNoteWhenNotPlaying() {
        for state: PlaybackState in [.idle, .loading, .paused, .stopped, .ended] {
            XCTAssertEqual(
                MenuBarNowPlayingLabel.icon(for: state),
                "music.note",
                "the label rests on music.note for the non-playing state \(state)"
            )
        }
    }
}
