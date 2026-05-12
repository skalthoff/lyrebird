import SwiftUI

/// Generic, centered empty-state primitive used across the app.
///
/// A single component so every "nothing here yet" surface lands with the same
/// visual weight: a pill-backed SF Symbol illustration, `ink` headline, `ink2`
/// body copy, and up to two CTAs (primary + secondary). Screens should prefer
/// the static factory presets on this type — `firstRunNoLibrary`, `noFavorites`,
/// `noDownloads`, `emptyPlaylist` — so the copy and affordances stay in sync
/// across Library, Home, Playlists, and Downloads.
///
/// This replaces the per-screen one-offs (`EmptyLibraryState`, etc.) going
/// forward; those will be migrated in the next batch when the screens switch
/// over. See issues #99, #100, #297, #298, #299.
///
/// Design tokens: `surface2` pill around the illustration, `border` stroke,
/// `ink` headline, `ink2` body copy. Primary CTA is an amethyst pill to match
/// the player's primary button; secondary CTA is a borderless text button.
struct EmptyStateView: View {
    /// SF Symbol name for the illustration glyph.
    let symbol: String
    /// Short title — "No music yet", "Empty playlist", etc.
    let headline: LocalizedStringKey
    /// Optional descriptive copy below the headline. Use `nil` for surfaces
    /// that are self-explanatory from the headline alone (e.g. "No favorites
    /// yet").
    ///
    /// Named `bodyText` rather than `body` to avoid shadowing `View.body`.
    let bodyText: LocalizedStringKey?
    /// Primary action, rendered as an amethyst pill button. Tuple is
    /// `(label, handler)`.
    let primaryCTA: (LocalizedStringKey, () -> Void)?
    /// Secondary action, rendered below the primary as a borderless text
    /// button. Tuple is `(label, handler)`.
    let secondaryCTA: (LocalizedStringKey, () -> Void)?

    /// Matches the task spec: `init(symbol:headline:body:primaryCTA:secondaryCTA:)`.
    /// Internally stored as `bodyText` so the SwiftUI `body` requirement isn't
    /// shadowed.
    init(
        symbol: String,
        headline: LocalizedStringKey,
        body: LocalizedStringKey? = nil,
        primaryCTA: (LocalizedStringKey, () -> Void)? = nil,
        secondaryCTA: (LocalizedStringKey, () -> Void)? = nil
    ) {
        self.symbol = symbol
        self.headline = headline
        self.bodyText = body
        self.primaryCTA = primaryCTA
        self.secondaryCTA = secondaryCTA
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 112, height: 112)
                .background(Circle().fill(Theme.surface2))
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(headline)
                    .font(Theme.font(22, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                if let bodyText {
                    Text(bodyText)
                        .font(Theme.font(13, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if primaryCTA != nil || secondaryCTA != nil {
                VStack(spacing: 10) {
                    if let primaryCTA {
                        Button(action: primaryCTA.1) {
                            Text(primaryCTA.0)
                                .font(Theme.font(13, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 22)
                                        .fill(Theme.primary.opacity(0.2))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22)
                                        .stroke(Theme.primary, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    if let secondaryCTA {
                        Button(action: secondaryCTA.1) {
                            Text(secondaryCTA.0)
                                .font(Theme.font(12, weight: .semibold))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Factory presets
//
// Each preset pins copy + glyph for a specific canonical empty state. Screens
// should reach for these first — they exist so the visual language stays
// consistent across surfaces and so copy changes land in one place. Callers
// provide the handlers (navigation, refresh, etc.) since this module doesn't
// own routing.

extension EmptyStateView {
    /// First-run state for a freshly-logged-in user whose server has no music
    /// library configured. Matches issue #99. The primary CTA is intended to
    /// bounce the user into the Jellyfin web admin where libraries are
    /// configured; `onChangeLibrary` is wired by the caller.
    static func firstRunNoLibrary(
        onChangeLibrary: @escaping () -> Void
    ) -> EmptyStateView {
        EmptyStateView(
            symbol: "turntable.circle",
            headline: "No music yet",
            body: "Your Jellyfin server doesn't have a music library configured yet. Add one on the server, then come back and refresh.",
            primaryCTA: ("Change Library", onChangeLibrary)
        )
    }

    /// Favorites tab / playlist empty state. Issue #297.
    static func noFavorites() -> EmptyStateView {
        EmptyStateView(
            symbol: "heart",
            headline: "No favorites yet",
            body: "Heart a track, album, or artist and it'll show up here."
        )
    }

    /// Downloads / Offline tab empty state. Issue #298. The download UX
    /// itself is tracked separately (#441) — this is just the empty surface
    /// that tells the user how to get something here.
    static func noDownloads() -> EmptyStateView {
        EmptyStateView(
            symbol: "arrow.down.circle",
            headline: "Nothing offline yet",
            body: "Downloaded tracks will appear here and stay playable without a network connection."
        )
    }

    /// Empty playlist state. Issue #299. Caller provides the "Add tracks"
    /// handler when a playlist supports edits; pass `nil` to render the
    /// read-only variant (e.g. for a smart playlist).
    static func emptyPlaylist(
        onAddTracks: (() -> Void)? = nil
    ) -> EmptyStateView {
        EmptyStateView(
            symbol: "music.note.list",
            headline: "Empty playlist",
            body: "This playlist doesn't have any tracks yet.",
            primaryCTA: onAddTracks.map { ("Add Tracks", $0) }
        )
    }
}

#Preview("First run — no library") {
    EmptyStateView.firstRunNoLibrary(onChangeLibrary: {})
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("No favorites") {
    EmptyStateView.noFavorites()
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("No downloads") {
    EmptyStateView.noDownloads()
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Empty playlist — editable") {
    EmptyStateView.emptyPlaylist(onAddTracks: {})
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Empty playlist — read-only") {
    EmptyStateView.emptyPlaylist()
        .frame(width: 720, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Custom with primary + secondary") {
    EmptyStateView(
        symbol: "sparkles",
        headline: "Nothing to show",
        body: "Try refreshing, or head back to the library.",
        primaryCTA: ("Refresh", {}),
        secondaryCTA: ("Go to Library", {})
    )
    .frame(width: 720, height: 480)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
