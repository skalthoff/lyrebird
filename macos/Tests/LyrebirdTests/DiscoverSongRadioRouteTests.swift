import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Discover-screen "Song Radio" CTA routing (#255).
///
/// The button is always enabled and must never dead-end: with a current track
/// it seeds a station from that track; with nothing playing it falls through to
/// the Instant Mix library seed. `startDiscoverSongRadio()` returns the branch
/// it took so we can assert the decision without reaching into the FFI (the
/// actual `core.instantMix` hop runs in a detached task and fails fast on this
/// un-authed core — the routing decision returns synchronously first).
///
/// Same isolation contract as `MiniPlayerStateTests`: `AppModel` is
/// `@MainActor` and boots a live core pointed at a throwaway data dir.
@MainActor
final class DiscoverSongRadioRouteTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-songradio-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "",
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

    private func status(currentTrack: Track?) -> PlayerStatus {
        PlayerStatus(
            state: currentTrack == nil ? .idle : .playing,
            currentTrack: currentTrack,
            positionSeconds: 0,
            durationSeconds: 0,
            volume: 1,
            queuePosition: 0,
            queueLength: 0,
            shuffle: false,
            repeatMode: .off,
            playSessionId: nil
        )
    }

    func testRoutesToSongRadioWhenATrackIsPlaying() throws {
        let model = try AppModel()
        model.status = status(currentTrack: makeTrack("now-playing"))

        XCTAssertEqual(
            model.startDiscoverSongRadio(),
            .songRadio,
            "with a current track the CTA must seed Song Radio from it"
        )
    }

    /// The reviewer-flagged fallthrough: nothing playing must NOT dead-end the
    /// button — it falls through to the Instant Mix library seed instead.
    func testFallsThroughToInstantMixWhenNothingIsPlaying() throws {
        let model = try AppModel()
        model.status = status(currentTrack: nil)

        XCTAssertEqual(
            model.startDiscoverSongRadio(),
            .instantMix,
            "with no current track the CTA must fall through to Instant Mix, not no-op"
        )
    }
}
