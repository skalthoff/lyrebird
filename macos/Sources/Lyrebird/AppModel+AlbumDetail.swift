import Foundation
@preconcurrency import LyrebirdCore

/// Album detail screen: liner-note hydration plus the album context-menu
/// actions (go to artist/album, album radio, mark played, add to playlist).
extension AppModel {
    /// Fetch the album's hydrated detail fields (label, premiere date, and
    /// aggregated People credits) via `fetch_item`. Returned as a compact
    /// [`AlbumDetail`] value type so the view layer can render the
    /// liner-note credits section (#65) without a second parse pass.
    ///
    /// Silent on errors: the liner-note section degrades to whatever fields
    /// are present on the cached `Album` so a 404 or a stripped-down server
    /// doesn't take down the whole detail page.
    func loadAlbumDetail(albumId: String) async -> AlbumDetail {
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: albumId,
                    fields: ["People", "Studios", "PremiereDate", "DateCreated", "ProductionYear", "Overview"]
                )
            }.value
            return Self.parseAlbumDetail(from: json)
        } catch {
            _ = handleAuthError(error)
            return AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)
        }
    }

    /// Parse the subset of the album item JSON that the liner-note section
    /// cares about. Static + internal so tests can hit it without wiring
    /// the full model. Missing fields become `nil`; the parser never throws.
    static func parseAlbumDetail(from json: String) -> AlbumDetail {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AlbumDetail(label: nil, releaseDate: nil, people: [], overview: nil)
        }

        // Jellyfin ships `Studios` as an array of `{ Name, Id }` objects. Pick
        // the first non-empty label — servers with multiple labels tend to
        // list the primary one first.
        let label: String? = {
            guard let studios = root["Studios"] as? [[String: Any]] else { return nil }
            for entry in studios {
                if let name = entry["Name"] as? String {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }()

        // `PremiereDate` is an ISO 8601 string; fall back to `DateCreated`
        // if absent. We only keep the yyyy-MM-dd portion since the hero
        // already shows the year and the liner-note section wants "Released
        // 19 Apr 2013".
        let releaseDate: Date? = {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for key in ["PremiereDate", "DateCreated"] {
                if let raw = root[key] as? String, !raw.isEmpty {
                    if let d = iso.date(from: raw) { return d }
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) { return d }
                }
            }
            return nil
        }()

        let people: [Person] = {
            guard let raw = root["People"] as? [[String: Any]] else { return [] }
            return raw.compactMap { entry in
                let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let type = (entry["Type"] as? String) ?? ""
                let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let id = rawId.isEmpty ? nil : rawId
                guard !name.isEmpty else { return nil }
                return Person(name: name, type: type, id: id)
            }
        }()

        // Editorial blurb (#68). Kept raw here — the album detail view runs it
        // through the same HTML strip as the artist bio before display.
        // Whitespace-only collapses to `nil` so the "About this album" section
        // never renders an empty shell.
        let overview: String? = {
            guard let raw = root["Overview"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : raw
        }()

        return AlbumDetail(label: label, releaseDate: releaseDate, people: people, overview: overview)
    }

    /// Navigate to the artist detail screen for this album's artist, if known.
    func goToArtist(album: Album) {
        guard let artistID = album.artistId else { return }
        navPath.append(Route.artist(artistID))
    }

    /// Navigate to the album's own detail screen. Used when the menu is
    /// invoked from a surface other than the album detail itself (e.g. a
    /// track row that links back to its album).
    func goToAlbum(album: Album) {
        navPath.append(Route.album(album.id))
    }

    /// Kick off an Instant Mix ("album radio") seeded by this album.
    func startAlbumRadio(album: Album) {
        playInstantMix(seedId: album.id, seedName: album.name)
    }

    /// Mark the album as played server-side. Matches Jellyfin web's
    /// "Mark Played" affordance: the album's `UserData.Played` flips and
    /// `LastPlayedDate` stamps, but per-track `PlayCount` is **not**
    /// incremented (Jellyfin doesn't cascade the operation to children).
    /// `playedById[album.id]` flips immediately for the optimistic glyph
    /// flip, then reconciles with the server's authoritative response. See #133.
    func markAllAsPlayed(album: Album) {
        let target = !isPlayed(id: album.id)
        playedById[album.id] = target
        Task { await setPlayed(itemId: album.id, played: target) }
    }

    /// Append every track on the album to a user-picked playlist. Loads
    /// the tracklist (cached) then routes through the async
    /// `addToPlaylist(trackIds:playlistId:)` path.
    func addAlbumToPlaylist(album: Album, playlist: Playlist) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            await addToPlaylist(trackIds: tracks.map(\.id), playlistId: playlist.id)
        }
    }
}
