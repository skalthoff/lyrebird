import Foundation

/// The catalog of customizable Home shelves and the pure ordering / visibility
/// logic behind "Customize Home" (#56).
///
/// Home customization is deliberately **client-only**, mirroring the
/// `PlaylistSidebarOrder` pattern (#317): the user's chosen order and the set
/// of hidden shelves are persisted as two `@AppStorage` strings, and the Home
/// view *renders its sections by sorting this catalog* on every paint. That
/// makes the feature impossible to desync — the stored layout is just a view
/// preference layered over whatever shelves the app ships.
///
/// The hard parts are all set-reconciliation, not UI:
///   * the shipped catalog drifts between app versions (a release adds a new
///     shelf), so the stored order must be reconciled against the current
///     `HomeSection.allCases` on every read — unknown sections append in
///     their declared order, retired ids prune;
///   * the hidden set must likewise drop ids that no longer exist;
///   * a `.onMove` from SwiftUI hands the sheet an `IndexSet` + destination
///     against the *displayed* (already-sorted) order, folded back into a
///     fresh id list to persist.
///
/// All of this is expressed as side-effect-free functions over CSV strings (the
/// `@AppStorage` values) so the contract is unit-testable without booting a
/// SwiftUI scene or touching `UserDefaults`.

// MARK: - Catalog

/// A customizable Home shelf. The raw value is the **stable persistence key** —
/// never rename one without a migration, since it's written into the user's
/// stored layout. Declaration order here *is* the default Home order, matching
/// `HomeView.body`'s shipped stack.
///
/// Only shelves backed by real data sources today are listed. Speculative
/// shelves from the issue's catalog (For [Decade], Top [Genre], Unplayed Gems,
/// High-Rated, Most-Played This Year) join this enum when their loaders land —
/// reconciliation makes them appear at the bottom of an existing user's layout
/// automatically.
enum HomeSection: String, CaseIterable, Identifiable, Codable {
    case recentlyPlayed
    case artistsYouLove
    case recentlyDiscoveredArtists
    case jumpBackIn
    case recentTracks
    case yourPlaylists
    case recentlyAdded
    case rediscover
    case quickPicks
    case suggestions
    case favorites
    case pinnedStations
    case artistRadio

    var id: String { rawValue }

    /// Human-facing title shown in the Customize Home list. Kept in sync with
    /// the section header titles in `HomeView` so the sheet reads like the page.
    var title: String {
        switch self {
        case .recentlyPlayed: return "Recently Played"
        case .artistsYouLove: return "Artists You Love"
        case .recentlyDiscoveredArtists: return "Recently Discovered Artists"
        case .jumpBackIn: return "Jump Back In"
        case .recentTracks: return "Recent Tracks"
        case .yourPlaylists: return "Your Playlists"
        case .recentlyAdded: return "Recently Added"
        case .rediscover: return "Rediscover"
        case .quickPicks: return "Quick Picks"
        case .suggestions: return "You Might Like"
        case .favorites: return "Favorites"
        case .pinnedStations: return "Pinned Stations"
        case .artistRadio: return "Artist Radio"
        }
    }

    /// SF Symbol mirrored from each shelf's header icon, so the sheet row and
    /// the live shelf share a glyph.
    var systemImage: String {
        switch self {
        case .recentlyPlayed: return "clock"
        case .artistsYouLove: return "heart.circle.fill"
        case .recentlyDiscoveredArtists: return "person.crop.circle.badge.plus"
        case .jumpBackIn: return "arrow.uturn.backward"
        case .recentTracks: return "clock.arrow.circlepath"
        case .yourPlaylists: return "music.note.list"
        case .recentlyAdded: return "sparkle"
        case .rediscover: return "binoculars.fill"
        case .quickPicks: return "flame.fill"
        case .suggestions: return "wand.and.sparkles"
        case .favorites: return "heart.fill"
        case .pinnedStations: return "pin.fill"
        case .artistRadio: return "dot.radiowaves.left.and.right"
        }
    }

    /// The default order: the catalog's declaration order. Used as the reset
    /// target and as the reconciliation tail for unknown stored ids.
    static var defaultOrder: [HomeSection] { allCases }
}

// MARK: - Layout codec + reconciliation

/// Pure ordering + visibility logic for the customizable Home stack (#56).
/// Stateless; the view owns the two `@AppStorage` CSV strings and feeds them
/// through here.
enum HomeSectionLayout {

