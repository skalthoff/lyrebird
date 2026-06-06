import Foundation
@preconcurrency import LyrebirdCore

/// `/Items` query construction and JSON→model parsing on `AppModel`:
/// `buildItemsQuery` (the authenticated `GET /Items` request builder) plus the
/// static parsers that turn the `{ Items: [...] }` envelope into typed
/// `Album` / `Artist` / `Track` values (`parse*FromItems` + the per-DTO
/// decoders). No stored state here — extensions of a `@MainActor` type inherit
/// its isolation, so these stay main-actor-bound just like the rest of the
/// class.
extension AppModel {
    /// Build an authenticated `GET /Items` request against the current
    /// session's server. Returns `nil` when there is no session or the
    /// core refuses to hand out an auth header. Keeps the URL
    /// construction boilerplate in one place so each caller can just
    /// specify the filter knobs it cares about.
    func buildItemsQuery(
        includeItemTypes: String,
        sortBy: String,
        sortOrder: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?,
        parentId: String?,
        years: [Int]? = nil,
        tags: [String]? = nil
    ) -> URLRequest? {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return nil }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(
                name: "Fields",
                value: (["Genres", "ProductionYear", "ChildCount", "PrimaryImageAspectRatio", "UserData"] + extraFields)
                    .joined(separator: ",")
            ),
        ]
        if let filters, !filters.isEmpty {
            queryItems.append(URLQueryItem(name: "Filters", value: filters))
        }
        if let minDateLastSaved {
            queryItems.append(URLQueryItem(name: "MinDateLastSaved", value: minDateLastSaved))
        }
        if let parentId, !parentId.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        if let years, !years.isEmpty {
            queryItems.append(
                URLQueryItem(name: "Years", value: years.map(String.init).joined(separator: ","))
            )
        }
        if let tags, !tags.isEmpty {
            queryItems.append(URLQueryItem(name: "Tags", value: tags.joined(separator: "|")))
        }
        comps?.queryItems = queryItems
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parse the `{ Items: [...], TotalRecordCount: ... }` envelope
    /// Jellyfin returns for `/Users/{id}/Items` into our typed `Album`
    /// array. Only the fields `Album` carries are extracted; everything
    /// else is dropped. Returns `[]` on any parse failure.
    static func parseAlbumsFromItems(data: Data) -> [Album] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.albumFromDTO($0) }
    }

    /// Like `parseAlbumsFromItems` but also extracts `UserData.PlayCount`
    /// per item into the returned map.
    static func parseAlbumsWithPlayCounts(data: Data) -> ([Album], [String: UInt32]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return ([], [:]) }
        var albums: [Album] = []
        var plays: [String: UInt32] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let userData = entry["UserData"] as? [String: Any],
               let playCount = userData["PlayCount"] as? Int, playCount > 0 {
                plays[album.id] = UInt32(playCount)
            }
        }
        return (albums, plays)
    }

    /// Parse the bare `BaseItemDto[]` response from
    /// `/Users/{id}/Items/Latest` into an album list + per-album
    /// `DateCreated` map. The NEW badge on `RecentlyAddedTile` reads the
    /// date map.
    static func parseLatestAlbumsWithDates(data: Data) -> ([Album], [String: Date]) {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ([], [:]) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var albums: [Album] = []
        var dates: [String: Date] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let raw = entry["DateCreated"] as? String {
                if let d = iso.date(from: raw) {
                    dates[album.id] = d
                } else {
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) {
                        dates[album.id] = d
                    }
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                }
            }
        }
        return (albums, dates)
    }

    /// Parse a Jellyfin `BaseItemDto` (from a `/Items` response) into the
    /// typed `Album` the core produces. Returns `nil` when the minimum
    /// required fields (`Id`, `Name`) aren't present so we don't render
    /// blank tiles.
    /// Parse `{ Items: [...] }` into typed `Artist` values. Mirror of
    /// `parseAlbumsFromItems` — used by the Favorites screen's "Artists"
    /// section. See `loadFavoriteArtists`.
    static func parseArtistsFromItems(data: Data) -> [Artist] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.artistFromDTO($0) }
    }

    /// Project a Jellyfin `BaseItemDto` into the typed `Artist` shape.
    /// `albumCount` / `songCount` come back from the server when they're
    /// available; defaults to 0 otherwise so the tile count line stays
    /// renderable.
    private static func artistFromDTO(_ entry: [String: Any]) -> Artist? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let albumCount: UInt32 = {
            if let c = entry["AlbumCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let songCount: UInt32 = {
            if let c = entry["SongCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let genres: [String] = (entry["Genres"] as? [String]) ?? []
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        return Artist(
            id: id,
            name: name,
            albumCount: albumCount,
            songCount: songCount,
            genres: genres,
            imageTag: imageTag,
            userData: nil
        )
    }

    private static func albumFromDTO(_ entry: [String: Any]) -> Album? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let id = entry["AlbumArtistId"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let trackCount: UInt32 = {
            if let c = entry["ChildCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let genres: [String] = (entry["Genres"] as? [String]) ?? []
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        // `user_data` landed on `Album` in BATCH-24 — clients that build
        // Albums from a local `BaseItemDto` can pass `nil` to reproduce the
        // old behaviour; callers that have a richer `UserData` projection
        // should populate the struct directly.
        return Album(
            id: id,
            name: name,
            artistName: artistName,
            artistId: artistId,
            year: year,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            genres: genres,
            imageTag: imageTag,
            // DTO parser doesn't request `Fields=UserData`, so the
            // server-authoritative projection is absent here. Favourite /
            // play-count consumers read the legacy convenience mirrors
            // (`isFavorite` / `playCount`) where those are set.
            userData: nil
        )
    }

    /// Parse the `{ Items: [...] }` envelope into typed `Track` values.
    /// Mirrors `parseAlbumsFromItems` but targets audio tracks — used by
    /// `fetchFavoriteTracks` for the Shuffle All Favorites CTA.
    static func parseTracksFromItems(data: Data) -> [Track] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.trackFromDTO($0) }
    }

    /// Turn a `BaseItemDto` (audio track) into the typed `Track` record.
    /// Returns `nil` on missing `Id`/`Name` so blank rows don't land in
    /// the shuffle queue.
    private static func trackFromDTO(_ entry: [String: Any]) -> Track? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let albumId = (entry["AlbumId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let albumName = (entry["Album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let items = entry["ArtistItems"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let indexNumber: UInt32? = {
            if let n = entry["IndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let discNumber: UInt32? = {
            if let n = entry["ParentIndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let userData = entry["UserData"] as? [String: Any]
        let isFavorite = (userData?["IsFavorite"] as? Bool) ?? false
        let playCount: UInt32 = {
            if let c = userData?["PlayCount"] as? Int, c > 0 { return UInt32(c) }
            return 0
        }()
        let container = (entry["Container"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bitrate: Int64? = {
            if let b = entry["Bitrate"] as? Int, b > 0 { return Int64(b) }
            return nil
        }()
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        // `user_data` landed on `Track` in BATCH-24 — see `albumFromDTO`
        // above for the same pattern.
        return Track(
            id: id,
            name: name,
            albumId: albumId,
            albumName: albumName,
            artistName: artistName,
            artistId: artistId,
            indexNumber: indexNumber,
            discNumber: discNumber,
            year: year,
            runtimeTicks: runtimeTicks,
            isFavorite: isFavorite,
            playCount: playCount,
            container: container,
            bitrate: bitrate,
            imageTag: imageTag,
            playlistItemId: nil,
            // DTO parser doesn't request `Fields=UserData`, so the
            // server-authoritative projection is absent. Legacy mirrors
            // `isFavorite` / `playCount` are populated above from whatever
            // the BaseItemDto carried.
            userData: nil
        )
    }
}
