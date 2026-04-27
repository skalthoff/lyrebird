import JellifyCore
import SwiftUI

/// Read-only metadata sheet for a single track — the "Get Info" affordance
/// the macOS Apple Music app surfaces on ⌘I and the right-click menu. Pulls
/// fields straight off the [`Track`] payload returned by the core; no extra
/// FFI round-trip on present.
///
/// What's surfaced (each row hides itself when its source is `nil`/empty so
/// thin metadata doesn't leave gaps):
/// - Album + track number + disc number
/// - Year, runtime
/// - Codec / container + bitrate
/// - Server-side play count
///
/// Edit-in-place / "Edit Info" is tracked separately under #96 — this is
/// the read-only landing pad first. See #95.
struct TrackInfoSheet: View {
    let track: Track
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)
            metadataGrid
            footer
        }
        .frame(width: 420)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Header

    /// Title + artist subtitle. Mirrors the now-playing block typography
    /// so the sheet feels like a smaller version of the full-screen player.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.name)
                .font(Theme.font(18, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text(track.artistName)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: - Metadata grid

    /// Two-column label/value list, top-aligned. Each row collapses when its
    /// source field is empty so the sheet adapts to thin metadata (e.g. a
    /// loose mp3 with no album, no year, no bitrate).
    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let album = track.albumName, !album.isEmpty {
                row(label: "track.info.album", value: album)
            }
            if let trackPosition = trackPositionString {
                row(label: "track.info.track", value: trackPosition)
            }
            if let year = track.year {
                row(label: "track.info.year", value: String(year))
            }
            row(label: "track.info.duration", value: durationString)
            if let format = formatString {
                row(label: "track.info.format", value: format)
            }
            row(label: "track.info.plays", value: String(track.playCount))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// Dismiss-only footer. Edit affordances live under #96 and arrive as a
    /// follow-up, so keeping this sheet read-only avoids implying a feature
    /// that doesn't exist yet.
    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Text("common.done")
                    .font(Theme.font(13, weight: .semibold))
                    .frame(width: 100, height: 32)
                    .foregroundStyle(Theme.bg)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    // MARK: - Helpers

    private func row(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .frame(width: 88, alignment: .leading)
                .accessibilityHidden(true)
            Text(value)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// "3 of 12" / "Disc 2 · 3 of 12" / "3" depending on what's available.
    private var trackPositionString: String? {
        guard let index = track.indexNumber else { return nil }
        let trackNumber = String(index)
        if let disc = track.discNumber {
            return "\(String(localized: "track.info.disc")) \(disc) · \(trackNumber)"
        }
        return trackNumber
    }

    /// `mm:ss` (or `hh:mm:ss` on the rare > 1h track). Jellyfin's `runtime_ticks`
    /// is the Apple-style 100-ns count (`seconds * 10_000_000`); divide once
    /// at present-time so callers don't repeat the math.
    private var durationString: String {
        let totalSeconds = Int(track.runtimeTicks / 10_000_000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// `FLAC · 1042 kbps` / `MP3 · 320 kbps` / `MP3` if bitrate's unknown.
    /// Container is upper-cased so the codec reads at-a-glance; bitrate is
    /// rounded to a nominal kbps from the bps field the server reports.
    private var formatString: String? {
        guard let container = track.container, !container.isEmpty else { return nil }
        let codec = container.uppercased()
        if let bitrate = track.bitrate, bitrate > 0 {
            let kbps = Int((Double(bitrate) / 1000.0).rounded())
            return "\(codec) · \(kbps) kbps"
        }
        return codec
    }
}
