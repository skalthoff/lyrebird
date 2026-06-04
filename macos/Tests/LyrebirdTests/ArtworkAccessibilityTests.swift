import XCTest
import LyrebirdCore

@testable import Lyrebird

/// Guards the decorative-vs-meaningful VoiceOver split on the `Artwork`
/// component (#356).
///
/// `Artwork` is rendered by ~30 surfaces. The overwhelming majority are
/// thumbnails nested inside a card / tile / row whose *parent* already carries
/// a meaningful `.accessibilityLabel`, so the inner image — and especially the
/// seeded-gradient fallback, which has no inherent meaning — must be hidden
/// from VoiceOver to avoid a contentless "image" stop. A handful of hero
/// surfaces (album detail, now-playing, playlist cover) are the dominant
/// identity of their screen and are *not* wrapped in a labelled control, so
/// they opt in as meaningful and supply their own label.
///
/// SwiftUI exposes no public API to introspect `.accessibilityHidden` /
/// `.accessibilityLabel` off a `some View` without booting a scene or pulling
/// in ViewInspector, so this suite asserts two complementary things, mirroring
/// `SwitchControlGroupingTests`:
///   1. behavioural facts off the type (the `decorative` default; the pure
///      now-playing label builder), and
///   2. structural invariants read directly from source (the modifier on the
///      root view; which call sites flip `decorative` and pair it with a
///      label).
/// Each assertion is falsifiable: it fails if the flag default flips, the
/// modifier is dropped, a hero loses its label, or a decorative thumbnail is
/// wrongly marked meaningful.
final class ArtworkAccessibilityTests: XCTestCase {

    // MARK: - Behavioural: default + label builder

    /// The default must stay `decorative: true` so the ~30 thumbnail call
    /// sites that pass no flag inherit hidden-from-VoiceOver behaviour. A flip
    /// to `false` would make every gradient placeholder a spoken "image".
    func testArtworkDefaultsToDecorative() {
        let art = Artwork(url: nil, seed: "Abbey Road")
        XCTAssertTrue(art.decorative,
                      "Artwork must default to decorative:true so nested thumbnails stay hidden from VoiceOver")
    }

    /// A caller can opt a hero in as meaningful.
    func testArtworkCanBeMarkedMeaningful() {
        let art = Artwork(url: nil, seed: "Abbey Road", decorative: false)
        XCTAssertFalse(art.decorative)
    }

    /// The now-playing hero prefers the album name when the server ships one.
    func testNowPlayingLabelUsesAlbumWhenPresent() {
        XCTAssertEqual(
            NowPlayingView.nowPlayingArtworkLabel(trackName: "Come Together", albumName: "Abbey Road"),
            "Album artwork for Abbey Road"
        )
    }

    /// Singles / loose tracks with no album name fall back to the track name
    /// rather than reading an empty "Album artwork for ".
    func testNowPlayingLabelFallsBackToTrackWhenNoAlbum() {
        XCTAssertEqual(
            NowPlayingView.nowPlayingArtworkLabel(trackName: "Strobe", albumName: nil),
            "Artwork for Strobe"
        )
        XCTAssertEqual(
            NowPlayingView.nowPlayingArtworkLabel(trackName: "Strobe", albumName: ""),
            "Artwork for Strobe"
        )
    }

    // MARK: - Source invariant: Artwork.swift

    /// `Artwork` must expose a `decorative` flag defaulting to `true` and apply
    /// `.accessibilityHidden(decorative)` on its composed root so the whole
    /// image (art *and* gradient fallback) is hidden by default.
    func testArtworkDeclaresDecorativeFlagAndAppliesHidden() throws {
        let code = strippingLineComments(try source("Sources/Lyrebird/Components/Artwork.swift"))
        XCTAssertTrue(code.contains("var decorative: Bool = true"),
                      "Artwork must declare `var decorative: Bool = true`")
        XCTAssertTrue(code.contains(".accessibilityHidden(decorative)"),
                      "Artwork must apply `.accessibilityHidden(decorative)` on its root view")
    }

    // MARK: - Source invariant: meaningful call sites are labelled

    /// The album-detail hero is meaningful and must carry its own label.
    func testAlbumDetailHeroIsLabelledMeaningful() throws {
        let code = strippingLineComments(try source("Sources/Lyrebird/Screens/AlbumDetailView.swift"))
        XCTAssertTrue(code.contains("decorative: false"),
                      "AlbumDetailView hero must opt out of decorative")
        XCTAssertTrue(code.contains(".accessibilityLabel(\"Album artwork for \\(album.name)\")"),
                      "AlbumDetailView hero must label the artwork with the album name")
    }

    /// The now-playing hero is meaningful and must carry its computed label.
    func testNowPlayingHeroIsLabelledMeaningful() throws {
        let code = strippingLineComments(try source("Sources/Lyrebird/Screens/NowPlayingView.swift"))
        XCTAssertTrue(code.contains("decorative: false"),
                      "NowPlayingView hero must opt out of decorative")
        XCTAssertTrue(code.contains(".accessibilityLabel(nowPlayingArtworkLabel(for: track))"),
                      "NowPlayingView hero must label the artwork via nowPlayingArtworkLabel(for:)")
    }

    /// The single-image playlist cover fallback must mirror the labelled
    /// collage path so a playlist hero is announced regardless of which branch
    /// renders.
    func testPlaylistCoverFallbackIsLabelledMeaningful() throws {
        let code = strippingLineComments(try source("Sources/Lyrebird/Screens/PlaylistView.swift"))
        XCTAssertTrue(code.contains("decorative: false"),
                      "PlaylistView single-image cover fallback must opt out of decorative")
        // Both the collage container and the single-image fallback read
        // "Playlist artwork".
        let labels = ranges(of: ".accessibilityLabel(\"Playlist artwork\")", in: code).count
        XCTAssertGreaterThanOrEqual(labels, 2,
                      "Both the playlist collage and its single-image fallback must label as 'Playlist artwork'")
    }

    /// Regression guard: decorative thumbnail surfaces must NOT opt out of
    /// decorative. A discography tile / library row / track row already lives
    /// inside a labelled parent, so flipping `decorative: false` there would
    /// re-introduce the redundant "image" announcement #356 removes.
    func testThumbnailSurfacesStayDecorative() throws {
        for path in [
            "Sources/Lyrebird/Components/TrackListRow.swift",
            "Sources/Lyrebird/Components/LibraryListRow.swift",
            "Sources/Lyrebird/Components/ArtistCard.swift",
            "Sources/Lyrebird/Components/HomeAlbumTile.swift",
        ] {
            let code = strippingLineComments(try source(path))
            XCTAssertFalse(code.contains("decorative: false"),
                           "\(path) renders a thumbnail inside a labelled parent and must keep Artwork decorative")
        }
    }

    // MARK: - Helpers

    /// Loads a repo-relative source file. Uses `#filePath` so the lookup is
    /// stable regardless of the runner's working directory.
    private func source(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let target = here
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: target),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read \(relativePath) at \(target.path)", file: file, line: line)
            return ""
        }
        return text
    }

    /// Drops `//`-style line comments so source-invariant assertions match
    /// live code rather than explanatory prose (this component's comments
    /// quote the very modifiers under test).
    private func strippingLineComments(_ src: String) -> String {
        src
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") {
                    return line[line.startIndex..<r.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }
}
