import Foundation

/// Pure logic backing the Now Playing "fact" tagline: builds the rotating
/// quip set from metadata already on the current track and resolves which
/// variant a given wall-clock instant maps to. Kept free of SwiftUI so the
/// string and index logic is unit-testable headlessly.
enum NowPlayingFacts {
    private static let losslessContainers: Set<String> = [
        "flac", "alac", "wav", "aiff", "aif", "ape", "wv",
    ]

    /// Build the quip set from the metadata the track already carries.
    /// Order is the rotation order; empty when nothing is worth saying.
    static func variants(
        playCount: UInt32,
        container: String?,
        lastPlayedAt: String?
    ) -> [String] {
        var facts: [String] = []

        if playCount > 0 {
            facts.append(playCountQuip(playCount))
        }

        if isLossless(container) {
            facts.append("Lossless — you're hearing the master.")
        }

        if let heard = lastHeardQuip(lastPlayedAt) {
            facts.append(heard)
        }

        return facts
    }

    /// Map a wall-clock instant to a stable variant index so every render of
    /// the same 15s timeline slot lands on the same quip regardless of when
    /// the view first appeared.
    static func index(at date: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let slot = Int(date.timeIntervalSinceReferenceDate / 15)
        return ((slot % count) + count) % count
    }

    /// Play-count line whose phrasing scales with how often the track has
    /// been heard, so a single play and a heavy-rotation favorite read
    /// differently.
    static func playCountQuip(_ count: UInt32) -> String {
        switch count {
        case 0: return ""
        case 1: return "You've heard this once."
        case 2...4: return "You've played this \(count) times."
        case 5...24: return "A regular — \(count) plays and counting."
        default: return "On heavy rotation — \(count) plays."
        }
    }

    /// "Last heard …" from the server's `lastPlayedAt`. The spec labels this
    /// "first heard", but the `Track` UserData projection exposes only a
    /// last-played timestamp, so the honest label is surfaced rather than
    /// mislabeling the value.
    static func lastHeardQuip(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: raw)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: raw)
        }
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return "Last heard \(fmt.string(from: date))."
    }

    /// Best-effort lossless detection keyed off the original container codec.
    /// The streamed bitrate is unreliable because Jellyfin reports the lossy
    /// transcode bitrate, so the source container is matched instead.
    static func isLossless(_ container: String?) -> Bool {
        guard let container = container?.lowercased() else { return false }
        return container
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .contains { losslessContainers.contains(String($0)) }
    }
}
