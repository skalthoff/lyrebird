@preconcurrency import Nuke
import SwiftUI

/// Library preferences pane.
///
/// Two halves:
///
/// **Browsing defaults.** Default sort for the Albums and Songs chips,
/// whether numbered track rows show their ordinal, and whether a track's play
/// count appears on hover. These write the `LibraryDefaults.*` keys that
/// `LibraryView`, `Sidebar`, `TrackRow`, and `TrackListRow` read, so a change
/// here reflects in the list views immediately. The default-library picker is
/// surfaced but holds a single option because the server currently exposes one
/// music library; it populates (and becomes selectable) once more than one
/// exists — see the row's footnote.
///
/// **Sidebar sections.** Toggles for each optional "Your Library" row
/// (Favorites / Albums / Artists / Playlists). All default on, so the sidebar
/// is unchanged until the user hides something.
///
/// **Maintenance.** The original Rescan + artwork-cache controls are kept:
///
/// 1. **Rescan Library**: re-pulls albums/artists/tracks from the server, the
///    same way the Library tab does on pull-to-refresh, wired to
///    `AppModel.refreshLibrary()`.
/// 2. **Cache size + Clear Cache**: shows the on-disk footprint of the Nuke
///    artwork cache and lets the user clear it.
///
/// Spec: `research/03-ux-patterns.md` Issue 71.
struct PreferencesLibrary: View {
    @Environment(AppModel.self) private var model

    // MARK: Browsing defaults

    @AppStorage(LibraryDefaults.albumSortKey) private var defaultAlbumSort: LibrarySortOrder = .nameAscending
    @AppStorage(LibraryDefaults.songSortKey) private var defaultSongSort: LibrarySortOrder = .nameAscending
    @AppStorage(LibraryDefaults.showTrackNumbersKey) private var showTrackNumbers = true
    @AppStorage(LibraryDefaults.showPlayCountOnHoverKey) private var showPlayCountOnHover = false

    // MARK: Sidebar sections

    @AppStorage(LibraryDefaults.sidebarShowFavoritesKey) private var sidebarShowFavorites = true
    @AppStorage(LibraryDefaults.sidebarShowAlbumsKey) private var sidebarShowAlbums = true
    @AppStorage(LibraryDefaults.sidebarShowArtistsKey) private var sidebarShowArtists = true
    @AppStorage(LibraryDefaults.sidebarShowPlaylistsKey) private var sidebarShowPlaylists = true

    // MARK: Maintenance state

    /// Human-readable representation of the artwork cache size. Refreshed
    /// when the pane appears and after a clear.
    @State private var cacheSizeLabel: String = "Calculating…"

    /// Toggles the "Rescanning…" label on the button while the refresh is in
    /// flight.
    @State private var isRescanning: Bool = false

    /// Set after a successful Clear Cache to acknowledge the action.
    @State private var justCleared: Bool = false

    /// The sort options offered as a default, per the issue's spec
    /// (Name / Artist / Year / Date Added / Play Count / Random). These map
    /// onto the existing `LibrarySortOrder` cases the Library header already
    /// understands, so a chosen default is a real, applied sort — not a
    /// parallel taxonomy.
    private let defaultSortChoices: [LibrarySortOrder] = [
        .nameAscending, .artist, .yearDescending, .recentlyAdded, .mostPlayed, .random,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Default Library",
                footnote: "Lyrebird browses every music library you can see. A picker appears here once the server exposes more than one — until then there's nothing to choose between."
            ) {
                PreferenceRow(
                    label: "Library",
                    help: "All music libraries on \(model.session?.server.name ?? "your server")."
                ) {
                    Picker("", selection: .constant(0)) {
                        Text("All Libraries").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .disabled(true)
                    .accessibilityLabel("Default library")
                }
            }

            PreferenceSection(
                title: "Default Sort",
                footnote: "Applied the first time you open each list in a session. You can still change the sort from the Library header at any time."
            ) {
                PreferenceRow(
                    label: "Albums",
                    help: "How the Albums list is ordered when you first open it."
                ) {
                    SortDefaultPicker(selection: $defaultAlbumSort, choices: defaultSortChoices)
                        .accessibilityLabel("Default album sort")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Songs",
                    help: "How the Songs list is ordered when you first open it."
                ) {
                    SortDefaultPicker(selection: $defaultSongSort, choices: defaultSortChoices)
                        .accessibilityLabel("Default song sort")
                }
            }

            PreferenceSection(
                title: "Track Lists",
                footnote: "Track numbers show as the leading column on album and playlist track rows. Play counts appear on the trailing edge when you hover a row."
            ) {
                PreferenceRow(
                    label: "Show track numbers",
                    help: showTrackNumbers
                        ? "On — numbered rows show their position."
                        : "Off — the number column is hidden."
                ) {
                    Toggle("", isOn: $showTrackNumbers)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show track numbers")
                }

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 10)

                PreferenceRow(
                    label: "Show play counts on hover",
                    help: showPlayCountOnHover
                        ? "On — hovering a track reveals how many times you've played it."
                        : "Off — play counts stay hidden."
                ) {
                    Toggle("", isOn: $showPlayCountOnHover)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show play counts on hover")
                }
            }

