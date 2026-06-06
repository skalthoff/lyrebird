import Foundation
@preconcurrency import LyrebirdCore

/// Artwork-URL resolution for `AppModel`: the synchronous per-cell
/// `imageURL(for:tag:maxWidth:)` lookup and the off-main batch
/// `resolveImageURLs(for:maxWidth:)`, both backed by the memoized
/// `imageURLCache` so each (itemID, tag, maxWidth) tuple crosses the
/// UniFFI boundary at most once.
extension AppModel {
    func imageURL(for itemID: String, tag: String?, maxWidth: UInt32 = 400) -> URL? {
        let key = Self.imageURLCacheKey(itemID: itemID, tag: tag, maxWidth: maxWidth)
        if let cached = imageURLCache[key] { return cached }
        let result: URL?
        if let s = try? core.imageUrl(itemId: itemID, tag: tag, maxWidth: maxWidth) {
            result = URL(string: s)
        } else {
            result = nil
        }
        imageURLCache[key] = result
        return result
    }

    /// The `imageURLCache` key for a given (itemID, tag, maxWidth) tuple.
    /// Kept in one place so `imageURL` and `resolveImageURLs` can't drift.
    /// `nonisolated` so the off-main `resolveImageURLs` batch can build keys
    /// inside its `Task.detached` without hopping back to the MainActor.
    nonisolated private static func imageURLCacheKey(
        itemID: String, tag: String?, maxWidth: UInt32
    ) -> String {
        "\(itemID)|\(tag ?? "")|\(maxWidth)"
    }

    /// Resolve a batch of image URLs **off the main thread** and return them
    /// as an `[itemID: URL?]` map, caching each result so a subsequent
    /// `imageURL(for:)` for the same tuple is a pure cache hit.
    ///
    /// Eager carousels (e.g. the artist Discography, which can hold up to
    /// ~200 album tiles) would otherwise call the synchronous `imageURL`
    /// inside each tile body on first render — taking the Rust `Inner` mutex
    /// on the MainActor once per tile, serialized against every background
    /// load (gap pattern #2). Resolving the whole batch in a single
    /// `Task.detached` hop keeps every mutex acquisition off the main thread;
    /// callers then hand each tile its pre-resolved URL so the per-cell sync
    /// FFI never runs. Already-cached tuples are served from the cache and
    /// never re-cross the FFI boundary.
    func resolveImageURLs(
        for items: [(id: String, tag: String?)],
        maxWidth: UInt32 = 400
    ) async -> [String: URL?] {
        var resolved: [String: URL?] = [:]
        var pending: [(id: String, tag: String?)] = []
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            let key = Self.imageURLCacheKey(itemID: item.id, tag: item.tag, maxWidth: maxWidth)
            if let cached = imageURLCache[key] {
                resolved[item.id] = cached
            } else {
                pending.append(item)
            }
        }
        guard !pending.isEmpty else { return resolved }

        let computed = await Task.detached(priority: .userInitiated) { [core] in
            pending.map { item -> (String, String, URL?) in
                let key = Self.imageURLCacheKey(itemID: item.id, tag: item.tag, maxWidth: maxWidth)
                let url = (try? core.imageUrl(itemId: item.id, tag: item.tag, maxWidth: maxWidth))
                    .flatMap(URL.init(string:))
                return (item.id, key, url)
            }
        }.value

        for (id, key, url) in computed {
            imageURLCache[key] = url
            resolved[id] = url
        }
        return resolved
    }
}
