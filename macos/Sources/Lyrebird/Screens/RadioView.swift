import SwiftUI
@preconcurrency import LyrebirdCore

/// Radio / Mixes — the dedicated "press play and keep going" surface (#93).
///
/// This screen does not introduce any new radio mechanic; it *aggregates* the
/// radio surfaces that already live scattered across Home and Discover into one
/// destination reachable from the sidebar:
///
/// - **Instant Mix** + **Song Radio** CTAs in the header — the same actions the
///   Discover header drives (`startInstantMix` / `regenerateInstantMix` /
///   `presentInstantMixPicker` / `startDiscoverSongRadio`).
/// - **Artist Radio** — the circular `ArtistRadioTile` row from Home, seeded by
///   the same `radioArtists` fallback (library artists until the
///   favorites/top-listened signals in #133/#229 land).
/// - **Genre / Decade / Mood radio** — the shared `RadioStationRows` component
///   (#256), reused verbatim so the stations read identically here and on
///   Discover.
///
/// All of the heavy lifting (the `.task`-driven genre/mood probes, the
/// per-tile artwork resolution, the Instant Mix FFI dispatch) already lives in
/// the reused components and `AppModel`, so this screen stays a thin composition
/// layer with no synchronous FFI on the render path.
struct RadioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                artistRadioSection
                RadioStationRows()
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RADIO")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                Text("sidebar.nav.radio")
                    .font(Theme.font(34, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("Endless stations and mixes from your library — pick one and keep going.")
                    .font(Theme.font(14, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
            Spacer()
            HStack(spacing: 10) {
                songRadioButton

                Button {
                    model.startInstantMix()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                        Text("Start Instant Mix")
                            .font(Theme.font(13, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Theme.accent)
                    )
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .help("Start an Instant Mix from your library")

                Button {
                    model.presentInstantMixPicker()
                } label: {
                    Text("Pick a seed…")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .stroke(Theme.borderStrong, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Choose a song, album, artist, or genre to seed a mix")
            }
        }
    }

    /// "Song Radio" CTA — the Radio-screen twin of Discover's button and
    /// `TrackContextMenu`'s "Start Song Radio". Kept always-enabled so the
    /// surface never presents a dead button: with no current track it seeds
    /// from `startInstantMix`'s own library fallback instead.
    private var songRadioButton: some View {
        let current = model.status.currentTrack
        return Button {
            model.startDiscoverSongRadio()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Song Radio")
                        .font(Theme.font(13, weight: .bold))
                    if let current {
                        Text(current.name)
                            .font(Theme.font(10, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .stroke(Theme.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(
            current.map { "Start a radio station based on \($0.name)" }
                ?? "Start a radio station from your library"
        )
        .accessibilityLabel(
            current.map { "Song Radio, based on \($0.name)" } ?? "Song Radio"
        )
        .accessibilityHint("Starts a radio station seeded by the current song")
    }

    // MARK: - Artist Radio

    /// Circular "<Artist> Radio" tiles, lifted from Home (#254). Hidden when
    /// there are no artists to seed from so a brand-new library never shows a
    /// blank band.
    @ViewBuilder
    private var artistRadioSection: some View {
        let artists = radioArtists
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("Artist Radio")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Tap to start a radio station")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                // Eager `HStack` (not `LazyHStack`) per the rc9 macOS 26.4
                // `LazyHStack` UAF noted in CLAUDE.md — `ArtistRadioTile` does
                // the same on Home.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(artists, id: \.id) { artist in
                            ArtistRadioTile(artist: artist)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Artist Radio")
        }
    }

    /// Artists to surface as radio seeds. Mirrors Home's `radioArtists`: the
    /// favorites (#133) and top-listened (#229) signals aren't wired in the
    /// core yet, so this falls through to the library's first few artists.
    /// Capped at 20 so the horizontal row doesn't grow unbounded once the
    /// richer signals are available.
    private var radioArtists: [Artist] {
        Array(model.artists.prefix(20))
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.15), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 80)
        .frame(height: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }
}
