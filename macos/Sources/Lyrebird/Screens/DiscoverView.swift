import SwiftUI

/// Discover — the "find something new" surface. Today: a header + Instant Mix
/// CTA (#248) and a horizontal "For You" carousel (#249). Richer
/// recommendations (recently added, more like this, genre tiles, etc.) land
/// in follow-ups.
///
/// Title is italic 34pt, subline 14pt `ink2`, right-aligned primary "Start
/// Instant Mix" + ghost "Generate new mix" — per `06-screen-specs.md`.
struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                forYouSection
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    /// The "For You" recommendations carousel (#249). Today this mirrors
    /// `recentlyPlayed` via `AppModel.refreshForYou()` — a deliberate
    /// stand-in until the core grows a real recommendations endpoint.
    /// Hidden when there is nothing to show so we do not punch a blank hole
    /// in the layout for a brand-new user who has not listened to anything.
    @ViewBuilder
    private var forYouSection: some View {
        if !model.forYou.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("For You")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Picks based on what you have been playing")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(model.forYou, id: \.id) { track in
                            RecentlyPlayedTile(track: track)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DISCOVER")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                Text("Discover")
                    .font(Theme.font(34, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("A fresh mix seeded from your library — press play and keep going.")
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

                Button {
                    model.regenerateInstantMix()
                } label: {
                    Text("Generate new mix")
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
            }
        }
    }

    /// "Song Radio" CTA, the Discover-screen twin of `TrackContextMenu`'s
    /// "Start Song Radio". Kept always-enabled rather than disabled-when-idle so
    /// the surface never presents a dead button: with no current track it seeds
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
