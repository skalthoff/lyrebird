@preconcurrency import Nuke
import SwiftUI

/// Library preferences pane.
///
/// Minimal shell today — two actions users ask for on every music app:
///
/// 1. **Rescan Library**: re-pulls albums/artists/tracks from the server, the
///    same way the Library tab does on pull-to-refresh. The button is wired
///    to `AppModel.refreshLibrary()` so the action is real even though it's a
///    shallow surface; the longer-horizon work tracked in `TODO(core-#569)`
///    is a server-side metadata rescan trigger (`/Library/Refresh`).
///
/// 2. **Cache size + Clear Cache**: shows the current on-disk footprint of
///    the Nuke artwork cache and lets the user nuke it. Artwork is the
///    single biggest cache in the app (256 MB limit — see `Artwork.swift`),
///    so a visible clear affordance is the pragmatic escape hatch when a
///    user is tight on disk. Full cache sweeps (SDK caches, DB caches) land
///    alongside the broader download-manager work.
///
/// Spec: `research/03-ux-patterns.md` Issue 71.
struct PreferencesLibrary: View {
    @Environment(AppModel.self) private var model

    /// Human-readable representation of the artwork cache size. Refreshed
    /// when the pane appears and after a clear. Initialised as a placeholder
    /// so the text doesn't jump when the first read comes in.
    @State private var cacheSizeLabel: String = "Calculating…"

    /// Toggles the "Rescanning…" label on the button while the refresh is in
    /// flight. Scoped to this view so the Library tab's own spinner isn't
    /// tied to the pane being visible.
    @State private var isRescanning: Bool = false

    /// Set after a successful Clear Cache to acknowledge the action — the
    /// label fades back to normal after a short pause so the button doesn't
    /// stick in a confirmation state forever.
    @State private var justCleared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Refresh",
                footnote: "Rescan pulls the latest albums, artists, tracks, and playlists from your server. The same action runs on pull-to-refresh in the Library tab."
            ) {
                PreferenceRow(
                    label: "Library data",
                    help: isRescanning
                        ? "Refreshing from server…"
                        : "Last refresh ran when you opened the Library tab."
                ) {
                    Button { rescan() } label: {
                        Text(isRescanning ? "Rescanning…" : "Rescan Library")
                            .font(Theme.font(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRescanning || model.session == nil)
                    .accessibilityLabel("Rescan library")
                }
            }

            PreferenceSection(
                title: "Cache",
                footnote: "Jellify keeps album art and artist images on disk so grids render instantly. Clearing the cache frees the space immediately; images re-download on first render."
            ) {
                PreferenceRow(
                    label: "Artwork cache size",
                    help: "Evicts least-recently-used images first. The limit is 256 MB; clearing drops back to zero."
                ) {
                    HStack(spacing: 10) {
                        Text(cacheSizeLabel)
                            .font(Theme.font(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                        Button { clearCache() } label: {
                            Text(justCleared ? "Cleared ✓" : "Clear Cache")
                                .font(Theme.font(13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Theme.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Theme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear artwork cache")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .task { refreshCacheSize() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Refresh server data and manage local caches.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Actions

    /// Kick off the same refresh the Library tab uses. The pane disables the
    /// button while it's in flight so repeat taps don't fan out.
    private func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        Task {
            await model.refreshLibrary()
            isRescanning = false
        }
    }

    /// Evict the shared Nuke pipeline's memory + disk caches. `cache.removeAll`
    /// sweeps every layer (image memory, encoded-image memory, and disk data)
    /// in one call — equivalent to removing each cache individually.
    private func clearCache() {
        Artwork.pipeline.cache.removeAll()
        justCleared = true
        // Give Nuke's background queue a moment to flush before we re-read
        // the footprint. 0.6s is generous — the NSCache eviction is instant,
        // disk removal is a few milliseconds in practice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            refreshCacheSize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                justCleared = false
            }
        }
    }

    /// Read the artwork cache's current on-disk size and render it as
    /// `4.3 MB` / `1.7 GB`. Uses `ByteCountFormatter` so the locale and unit
    /// match every other size-of-thing in macOS.
    ///
    /// The pipeline's `dataCache` is typed as the `DataCaching` protocol so
    /// callers can swap implementations; `totalSize` lives on the concrete
    /// `Nuke.DataCache` Jellify actually uses (wired in
    /// `Artwork.pipeline`). A failed downcast means someone swapped the
    /// cache implementation, so we fall back to a dash rather than a zero.
    ///
    /// `totalSize` walks the cache index (read-after-index is O(n) on the
    /// count of entries, not the bytes), so wrapping the read in a Task keeps
    /// the view's first paint snappy even with a full 256 MB cache. The Task
    /// stays on the main actor because `Artwork.pipeline` and `DataCache` are
    /// both main-actor isolated in this module.
    private func refreshCacheSize() {
        Task { @MainActor in
            let cache = Artwork.pipeline.configuration.dataCache as? DataCache
            let label: String = {
                guard let cache else { return "—" }
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useKB, .useMB, .useGB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: Int64(cache.totalSize))
            }()
            cacheSizeLabel = label
        }
    }
}

#Preview {
    PreferencesLibrary()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
