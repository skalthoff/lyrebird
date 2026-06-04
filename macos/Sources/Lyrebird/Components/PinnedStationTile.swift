import SwiftUI

/// A lightweight, locally-persisted record of a station the user has pinned
/// to their Home / Radio page. This is a *placeholder model* — the real pin
/// infrastructure (server-backed or MMKV-equivalent at `LyrebirdStorage.pinned_stations`)
/// hasn't been built yet. Until it lands we serialize an array of these to
/// `@AppStorage("pinned_stations")` as JSON so the row has a real shape to
/// render against.
///
/// Once the pin FFI exists (tracked in #253 / follow-ups), this struct and
/// its `AppStorage` decoder get replaced with the core-backed source of
/// truth; the tile / row UI shouldn't need to change.
struct PinnedStation: Codable, Hashable, Identifiable {
    /// Station kind. Mirrors the conceptual categories in `06-screen-specs.md §9`
    /// (Artist Radio, Song Radio, Genre/Decade/Mood Radio, plus playlist-style
    /// "mixes"). Raw strings keep the stored JSON forward-compatible.
    enum Kind: String, Codable {
        case artist
        case playlist
        case mood
        case genre
        case mix
    }

    let type: Kind
    /// Upstream identifier — an artist/playlist/genre id when we have one, or
    /// a synthetic slug for placeholder mixes ("todays-mix", etc.).
    let id: String
    let title: String
}

/// Horizontal tile for the Pinned Stations row on Home (#253). Displays a
/// pulsing "on air" dot, the station name in italic 20pt, and a short
/// subtitle ("42 tracks · updated today"-style). Tapping the tile runs the
/// row's `action`, which `HomeView.handleStationTap` routes to the station's
/// subject (browse the genre, open the playlist, or start a seeded radio).
struct PinnedStationTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let station: PinnedStation
    /// Opaque subtitle text — e.g. "42 tracks · updated today". Kept as a
    /// free-form string so we don't have to fake `trackCount` / `updatedAt`
    /// before the real model exists.
    var subtitle: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var dotPulse = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                onAirRow
                VStack(alignment: .leading, spacing: 6) {
                    Text(station.title)
                        .font(Theme.font(20, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 220, height: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Theme.surface2, Theme.surface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering ? Theme.accent : Theme.border,
                        lineWidth: isHovering ? 2 : 1
                    )
            )
            .shadow(
                color: isHovering ? Theme.accent.opacity(0.25) : .clear,
                radius: 12
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Play \(station.title)")
        .accessibilityLabel("\(station.title), pinned station")
        .accessibilityHint("Starts the \(station.title) station")
    }

    /// The "on air" indicator: a hot-accent dot that pulses like a tally light,
    /// next to the kind label. Pulse disabled under Reduce Motion.
    private var onAirRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.accentHot)
                .frame(width: 8, height: 8)
                .scaleEffect(dotPulse ? 1.15 : 0.85)
                .shadow(color: Theme.accentHot.opacity(0.6), radius: dotPulse ? 6 : 2)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        dotPulse = true
                    }
                }
            Text("ON AIR")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(2)
            Spacer()
            Text(kindLabel)
                .font(Theme.font(10, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
        }
    }

    private var kindLabel: String {
        switch station.type {
        case .artist: return "ARTIST"
        case .playlist: return "PLAYLIST"
        case .mood: return "MOOD"
        case .genre: return "GENRE"
        case .mix: return "MIX"
        }
    }
}

// MARK: - Local persistence

/// JSON-encoded `@AppStorage` bridge for the pinned-stations list. Declared as
/// a free helper so both the Home row and any future pin-toggle control can
/// read/write the same key without sharing a view.
///
/// This is a placeholder store — it lives entirely in `UserDefaults` under
/// `"pinned_stations"`. When the real store lands (`LyrebirdStorage.pinned_stations`
/// or a core-backed equivalent), this enum becomes the adapter.
enum PinnedStationsStore {
    static let defaultsKey = "pinned_stations"

    /// Decode the current list. Returns `[]` on missing / corrupt data — we
    /// would rather start clean than crash the Home screen if an older build
    /// wrote a stale shape.
    static func load() -> [PinnedStation] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([PinnedStation].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func save(_ stations: [PinnedStation]) {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
