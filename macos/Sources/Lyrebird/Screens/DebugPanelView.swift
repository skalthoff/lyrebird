import AppKit
import SwiftUI
import Nuke

/// In-app debug panel (#448). Opened via ⌘⇧D or Help ▸ "Debug Panel".
///
/// Shows a tabbed read-only view of live app state for bug reports:
/// Session, Player, Queue, Cache, Flags, Network, and Logs. The "Copy
/// diagnostic bundle" button serializes the current snapshot as JSON and
/// places it on the clipboard — the first request in every bug report.
///
/// The panel snapshots state on open and on manual refresh rather than
/// observing the model per-frame (CLAUDE.md gap pattern #2). A 5 s
/// background timer keeps the snapshot live while the window is visible;
/// the timer cancels when the window closes. All blocking I/O (disk cache
/// sizes, log store reads) runs in detached tasks inside
/// `AppModel.refreshDebugSnapshot`.
struct DebugPanelView: View {

    @Environment(AppModel.self) private var model

    /// Active tab selection.
    @State private var activeTab: Tab = .session

    /// Auto-refresh timer. Lives in `@State` so it's torn down when this
    /// view is destroyed (window closed), preventing wake-up leaks.
    @State private var refreshTimer: Timer?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            tabContent
        }
        .background(Theme.bg)
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            model.refreshDebugSnapshot()
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Debug Panel")
                .font(Theme.font(18, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)

            Spacer()

            if model.isRefreshingDebugSnapshot {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.ink3)
            }

            Text("Captured \(capturedLabel)")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()

            refreshButton
            copyBundleButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var refreshButton: some View {
        Button {
            model.refreshDebugSnapshot()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                Text("Refresh")
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshingDebugSnapshot)
        .accessibilityLabel("Refresh debug snapshot")
    }

    private var copyBundleButton: some View {
        Button {
            copyDiagnosticBundle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                Text("Copy bundle")
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy diagnostic bundle to clipboard")
    }

    // MARK: - Tab bar + content

    private var tabContent: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.border)
            ScrollView {
                switch activeTab {
                case .session: sessionTab
                case .player:  playerTab
                case .queue:   queueTab
                case .cache:   cacheTab
                case .flags:   flagsTab
                case .network: networkTab
                case .logs:    logsTab
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabBarItem(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(Theme.bgAlt)
    }

    private func tabBarItem(_ tab: Tab) -> some View {
        Button {
            activeTab = tab
        } label: {
            Text(tab.label)
                .font(Theme.font(12, weight: activeTab == tab ? .bold : .medium))
                .foregroundStyle(activeTab == tab ? Theme.primary : Theme.ink3)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    activeTab == tab
                        ? Theme.surface2.clipShape(RoundedRectangle(cornerRadius: 6))
                        : Color.clear.clipShape(RoundedRectangle(cornerRadius: 6))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
    }

    // MARK: - Session tab

    private var sessionTab: some View {
        let s = model.debugSnapshot.session
        return DebugSection(title: "Session") {
            DebugRow(label: "Server URL", value: s.serverURL.isEmpty ? "(not connected)" : s.serverURL)
            DebugRow(label: "Username", value: s.username ?? "(not signed in)")
            DebugRow(label: "User ID (hashed)", value: s.userId ?? "(not signed in)")
            DebugRow(label: "Device ID", value: s.deviceId ?? "(not signed in)")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Player tab

    private var playerTab: some View {
        let p = model.debugSnapshot.player
        return VStack(alignment: .leading, spacing: 20) {
            DebugSection(title: "Playback State") {
                DebugRow(label: "State", value: p.playbackState)
                DebugRow(label: "Position", value: String(format: "%.1f s", p.positionSeconds))
                DebugRow(label: "Volume", value: String(format: "%.0f%%", p.volume * 100))
            }
            DebugSection(title: "Audio Engine") {
                DebugRow(label: "DSP pipeline", value: p.dspPipelineEnabled ? "enabled" : "disabled")
                DebugRow(label: "Offline playback", value: p.offlinePlaybackEnabled ? "enabled" : "disabled")
                DebugRow(label: "Normalization", value: p.normalizationMode)
                DebugRow(label: "Pre-gain", value: String(format: "%+.1f dB", p.preGainDb))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Queue tab

    private var queueTab: some View {
        let q = model.debugSnapshot.queue
        return DebugSection(title: "Queue") {
            DebugRow(label: "Playing from", value: q.currentContextLabel ?? "(none)")
            DebugRow(label: "User-added (Up Next)", value: "\(q.userAddedCount) items")
            DebugRow(label: "Auto-queue tail", value: "\(q.autoQueueCount) items")
            DebugRow(label: "Total queue length", value: "\(q.totalQueueLength) items")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cache tab

    private var cacheTab: some View {
        let c = model.debugSnapshot.cache
        return VStack(alignment: .leading, spacing: 20) {
            DebugSection(title: "Library Cache") {
                DebugRow(label: "Albums", value: "\(c.albumsLoaded) / \(c.albumsTotal)")
                DebugRow(label: "Artists", value: "\(c.artistsLoaded) / \(c.artistsTotal)")
                DebugRow(label: "Tracks", value: "\(c.tracksLoaded) / \(c.tracksTotal)")
                DebugRow(label: "Playlists", value: "\(c.playlistsLoaded) / \(c.playlistsTotal)")
            }
            DebugSection(title: "Artwork Cache (Nuke)") {
                DebugRow(label: "Disk cache", value: c.nukeDiskCacheSizeLabel ?? "…")
                DebugRow(label: "Memory cache", value: c.nukeMemoryCacheSizeLabel ?? "…")
            }
            DebugSection(title: "Database") {
                DebugRow(label: "SQLite (main + WAL + SHM)", value: c.sqliteDbSizeLabel ?? "…")
            }
            clearArtworkCacheButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clearArtworkCacheButton: some View {
        Button {
            clearArtworkCache()
        } label: {
            Text("Clear image cache")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear image cache")
    }

    // MARK: - Flags tab

    private var flagsTab: some View {
        let f = model.debugSnapshot.flags
        return VStack(alignment: .leading, spacing: 20) {
            DebugSection(title: "Capabilities") {
                DebugFlagRow(label: "Downloads", value: f.supportsDownloads)
                DebugFlagRow(label: "Mark played", value: f.supportsMarkPlayed)
                DebugFlagRow(label: "Artist play / shuffle", value: f.supportsArtistPlayShuffle)
                DebugFlagRow(label: "Track info", value: f.supportsTrackInfo)
                DebugFlagRow(label: "Genre actions", value: f.supportsGenreActions)
                DebugFlagRow(label: "Streaming bitrate", value: f.supportsStreamingBitrate)
                DebugFlagRow(label: "Stream quality selection", value: f.supportsStreamQualitySelection)
                DebugFlagRow(label: "Crossfade", value: f.supportsCrossfade)
                DebugFlagRow(label: "Playlist search", value: f.supportsPlaylistSearch)
                DebugFlagRow(label: "Language selection", value: f.supportsLanguageSelection)
                DebugFlagRow(label: "Theme selection", value: f.supportsThemeSelection)
            }
            DebugSection(title: "UserDefaults flags") {
                DebugFlagRow(label: "DSP pipeline (\(f.engineDSPDefaultsKey))", value: f.supportsEngineDSP)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Network tab

    private var networkTab: some View {
        let n = model.debugSnapshot.network
        return DebugSection(title: "Network") {
            DebugFlagRow(label: "Online", value: n.isOnline)
            DebugRow(label: "Quality hint", value: n.qualityHint)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Logs tab

    private var logsTab: some View {
        let lines = model.debugSnapshot.logs.lines
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last \(lines.count) entries from subsystem \(Log.subsystem)")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                Spacer()
            }
            if lines.isEmpty {
                Text("(no log entries)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(logLineColor(line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var capturedLabel: String {
        let ts = model.debugSnapshot.capturedAt
        guard ts.timeIntervalSince1970 > 1 else { return "—" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: ts)
    }

    private func logLineColor(_ line: String) -> Color {
        if line.contains("[player]") { return Theme.teal }
        if line.contains("[net]")    { return Theme.warning }
        if line.contains("[auth]")   { return Theme.danger }
        return Theme.ink3
    }

    private func copyDiagnosticBundle() {
        let json = model.debugSnapshot.jsonString()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    private func clearArtworkCache() {
        // Capture main-actor-isolated references before hopping off.
        // This mirrors the pattern in `PreferencesLibrary.clearCache`.
        Artwork.pipeline.cache.removeAll()
        let dataCache = Artwork.pipeline.configuration.dataCache as? DataCache
        Task {
            await Task.detached(priority: .utility) { [dataCache] in
                dataCache?.flush()
            }.value
            model.refreshDebugSnapshot()
        }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                // Only auto-refresh if no manual refresh is already in flight.
                if !self.model.isRefreshingDebugSnapshot {
                    self.model.refreshDebugSnapshot()
                }
            }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Tab enum

    enum Tab: CaseIterable {
        case session, player, queue, cache, flags, network, logs

        var label: String {
            switch self {
            case .session: return "Session"
            case .player:  return "Player"
            case .queue:   return "Queue"
            case .cache:   return "Cache"
            case .flags:   return "Flags"
            case .network: return "Network"
            case .logs:    return "Logs"
            }
        }
    }
}

// MARK: - Sub-components

/// A titled section card with a `content` block.
private struct DebugSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.2)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            )
        }
    }
}

/// A single key-value row within a `DebugSection`.
private struct DebugRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(minWidth: 160, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}

/// A boolean flag row with a tinted dot indicator.
private struct DebugFlagRow: View {
    let label: String
    let value: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(value ? Theme.teal : Theme.danger.opacity(0.7))
                .frame(width: 7, height: 7)

            Text(label)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(minWidth: 153, alignment: .leading)

            Text(value ? "true" : "false")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(value ? Theme.teal : Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityLabel("\(label): \(value ? "enabled" : "disabled")")
    }
}