    // MARK: CSV codec

    /// Decode a stored `@AppStorage` CSV into a section list, dropping unknown
    /// raw values (a retired shelf id from a newer→older downgrade) and blank
    /// entries (a stray comma or a freshly-initialised `""`). Section raw values
    /// are bare identifiers and never contain commas, so a plain split is
    /// unambiguous.
    static func decode(_ raw: String) -> [HomeSection] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { HomeSection(rawValue: $0) }
    }

    /// Encode a section list back into the `@AppStorage` CSV value.
    static func encode(_ sections: [HomeSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decode a stored hidden-set CSV into a `Set<HomeSection>`. Same tolerance
    /// for unknown / blank entries as `decode`.
    static func decodeHidden(_ raw: String) -> Set<HomeSection> {
        Set(decode(raw))
    }

    /// Encode a hidden set back into a CSV. Emitted in catalog order so the
    /// stored string is stable across writes (set iteration order isn't).
    static func encodeHidden(_ hidden: Set<HomeSection>) -> String {
        encode(HomeSection.allCases.filter { hidden.contains($0) })
    }

    // MARK: Reconciliation

    /// Reconcile a stored order against the shipped catalog
    /// (`HomeSection.allCases`):
    ///   * sections in both keep their stored relative order;
    ///   * sections shipped but not stored (a new shelf in this app version)
    ///     append in catalog order, so an upgrade lands new shelves at the
    ///     bottom of the user's arrangement rather than reshuffling it;
    ///   * stored ids no longer shipped are pruned;
    ///   * the result is a duplicate-free permutation of the catalog, so
    ///     sorting by it is total.
    static func reconciled(stored: [HomeSection]) -> [HomeSection] {
        let catalog = HomeSection.allCases
        let catalogSet = Set(catalog)
        var seen = Set<HomeSection>()
        var result: [HomeSection] = []
        for section in stored where catalogSet.contains(section) && seen.insert(section).inserted {
            result.append(section)
        }
        for section in catalog where seen.insert(section).inserted {
            result.append(section)
        }
        return result
    }

    /// The fully-resolved order to render: the stored CSV reconciled against the
    /// live catalog. An empty / corrupt stored value yields the default order.
    static func order(stored raw: String) -> [HomeSection] {
        reconciled(stored: decode(raw))
    }

    /// The set of sections the user has hidden, intersected with the live
    /// catalog so a retired id can't strand a phantom hide.
    static func hidden(stored raw: String) -> Set<HomeSection> {
        decodeHidden(raw).intersection(HomeSection.allCases)
    }

    /// The sections to actually render, in order, with hidden ones removed.
    /// The single call `HomeView` makes to lay out its stack.
    static func visibleOrder(order rawOrder: String, hidden rawHidden: String) -> [HomeSection] {
        let hide = hidden(stored: rawHidden)
        return order(stored: rawOrder).filter { !hide.contains($0) }
    }

    // MARK: Move

    /// Fold a SwiftUI `.onMove(source:destination:)` into a fresh stored order.
    /// `displayed` is the list currently shown in the sheet (already reconciled
    /// + sorted); `source` / `destination` are exactly what `.onMove` hands the
    /// view. We persist the *entire* arrangement so the next reconcile is a
    /// straight pass-through.
    static func applyingMove(
        displayed: [HomeSection],
        source: IndexSet,
        destination: Int
    ) -> [HomeSection] {
        var sections = displayed
        sections.move(fromOffsets: source, toOffset: destination)
        return sections
    }

    /// Toggle a section's hidden state, returning the new hidden set.
    static func togglingHidden(
        _ section: HomeSection,
        in hidden: Set<HomeSection>
    ) -> Set<HomeSection> {
        var next = hidden
        if next.contains(section) {
            next.remove(section)
        } else {
            next.insert(section)
        }
        return next
    }
}

// MARK: - AppStorage keys

/// `@AppStorage` keys for the Home customization layout (#56). Grouped in one
/// enum so the sheet and the Home view read/write the same keys without sharing
/// a view, matching `LibraryDefaults` / `PinnedStationsStore`.
enum HomeLayoutDefaults {
    /// CSV of `HomeSection` raw values in the user's chosen order.
    static let sectionOrderKey = "home_section_order"
    /// CSV of `HomeSection` raw values the user has hidden.
    static let sectionHiddenKey = "home_section_hidden"
}
