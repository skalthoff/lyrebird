import AppKit
import Nuke
import SwiftUI

/// Owns the custom Dock tile: hosts `DockTileView` inside
/// `NSApp.dockTile.contentView`, keeps it fed with fresh snapshots, and
/// throttles the (manual) `NSApp.dockTile.display()` calls so the tile never
/// redraws more than once a second.
///
/// The Dock tile does **not** auto-redraw — AppKit only repaints it when you
/// call `display()` — and repainting it faster than ~1 Hz spikes CPU. So the
/// controller:
///
///   1. Installs the `NSHostingView` once, lazily, on first update.
///   2. Resolves album art off-screen via the shared Nuke pipeline (cached, so
///      a steady track costs one fetch), then hands the concrete `NSImage`
///      into the view — an async `LazyImage` inside an off-window host would
///      paint its placeholder and never get a second `display()`.
///   3. Coalesces redraws to at most one per second; a progress-only change
///      that arrives early is held and flushed on the next tick, while a
///      track / play-pause change forces an immediate redraw so transport
///      feedback stays snappy.
///   4. Restores the stock app icon on teardown (`uninstall()`), called from
///      `applicationWillTerminate`.
@MainActor
final class DockTileController {
    private var hostingView: NSHostingView<DockTileView>?

    /// Last snapshot actually pushed to the tile, so we can skip redundant
    /// redraws when nothing the tile cares about changed.
    private var lastSnapshot: DockTileSnapshot?

    /// Last `(itemID, tag)` we kicked an artwork fetch for, so a steady track
    /// doesn't re-request the bitmap every second.
    private var artworkKey: String?
    private var artworkImage: NSImage?
    private var artworkTask: Task<Void, Never>?

    /// Wall-clock time of the last `display()`. Used to enforce the ≥1 s gap.
    private var lastDisplay: Date = .distantPast

    /// Pending coalesced redraw fired when a progress-only change arrives
    /// inside the 1 s window.
    private var throttleTask: Task<Void, Never>?

    private let minInterval: TimeInterval = 1.0

    /// All stored properties carry defaults, so construction touches no
    /// main-actor state. `nonisolated` lets `AppDelegate` (an `NSObject`, not
    /// itself main-actor isolated) build the controller in its stored-property
    /// initializer without an `await`.
    nonisolated init() {}

    /// Map raw `(position, duration)` seconds to a `0...1` ring fill. Guards a
    /// zero / negative / unknown duration (returns 0) and clamps a position
    /// that briefly overshoots duration at end-of-track (returns 1). Pure so
    /// it can be unit-tested without touching the live Dock.
    nonisolated static func progressFraction(position: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Build a snapshot from the current player state and refresh the tile.
    /// Cheap to call on every status poll; the throttle does the rate-limiting.
    ///
    /// - Parameters:
    ///   - state / position / duration: current playback status.
    ///   - artworkURL / seed: resolved by the caller (which owns the FFI
    ///     `imageURL` cache) so this controller never crosses the Rust boundary.
    func update(
        hasTrack: Bool,
        isPaused: Bool,
        position: Double,
        duration: Double,
        artworkURL: URL?,
        seed: String
    ) {
        // Nothing playing or loaded → drop back to the stock icon so the Dock
        // doesn't keep showing the last track's art after the queue empties.
        guard hasTrack else {
            uninstall()
            return
        }

        ensureArtwork(url: artworkURL, key: artworkURL?.absoluteString)

        let progress = Self.progressFraction(position: position, duration: duration)
        let snapshot = DockTileSnapshot(
            artwork: artworkImage,
            seed: seed.isEmpty ? DockTileSnapshot.placeholderSeed : seed,
            progress: progress,
            isPaused: isPaused
        )

        // A track / play-pause transition is a "structural" change the user
        // expects to see immediately; a progress tick is not.
        let structuralChange =
            lastSnapshot?.artwork !== snapshot.artwork
            || lastSnapshot?.isPaused != snapshot.isPaused
            || lastSnapshot?.seed != snapshot.seed
        apply(snapshot, force: structuralChange)
    }

    /// Restore the standard Dock icon and tear down the hosting view. Safe to
    /// call repeatedly. Invoked when playback stops and on app termination.
    func uninstall() {
        throttleTask?.cancel()
        throttleTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artworkImage = nil
        lastSnapshot = nil
        hostingView = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    // MARK: - Internals

    /// Resolve album art off the main render path. Skips re-fetching when the
    /// key is unchanged; clears the bitmap when there is no URL so a track
    /// without artwork falls back to the seeded gradient.
    private func ensureArtwork(url: URL?, key: String?) {
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel()
        artworkImage = nil

        guard let url else { return }
        let request = ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: 256, height: 256),
                    unit: .pixels,
                    contentMode: .aspectFill,
                    crop: false,
                    upscale: false
                )
            ]
        )
        artworkTask = Task { [weak self] in
            let image = try? await Artwork.pipeline.image(for: request)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.artworkKey == key else { return }
                self.artworkImage = image
                // Re-push with the freshly-resolved art. Force so the user sees
                // the new cover the instant it decodes, not a second later.
                if var snap = self.lastSnapshot {
                    snap.artwork = image
                    self.apply(snap, force: true)
                }
            }
        }
    }

    /// Push a snapshot to the hosting view and schedule / fire a `display()`,
    /// honouring the 1 s floor unless `force` is set.
    private func apply(_ snapshot: DockTileSnapshot, force: Bool) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        installIfNeeded()
        hostingView?.rootView = DockTileView(snapshot: snapshot)

        let elapsed = Date().timeIntervalSince(lastDisplay)
        if force || elapsed >= minInterval {
            flush()
        } else {
            scheduleFlush(after: minInterval - elapsed)
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard throttleTask == nil else { return }
        throttleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flush() }
        }
    }

    private func flush() {
        throttleTask?.cancel()
        throttleTask = nil
        lastDisplay = Date()
        NSApp.dockTile.display()
    }

    private func installIfNeeded() {
        guard hostingView == nil else { return }
        let host = NSHostingView(rootView: DockTileView(snapshot: lastSnapshot ?? .init(
            artwork: nil,
            seed: DockTileSnapshot.placeholderSeed,
            progress: 0,
            isPaused: false
        )))
        host.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        hostingView = host
        NSApp.dockTile.contentView = host
    }
}
