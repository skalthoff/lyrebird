import SwiftUI

/// Lyrics source preference pane.
///
/// Lets the user choose where Lyrebird looks for lyrics:
///
/// - **Jellyfin only** — the default; fetch from the server's lyrics
///   endpoint and render nothing when the server has no match.
/// - **Jellyfin + LRCLib** — try the server first; if it returns no
///   lyrics, silently fall back to lrclib.net (an open, community-
///   maintained sync-lyrics database). The fallback is async, cached
///   per track for the lifetime of the app session, and failure-silent.
/// - **None** — skip all lyrics fetches; the Lyrics tab always shows
///   the "No Lyrics" empty state (useful for metered connections).
///
/// Preference key:
/// - `lyrics.source`  — `LyricsSource` (default `.jellyfinOnly`)
///
/// Issues closed here: #121.
struct PreferencesLyrics: View {
    @AppStorage("lyrics.source") private var sourceRaw: String = LyricsSource.jellyfinOnly.rawValue

    private var source: Binding<LyricsSource> {
        Binding(
            get: { LyricsSource(rawValue: sourceRaw) ?? .jellyfinOnly },
            set: { sourceRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Source",
                footnote: source.wrappedValue.footnote
            ) {
                PreferenceRow(
                    label: "Lyrics source",
                    help: source.wrappedValue.subtitle
                ) {
                    LyricsSourcePicker(selection: source)
                        .accessibilityLabel("Lyrics source")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lyrics")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Where Lyrebird fetches lyrics for the playing track.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

// MARK: - LyricsSource

/// Where Lyrebird looks for lyrics.
///
/// Raw values are stable `@AppStorage` keys — do not rename without
/// a migration. The `label`, `subtitle`, and `footnote` strings are
/// display-only and safe to change.
enum LyricsSource: String, CaseIterable, Identifiable {
    /// Fetch from the Jellyfin server's `/Audio/{id}/Lyrics` endpoint only.
    /// No lyrics returned by the server → empty state.
    case jellyfinOnly = "jellyfinOnly"
    /// Try Jellyfin first; if it returns no match, silently fall back to
    /// lrclib.net. The fallback is async (non-blocking) and cached per
    /// track for the app session. Failures are swallowed — a spinner
    /// never shows.
    case jellyfinPlusLrcLib = "jellyfinPlusLrcLib"
    /// Skip all lyrics fetches. The Lyrics tab always shows the empty state.
    /// Useful on metered connections.
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jellyfinOnly: return "Jellyfin"
        case .jellyfinPlusLrcLib: return "Jellyfin + LRCLib"
        case .none: return "None"
        }
    }

    var subtitle: String {
        switch self {
        case .jellyfinOnly:
            return "Fetch from your Jellyfin server only."
        case .jellyfinPlusLrcLib:
            return "Try Jellyfin first, then lrclib.net as a fallback."
        case .none:
            return "Don't fetch lyrics — always show the empty state."
        }
    }

    var footnote: String {
        switch self {
        case .jellyfinOnly:
            return "The server's /Audio/{id}/Lyrics endpoint is used. Tracks without server-side lyrics show the \"No Lyrics\" placeholder."
        case .jellyfinPlusLrcLib:
            return "The LRCLib fallback runs in the background after a server miss. Results are cached per track so the network is only hit once per track per session. Fetches always fail silently — no error is shown."
        case .none:
            return "No network fetch is made. The Lyrics tab shows the \"No Lyrics\" placeholder for every track."
        }
    }
}

// MARK: - Picker

/// Segmented picker for the three lyrics-source options.
private struct LyricsSourcePicker: View {
    @Binding var selection: LyricsSource

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(LyricsSource.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 380)
    }
}

#Preview {
    PreferencesLyrics()
        .frame(width: 600, height: 400)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
