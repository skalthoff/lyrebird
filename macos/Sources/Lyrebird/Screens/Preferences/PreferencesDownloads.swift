import SwiftUI

/// Downloads preferences pane (#819).
///
/// Two surfaces, both now wired to the core download engine when
/// `supportsDownloads` is live:
///
/// 1. **Download location** — read-only display of the resolved directory
///    offline copies land in (`core.downloadDirPath()`), falling back to the
///    sandbox cache path when the feature is dormant.
///
/// 2. **Storage budget slider** — caps total disk used by completed downloads.
///    1 GB – 100 GB; the chosen value is persisted under
///    `downloads.storageBudgetGb` *and* pushed to the core via
///    `setDownloadBudget(gigabytes:)`, which the engine enforces (evict/refuse)
///    on the next download.
///
/// When the feature is live the pane also shows current usage (used of budget,
/// item count) read from `core.downloadStats()`.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 Downloads bullet.
struct PreferencesDownloads: View {
    @Environment(AppModel.self) private var model
    @AppStorage("downloads.storageBudgetGb") private var storageBudgetGb: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Location",
                footnote: "Offline copies live inside Lyrebird's data folder so they survive relaunches."
            ) {
                PreferenceRow(
                    label: "Download location",
                    help: "Directory offline audio is written to."
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
                footnote: "Budget for offline downloads. When the cap is reached, the oldest-downloaded tracks are evicted to make room; a track larger than the whole budget is refused."
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
                            .onChange(of: storageBudgetGb) { _, newValue in
                                // Push the new cap to the engine so it's enforced
                                // on the next download. No-op while the feature
                                // is dormant.
                                model.setDownloadBudget(gigabytes: newValue)
                            }
                        Text(budgetReadout)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                if model.supportsDownloads {
                    PreferenceRow(
                        label: "Used",
                        help: "Disk space currently used by completed downloads."
                    ) {
                        Text(usageText)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                            .accessibilityLabel("Storage used: \(usageText)")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .task {
            // Seed the core's budget from the persisted slider value and pull
            // current usage so the pane shows real numbers on open. Both no-op
            // while `supportsDownloads` is false.
            model.setDownloadBudget(gigabytes: storageBudgetGb)
            await model.refreshDownloadStats()
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

    /// Path where offline tracks live. When the downloads feature is live this
    /// is the engine's resolved directory; otherwise it falls back to the
    /// sandbox cache path so the row stays meaningful before the feature ships.
    private var downloadLocationText: String {
        if model.supportsDownloads {
            let resolved = model.downloadDirectoryPath()
            if !resolved.isEmpty { return resolved }
        }
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

    /// "1.2 GB of 10 GB · 14 tracks" style usage readout, formatted from the
    /// core's `DownloadStats`. Falls back to a zero readout before the first
    /// stats refresh.
    private var usageText: String {
        let stats = model.downloadStats
        let used = stats?.usedBytes ?? 0
        let count = Int(stats?.itemCount ?? 0)
        let usedStr = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
        let budgetStr = "\(Int(storageBudgetGb.rounded())) GB"
        let trackWord = count == 1 ? "track" : "tracks"
        return "\(usedStr) of \(budgetStr) · \(count) \(trackWord)"
    }
}