            PreferenceSection(
                title: "Sidebar Sections",
                footnote: "Choose which rows appear under \"Your Library\" in the sidebar. Hidden sections are still reachable from search and detail pages."
            ) {
                sidebarToggle(label: "Favorites", isOn: $sidebarShowFavorites)
                divider
                sidebarToggle(label: "Albums", isOn: $sidebarShowAlbums)
                divider
                sidebarToggle(label: "Artists", isOn: $sidebarShowArtists)
                divider
                sidebarToggle(label: "Playlists", isOn: $sidebarShowPlaylists)
            }

            PreferenceSection(
                title: "Refresh",
                footnote: "Rescan pulls the latest albums, artists, tracks, and playlists from your server. The same action runs on pull-to-refresh in the Library tab."
            ) {
                PreferenceRow(
                    label: "Library data",
                    help: isRescanning
                        ? "Refreshing from server…"
                        : "Last refresh ran when you opened the Library tab."
                ) {
                    Button { rescan() } label: {
                        Text(isRescanning ? "Rescanning…" : "Rescan Library")
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRescanning || model.session == nil)
                    .accessibilityLabel("Rescan library")
                }
            }

            PreferenceSection(
                title: "Cache",
                footnote: "Lyrebird keeps album art and artist images on disk so grids render instantly. Clearing the cache frees the space immediately; images re-download on first render."
            ) {
                PreferenceRow(
                    label: "Artwork cache size",
                    help: "Evicts least-recently-used images first. The limit is 256 MB; clearing drops back to zero."
                ) {
                    HStack(spacing: 10) {
                        Text(cacheSizeLabel)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                        Button { clearCache() } label: {
                            Text(justCleared ? "Cleared ✓" : "Clear Cache")
                                .font(Theme.font(13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Theme.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Theme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear artwork cache")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .task { refreshCacheSize() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Browsing defaults, sidebar sections, and local caches.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Shared divider used between rows inside a section.
    private var divider: some View {
        Divider()
            .background(Theme.border)
            .padding(.vertical, 10)
    }

    /// A single sidebar-section visibility toggle.
    @ViewBuilder
    private func sidebarToggle(label: String, isOn: Binding<Bool>) -> some View {
        PreferenceRow(
            label: label,
            help: isOn.wrappedValue ? "Shown in the sidebar." : "Hidden from the sidebar."
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Show \(label) in sidebar")
        }
    }

    // MARK: - Actions

    /// Kick off the same refresh the Library tab uses.
    private func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        Task {
            await model.refreshLibrary()
            isRescanning = false
        }
    }

    /// Evict the shared Nuke pipeline's memory + disk caches.
    ///
    /// `cache.removeAll()` clears memory synchronously but the disk
    /// `DataCache.removeAll()` only *stages* the deletion and returns instantly
    /// (its files are removed on a background queue). Reading `totalSize` right
    /// away — or after a fixed delay — can therefore still report the old bytes
    /// while the button says "Cleared ✓". So we hop to a detached task,
    /// `flush()` the cache (a synchronous wait for the staged deletion to land),
    /// then read the now-accurate size from that same off-main context.
    private func clearCache() {
        justCleared = true
        Task {
            let label = await Task.detached(priority: .utility) { () -> String in
                Artwork.pipeline.cache.removeAll()
                let dataCache = Artwork.pipeline.configuration.dataCache as? DataCache
                dataCache?.flush()
                return Self.formatCacheSize(dataCache)
            }.value
            cacheSizeLabel = label
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            justCleared = false
        }
    }

    /// Read the artwork cache's current on-disk size and render it as
    /// `4.3 MB` / `1.7 GB`.
    ///
    /// `DataCache.totalSize` enumerates and `stat`s every file on disk — Nuke
    /// documents it as "Requires disk IO, avoid using from the main thread" —
    /// so the walk runs in a detached task and only the resulting label hops
    /// back to the main actor. `DataCache` is `Sendable`, so reading it off the
    /// main thread is safe.
    private func refreshCacheSize() {
        Task {
            let label = await Task.detached(priority: .utility) { () -> String in
                Self.formatCacheSize(Artwork.pipeline.configuration.dataCache as? DataCache)
            }.value
            cacheSizeLabel = label
        }
    }

    /// Format a `DataCache`'s on-disk footprint as a human-readable byte count.
    /// `nil` (no disk cache configured) renders as an em dash. Reads
    /// `totalSize`, so this must run off the main thread.
    nonisolated private static func formatCacheSize(_ cache: DataCache?) -> String {
        guard let cache else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(cache.totalSize))
    }
}

/// Menu picker for a default `LibrarySortOrder`. Renders only the curated
/// `choices` (Name / Artist / Year / Date Added / Play Count / Random) so the
/// default-sort menu stays a short, spec-shaped list rather than exposing all
/// nine header sort modes.
private struct SortDefaultPicker: View {
    @Binding var selection: LibrarySortOrder
    let choices: [LibrarySortOrder]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(choices) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 160)
    }
}

#Preview {
    PreferencesLibrary()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
