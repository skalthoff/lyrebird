import CoreTransferable
import Foundation
import UniformTypeIdentifiers
@preconcurrency import LyrebirdCore

/// A drag-source that materialises a `.m3u` playlist file when the user drops
/// one or more track rows onto Finder (or any other app that accepts file
/// drops).
///
/// **How it works.** SwiftUI's `Transferable + FileRepresentation` pattern is
/// the recommended replacement for `NSFilePromiseProvider` on macOS 13+: the
/// exporter closure is called once the user completes the drop, on a background
/// thread, so the file can be written asynchronously without blocking the drag
/// gesture. The receiving app gets a real `.m3u` file in a system temp
/// directory — not a phantom promise — so VLC / IINA / Music all open it
/// directly.
///
/// **Stream URL credential.** Each M3U entry embeds the Jellyfin `api_key` so
/// the file is playable in an external player without further authentication
/// (a bare `/universal` path 401s for generic HTTP players — see
/// `PlaylistExport.streamURL`). The key is extracted from `core.streamUrl` on
/// a background thread inside the exporter closure so it never touches the
/// MainActor. When extraction fails the file falls back to auth-free URLs
/// (valid, but will prompt for credentials in the player).
///
/// **File name.** Single-track drags use "<Artist> - <Title>.m3u"; multi-track
/// drags use "Selection (<N> tracks).m3u".
struct TrackM3UDrag: Transferable {
    /// The ordered tracks to include in the exported file.
    let tracks: [Track]
    /// The server base URL (no trailing slash), e.g. `https://music.example.com`.
    let serverURL: String
    /// The LyrebirdCore instance, captured by reference so the exporter can
    /// call `core.streamUrl` off the MainActor inside the `FileRepresentation`
    /// exporter closure. `LyrebirdCore` is a reference-counted FFI object and
    /// is safe to hold across concurrency domains.
    let core: LyrebirdCore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .m3uPlaylist) { drag in
            // Resolve the api_key from the first track's stream URL.  Runs on
            // a background thread (the FileRepresentation exporter is always
            // called off the main actor) so it is safe to cross the UniFFI
            // boundary here.
            let apiKey: String? = drag.resolveApiKey()

            let content = PlaylistExport.m3u8(
                playlistName: drag.suggestedName,
                tracks: drag.tracks,
                serverURL: drag.serverURL,
                apiKey: apiKey
            )

            let tempDir = FileManager.default.temporaryDirectory
            let filename = drag.safeFilename
            let tempURL = tempDir.appendingPathComponent(filename)
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return SentTransferredFile(tempURL)
        }
    }

    // MARK: - Helpers

    /// A human-readable name for the exported file, free of characters that
    /// are illegal in macOS filenames (`/`, `:`, NUL).
    var safeFilename: String {
        sanitize(suggestedName) + ".m3u"
    }

    /// The logical name for the selection — used in the M3U `#PLAYLIST:`
    /// header and as the base of the filename.
    var suggestedName: String {
        if tracks.count == 1, let t = tracks.first {
            return PlaylistExport.displayTitle(for: t)
        }
        return "Selection (\(tracks.count) tracks)"
    }

    /// Extract the `api_key` query parameter from a `core.streamUrl` call on
    /// the first track. Returns `nil` on any failure, in which case the caller
    /// emits auth-free (prompt-on-play) stream URLs.
    ///
    /// Called from the `FileRepresentation` exporter closure which runs on a
    /// background thread — safe to cross the UniFFI boundary directly.
    private func resolveApiKey() -> String? {
        guard let first = tracks.first else { return nil }
        guard let urlString = try? core.streamUrl(
            trackId: first.id,
            mediaSourceId: nil,
            playSessionId: nil,
            maxStreamingBitrate: nil
        ) else { return nil }
        guard let components = URLComponents(string: urlString),
              let key = components.queryItems?.first(where: { $0.name == "api_key" })?.value,
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Replace characters that are illegal or problematic in macOS filenames
    /// with a safe substitute so the temp file can always be created.
    private func sanitize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - UTType extension

extension UTType {
    /// The M3U playlist UTI (`public.m3u-playlist`). Registered by macOS as the
    /// canonical type for `.m3u` and `.m3u8` files. Declared here so the UTI
    /// name is centralised and can't be misspelled at the call site.
    static var m3uPlaylist: UTType {
        // Prefer the well-known system type when available; fall back to a
        // declared type so we don't accidentally use a different UTI.
        UTType(filenameExtension: "m3u") ?? UTType(importedAs: "public.m3u-playlist")
    }
}
