import Foundation
import Network
import Observation

/// Publishes the system's reachability state. Uses `NWPathMonitor` on a background
/// queue and republishes changes on the main actor so SwiftUI views can bind to
/// `isOnline` without manual dispatch.
///
/// The monitor debounces flaky transitions: a path that reports `satisfied` is
/// only treated as "online" after the state has held steady for a short window.
/// Going offline is applied immediately so the banner surfaces right away.
@Observable
@MainActor
final class NetworkMonitor {
    /// `true` when the system reports a usable network path. Starts `true`
    /// optimistically so the banner does not flash on cold launch.
    var isOnline: Bool = true

    private var monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.jellify.network-monitor")
    private var stableOnlineTask: Task<Void, Never>?

    init() {
        self.monitor = NWPathMonitor()
        start()
    }

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self.apply(satisfied: satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    private func apply(satisfied: Bool) {
        stableOnlineTask?.cancel()
        stableOnlineTask = nil

        if !satisfied {
            // Offline is applied immediately so users see the banner fast.
            if isOnline { isOnline = false }
            return
        }

        // Debounce coming back online to avoid flicker on flaky networks.
        stableOnlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000) // 0.75s
            guard let self, !Task.isCancelled else { return }
            if !self.isOnline { self.isOnline = true }
        }
    }

    /// Force a fresh path evaluation. Cancels the existing monitor and starts a
    /// new one so the next `pathUpdateHandler` fires with a current snapshot.
    func retry() {
        stableOnlineTask?.cancel()
        stableOnlineTask = nil
        monitor.cancel()
        monitor = NWPathMonitor()
        start()
    }
}
