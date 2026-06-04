import Foundation

/// Inflected count strings ("1 album" / "2 albums") backed by the String
/// Catalog's plural variations (#350).
///
/// Before this, count subtitles were assembled with hand-rolled ternaries
/// scattered across a dozen views — `count == 1 ? "1 track" : "\(count) tracks"`
/// or, worse, the `"track\(count == 1 ? "" : "s")"` suffix trick. Those
/// don't localize (the English rule is hardcoded at every call site) and they
/// quietly disagree with each other on edge cases. This funnels every count
/// label through a single `String(localized:)` lookup against a `%lld`-keyed
/// plural variation in `Localizable.xcstrings`, so the catalog owns the
/// singular/plural rule and translators get the per-language plural categories
/// for free.
///
/// ### Why a helper instead of inline `Text("count.tracks \(n)")`?
///
/// The interpolation form works for a bare `Text`, but most call sites need a
/// plain `String`: they join several counts with `" · "` into one subtitle
/// (`GenreDetailView`, `FavoritesView`), feed an `.accessibilityLabel`, or
/// embed the count inside a larger sentence. A `String`-returning helper covers
/// all of those uniformly, and keeps the catalog key in exactly one place per
/// noun so a typo can't silently fall back to the raw key in one view but not
/// another.
///
/// ### Testability
///
/// Mirrors `LyrebirdErrorPresenter`: the bundle lookup (`label(_:_:)`) can't be
/// exercised headlessly because SwiftPM strips the `.xcstrings` catalog from
/// the unit-test binary (resources are copied into the `.app` by
/// `make-bundle.sh`, not the test bundle), so a `String(localized:)` call there
/// returns the raw key rather than the inflected value. The English plural
/// *rule* therefore lives in `pluralCategory(for:)` and the key routing in
/// `Noun.key` / `key(_:)`, both pure and unit-tested, while the catalog lookup
/// is a thin one-liner over them.
enum CountStrings {
    /// The countable nouns the app pluralizes. Each maps to a `%lld`-keyed
    /// plural variation in `Localizable.xcstrings`.
    enum Noun: CaseIterable {
        case albums
        case artists
        case items
        case playlists
        case plays
        case results
        case selected
        case songs
        case tracks

        /// The catalog key carrying this noun's plural variations. The trailing
        /// `%lld` is the format placeholder the String Catalog substitutes the
        /// count into; it's part of the key by Xcode convention.
        var key: String {
            switch self {
            case .albums: return "count.albums %lld"
            case .artists: return "count.artists %lld"
            case .items: return "count.items %lld"
            case .playlists: return "count.playlists %lld"
            case .plays: return "count.plays %lld"
            case .results: return "count.results %lld"
            case .selected: return "count.selected %lld"
            case .songs: return "count.songs %lld"
            case .tracks: return "count.tracks %lld"
            }
        }
    }

    /// The CLDR plural category an English count selects. English distinguishes
    /// only `one` (exactly 1) from `other` (everything else, including 0 and
    /// negatives), which is precisely what the catalog's `en` variations encode.
    ///
    /// Exposed (and unit-tested) so the selection rule has coverage that
    /// doesn't depend on the catalog being present in the test bundle. Other
    /// languages have richer category sets (e.g. `zero`, `few`, `many`); those
    /// are the catalog's responsibility per locale, not this function's.
    enum PluralCategory {
        case one
        case other
    }

    /// The English plural category for `count`.
    static func pluralCategory(for count: Int) -> PluralCategory {
        count == 1 ? .one : .other
    }

    /// The catalog key for `noun`. Thin pass-through to `Noun.key`, provided so
    /// call sites and tests can route through one symbol.
    static func key(_ noun: Noun) -> String {
        noun.key
    }

    /// An inflected, localized count label, e.g. `label(1, .albums) == "1 album"`
    /// and `label(2, .albums) == "2 albums"` in English. The count is formatted
    /// by the catalog's `%lld` placeholder, so it inherits the locale's grouping
    /// behaviour for the integer itself.
    ///
    /// The `LocalizationValue` is built by *interpolating* the count
    /// (`"count.tracks \(count)"`) rather than substituting it into the key
    /// string. Interpolation records the count as a `%lld` argument so the
    /// String Catalog can run plural selection on it; baking the digit into the
    /// key (`"count.tracks 2"`) would miss the variation and return the raw key.
    static func label(_ count: Int, _ noun: Noun) -> String {
        String(localized: localizationValue(count, noun), bundle: .main)
    }

    /// Builds the interpolated `LocalizationValue` for `noun` carrying `count`
    /// as its `%lld` argument. Split out so `label(_:_:)` stays a one-liner and
    /// the per-noun key prefixes live next to `Noun.key` for easy auditing.
    private static func localizationValue(_ count: Int, _ noun: Noun) -> String.LocalizationValue {
        switch noun {
        case .albums: return "count.albums \(count)"
        case .artists: return "count.artists \(count)"
        case .items: return "count.items \(count)"
        case .playlists: return "count.playlists \(count)"
        case .plays: return "count.plays \(count)"
        case .results: return "count.results \(count)"
        case .selected: return "count.selected \(count)"
        case .songs: return "count.songs \(count)"
        case .tracks: return "count.tracks \(count)"
        }
    }
}
