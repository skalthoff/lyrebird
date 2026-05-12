import SwiftUI
@preconcurrency import LyrebirdCore

/// Small pill badge showing the container format of a track (e.g. "FLAC",
/// "MP3"). Hovering reveals a tooltip with codec + bitrate detail when
/// available. Hidden when neither `container` nor `bitrate` are present.
///
/// Designed for inline use next to the track name in `TrackRow` and
/// `TrackListRow`. Typography and colour tokens follow the design spec so the
/// badge reads as a secondary annotation rather than a call-to-action.
struct FormatBadge: View {
	let track: Track

	/// Upper-cased display label derived from the container string.
	private var label: String? {
		guard let raw = track.container?.trimmingCharacters(in: .whitespaces),
			  !raw.isEmpty else { return nil }
		return raw.uppercased()
	}

	/// Tooltip text shown on hover. Includes bitrate when available.
	/// Format: "FLAC" or "MP3 · 320 kbps"
	private var tooltipText: String? {
		guard let lbl = label else { return nil }
		if let kbps = bitrateKbps {
			return "\(lbl) · \(kbps) kbps"
		}
		return lbl
	}

	/// Bitrate rounded to the nearest 10 kbps for display clarity.
	private var bitrateKbps: Int? {
		guard let raw = track.bitrate, raw > 0 else { return nil }
		let kbps = Int(raw) / 1000
		// Round to nearest 10 for lossless (avoids "1411 kbps" → "1410 kbps")
		// but keep the exact value for lossy where precision matters.
		if kbps < 400 {
			// Lossy range — round to nearest 10 for tidy display
			return (kbps / 10) * 10 == 0 ? kbps : (kbps + 5) / 10 * 10
		}
		return kbps
	}

	var body: some View {
		if let lbl = label, let tip = tooltipText {
			Text(lbl)
				.font(Theme.font(9, weight: .semibold))
				.foregroundStyle(Theme.ink3)
				.padding(.horizontal, 5)
				.padding(.vertical, 2)
				.background(
					RoundedRectangle(cornerRadius: 3)
						.fill(Theme.surface)
						.overlay(
							RoundedRectangle(cornerRadius: 3)
								.stroke(Theme.border, lineWidth: 0.5)
						)
				)
				.help(tip)
				.accessibilityLabel("Format: \(tip)")
		}
	}
}

#Preview("Format badge variants") {
	VStack(alignment: .leading, spacing: 12) {
		// FLAC with bitrate
		FormatBadge(track: Track(
			id: "1", name: "Track", albumId: nil, albumName: nil,
			artistName: "Artist", artistId: nil, indexNumber: nil,
			discNumber: nil, year: nil, runtimeTicks: 0,
			isFavorite: false, playCount: 0,
			container: "flac", bitrate: 1_411_000, imageTag: nil,
			playlistItemId: nil, userData: nil
		))
		// MP3 with bitrate
		FormatBadge(track: Track(
			id: "2", name: "Track", albumId: nil, albumName: nil,
			artistName: "Artist", artistId: nil, indexNumber: nil,
			discNumber: nil, year: nil, runtimeTicks: 0,
			isFavorite: false, playCount: 0,
			container: "mp3", bitrate: 320_000, imageTag: nil,
			playlistItemId: nil, userData: nil
		))
		// Container only, no bitrate
		FormatBadge(track: Track(
			id: "3", name: "Track", albumId: nil, albumName: nil,
			artistName: "Artist", artistId: nil, indexNumber: nil,
			discNumber: nil, year: nil, runtimeTicks: 0,
			isFavorite: false, playCount: 0,
			container: "aac", bitrate: nil, imageTag: nil,
			playlistItemId: nil, userData: nil
		))
		// No container — badge hidden
		FormatBadge(track: Track(
			id: "4", name: "Track", albumId: nil, albumName: nil,
			artistName: "Artist", artistId: nil, indexNumber: nil,
			discNumber: nil, year: nil, runtimeTicks: 0,
			isFavorite: false, playCount: 0,
			container: nil, bitrate: nil, imageTag: nil,
			playlistItemId: nil, userData: nil
		))
	}
	.padding(16)
	.background(Theme.bg)
}
