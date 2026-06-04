import Foundation
@preconcurrency import LyrebirdCore

/// Pure, side-effect-free serializers behind the playlist Share / Export
/// affordances (#237). Kept free of `AppModel`, `NSSavePanel`, and the Rust
/// FFI so the string-building logic is unit-testable in isolation — the only
/// inputs are an already-loaded `[Track]`, the playlist name, and the raw
/// server URL string.
///
/// Two export formats plus a sharable deep link:
///   - **M3U** (`#EXTM3U` + `#EXTINF`) — the de-facto playlist interchange
///     format every desktop player understands.
///   - **JSON** — a stable, machine-readable manifest of the playlist for
///     re-import / backup / scripting.
///   - **Deep link** — the Jellyfin web `details` route, with any embedded
///     credentials and query/fragment secrets stripped so the URL is safe to
///     paste into a chat.
///
/// `AppModel` owns the IO (track fetch, `NSSavePanel`, pasteboard); this type
/// owns only the bytes.
enum PlaylistExport {

    // MARK: - Stream URL

    /// The auth-free universal-stream path for a track, e.g.
    /// `https://server.example.com/Audio/<id>/universal`. No query parameters
    /// and no `api_key`, so the resulting M3U is safe to share even though it
    /// references the origin server. Servers that allow unauthenticated
    /// download (common on LAN setups) can play it directly; others will
    /// prompt for auth, which is the correct behaviour for a shared file.
    static func streamURL(forTrackId trackId: String, base: String) -> String {
        "\(base)/Audio/\(trackId)/universal"
    }

    // MARK: - M3U

    /// Build an extended-M3U (`.m3u8`) document for `playlist` from its
    /// already-loaded `tracks`.
    ///
    /// `runtimeTicks` is in 100-nanosecond units; `#EXTINF` wants whole
    /// seconds, so we integer-divide by 10,000,000. A track with unknown
    /// runtime (0 ticks) emits `#EXTINF:-1`, the M3U convention for
    /// "duration unknown", rather than a misleading `0`.
    ///
    /// The document always ends with a trailing newline so appending to it /
    /// concatenating files behaves.
    static func m3u8(playlistName: String, tracks: [Track], serverURL: String) -> String {
        let base = normalizedBase(serverURL)
        var lines: [String] = ["#EXTM3U"]
        // A comment header naming the playlist — ignored by players, but makes
        // the file self-describing when opened in a text editor.
        lines.append("#PLAYLIST:\(sanitizedLine(playlistName))")
        for track in tracks {
            let seconds = track.runtimeTicks > 0 ? Int(track.runtimeTicks / 10_000_000) : -1
            let title = displayTitle(for: track)
            lines.append("#EXTINF:\(seconds),\(sanitizedLine(title))")
            lines.append(streamURL(forTrackId: track.id, base: base))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    /// Build a stable JSON manifest for `playlist` from its already-loaded
    /// `tracks`. Keys are sorted and the output is pretty-printed so the file
    /// is diff-friendly and human-readable. Durations are emitted in whole
    /// seconds (mirroring the M3U `#EXTINF` convention) rather than raw ticks.
    ///
    /// The schema is intentionally small and self-contained — id, name, and an
    /// ordered `tracks` array — so a future "Import Playlist" path can round-
    /// trip it without depending on the server's full item projection.
    static func json(playlistId: String, playlistName: String, tracks: [Track]) throws -> String {
        let manifest = PlaylistManifest(
            schema: "lyrebird.playlist/v1",
            id: playlistId,
            name: playlistName,
            trackCount: tracks.count,
            tracks: tracks.map(TrackManifest.init(track:))
        )
        let encoder = JSONEncoder()
        // Sorted keys + pretty-print → deterministic, reviewable output.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Deep link

    /// Jellyfin web URL for an item id, e.g.
    /// `https://server.example.com/web/#/details?id=<id>`. The web UI uses the
    /// same `details` route for albums, artists, and playlists.
    ///
    /// **Secret stripping (#237):** the stored server URL is whatever the user
    /// typed at login, which can carry embedded credentials
    /// (`https://user:pass@host`) or a stray query/fragment. We rebuild the URL
    /// from `scheme://host[:port]/path` only, so the copied link never leaks a
    /// password or token. Returns `nil` when `serverURL` is empty or can't be
    /// parsed into a scheme + host.
    static func webURL(serverURL: String, itemId: String) -> URL? {
        guard let base = sanitizedOrigin(serverURL) else { return nil }
        return URL(string: "\(base)/web/#/details?id=\(itemId)")
    }

    // MARK: - Helpers

    /// A user-facing "Artist - Title" label for a track, falling back to the
    /// bare title when the artist is blank so we never emit a dangling " - ".
    static func displayTitle(for track: Track) -> String {
        let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? track.name : "\(artist) - \(track.name)"
    }

    /// Trim a trailing slash from the raw server URL so path concatenation
    /// doesn't produce a double slash. Does not strip credentials — used for
    /// the stream-URL base where the host is the same origin the app is
    /// already authenticated against.
    private static func normalizedBase(_ serverURL: String) -> String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    /// Rebuild a credential-free origin (`scheme://host[:port][/path]`) from a
    /// raw server URL, dropping any `user:password@` userinfo, query, and
    /// fragment. The trailing slash is removed so callers can append `/web/...`
    /// cleanly. Returns `nil` if the string lacks a scheme or host.
    private static func sanitizedOrigin(_ serverURL: String) -> String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty
        else { return nil }

        // Drop everything that could carry a secret.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var origin = "\(scheme)://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        // Preserve any sub-path the server is mounted under (reverse proxies),
        // minus a trailing slash.
        var path = components.path
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        origin += path
        return origin
    }

    /// Collapse newlines / carriage returns to spaces so a track title or
    /// playlist name can't inject extra M3U directive lines.
    private static func sanitizedLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - JSON manifest shapes

/// Top-level JSON export shape. `Codable` so the same type can back a future
/// import path. `schema` is a version tag so importers can branch on format
/// changes without sniffing the payload.
struct PlaylistManifest: Codable, Equatable {
    let schema: String
    let id: String
    let name: String
    let trackCount: Int
    let tracks: [TrackManifest]
}

/// Per-track JSON export shape. A deliberately small projection of `Track`:
/// the stable identifiers plus the human-readable metadata needed to re-resolve
/// or display the entry. Optional fields are omitted from the output when nil
/// (default `JSONEncoder` behaviour) to keep the manifest compact.
struct TrackManifest: Codable, Equatable {
    let id: String
    let name: String
    let artist: String?
    let album: String?
    let albumId: String?
    let durationSeconds: Int

    init(track: Track) {
        self.id = track.id
        self.name = track.name
        let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.isEmpty ? nil : artist
        self.album = track.albumName
        self.albumId = track.albumId
        self.durationSeconds = track.runtimeTicks > 0 ? Int(track.runtimeTicks / 10_000_000) : 0
    }
}
