import SwiftUI

/// Downloads preferences pane.
///
/// Minimal shell today — two surfaces users look for first:
///
/// 1. **Download location** — read-only display of the path where offline
///    copies will land. Today this resolves to
///    `~/Library/Containers/.../Caches/Downloads` via
///    `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)`
///    so the path reads as expected for a sandboxed app. Picking a custom
///    location lands alongside the broader download manager work
///    (`TODO(#570)`).
///
/// 2. **Storage budget slider** — caps total disk space used by offline
///    downloads. 1 GB — 100 GB with a 500 MB step; the chosen value is
///    persisted under `downloads.storageBudgetGb` so the download manager
///    can enforce it once it lands.
///
/// Both surfaces are here now so users can see the feature exists and set
/// their preference in advance — the download manager honours both when
/// `core.download_track` / offline playback ships.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 Downloads bullet.
struct PreferencesDownloads: View {
    @AppStorage("downloads.storageBudgetGb") private var storageBudgetGb: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Location",
                footnote: "Offline copies live inside Lyrebird's cache folder so macOS can evict them under disk pressure."
            ) {
                PreferenceRow(
                    label: "Download location",
                    help: "Cache directory inside Lyrebird's sandbox."
                ) {
                    Text(downloadLocationText)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .accessibilityLabel("Download location: \(downloadLocationText)")
                }
            }

            PreferenceSection(
                title: "Storage",
                footnote: "Budget for offline downloads. When the cap is reached, the download manager stops queuing new tracks and asks you to free space. Oldest-played downloads evict first when auto-prune lands."
            ) {
                PreferenceRow(
                    label: "Storage budget",
                    help: budgetSubtitle
                ) {
                    HStack(spacing: 12) {
                        Slider(value: $storageBudgetGb, in: 1...100, step: 1)
                            .frame(width: 220)
                            .accessibilityLabel("Storage budget")
                            .accessibilityValue("\(Int(storageBudgetGb)) gigabytes")
                        Text(budgetReadout)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloads")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Offline location and storage budget.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Path where offline tracks live. Resolves against the user's cache
    /// directory so the value matches macOS's sandbox expectations. When the
    /// resolver fails (extremely unusual) we show a dash rather than an
    /// empty string so the row stays readable.
    private var downloadLocationText: String {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return "—"
        }
        return caches.appendingPathComponent("Downloads").path
    }

    private var budgetReadout: String {
        "\(Int(storageBudgetGb.rounded())) GB"
    }

    private var budgetSubtitle: String {
        let gb = Int(storageBudgetGb.rounded())
        return "Up to \(gb) GB of disk space reserved for offline music."
    }
}

#Preview {
    PreferencesDownloads()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
