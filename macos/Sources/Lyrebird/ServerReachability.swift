import Foundation
import Network
import Observation
@preconcurrency import LyrebirdCore

/// Tracks whether the Jellyfin server is currently responding successfully.
///
/// This is a *separate* signal from `NetworkMonitor.isOnline` — the system may
/// be online (Wi-Fi up, DNS resolving) while the Jellyfin endpoint itself
/// returns 5xx, refuses connections, or times out. The server-unreachable
/// banner surfaces that second failure mode without conflating it with a
/// network outage.
///
/// Debounce policy: a single 500 from the server should not flash the banner.
/// `noteFailure()` records a timestamp in a rolling window; the reachability
/// flag flips only after `failureThreshold` failures accumulate inside
/// `failureWindow`. A single `noteSuccess()` clears the window and restores
/// reachability immediately — when the server starts answering, users
/// should not have to wait for a decay timer before the banner disappears.
@Observable
@MainActor
final class ServerReachability {
    /// `true` when the server appears to be answering. Starts optimistically
    /// so the banner does not flash on cold launch before the first request.
    var isServerReachable: Bool = true

    /// Number of failures required inside `failureWindow` to flip the flag.
    /// Chosen to tolerate a single transient 500 while still catching a
    /// sustained outage within a couple of seconds of user-visible activity.
    let failureThreshold: Int = 3

    /// Rolling window (seconds) used to evaluate `failureThreshold`.
    let failureWindow: TimeInterval = 10

    /// Timestamps of recent failures inside the rolling window. Trimmed on
    /// every `noteFailure` / `noteSuccess` call so it stays bounded.
    private var recentFailures: [Date] = []

    /// Record a server failure. Timestamps older than `failureWindow` are
    /// discarded; once the count reaches `failureThreshold` the flag flips
    /// to `false`. Callers should use `classifyError` to decide whether a
    /// thrown error counts as a server failure before calling this.
    func noteFailure(at now: Date = Date()) {
        recentFailures.append(now)
        trim(now: now)
        if recentFailures.count >= failureThreshold && isServerReachable {
            isServerReachable = false
        }
    }

    /// Record a successful server interaction. Clears the failure window and
    /// restores reachability immediately — a single good response is strong
    /// evidence the endpoint is healthy again. Also stamps
    /// `LastConnectedStore` so the login screen can fall back on a
    /// "last connected {date}" hint after repeated failures (see #203).
    func noteSuccess() {
        recentFailures.removeAll(keepingCapacity: true)
        if !isServerReachable { isServerReachable = true }
        LastConnectedStore.noteSuccess()
    }

    /// Reset to the optimistic state. Used by the Retry CTA so the banner
    /// disappears while the user waits for the refetch to resolve.
    func reset() {
        recentFailures.removeAll(keepingCapacity: true)
        isServerReachable = true
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-failureWindow)
        recentFailures.removeAll { $0 < cutoff }
    }

    /// Decide whether a thrown error should be treated as a server-reachability
    /// failure. Returns `true` for network-level errors (connection refused,
    /// timeout), HTTP 5xx responses from the server, and 429 rate-limit
    /// responses. 401/403/404 responses are *not* treated as reachability
    /// failures — they signal a client/auth problem, not that the endpoint
    /// is down.
    ///
    /// Post-BATCH-24 the Rust `LyrebirdError` is a typed enum split by HTTP
    /// class, so we no longer need to parse the legacy
    /// `"server returned an error: <status> <body>"` message to recover the
    /// status code. `Server` now carries only 5xx / unclassified failures
    /// (401/403/404/429 have their own variants).
    static func shouldCount(error: Error) -> Bool {
        guard let err = error as? LyrebirdError else { return false }
        switch err {
        case .Network, .Server, .RateLimit:
            return true
        default:
            return false
        }
    }
}

// MARK: - Server discovery (Bonjour / mDNS)

/// A Jellyfin server discovered on the local network via Bonjour (mDNS).
///
/// Populated from `_jellyfin._tcp` advertisements — each resolved service
/// becomes one `DiscoveredServer` carrying a display name (the NetService
/// name) and a URL built from the resolved host + port. Advertised services
/// without a usable address are skipped, so consumers can render the array
/// directly without extra filtering.
struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
}

/// Browses the local network for Jellyfin servers advertising over Bonjour.
///
/// Jellyfin's self-hosting docs recommend advertising the server's HTTP
/// endpoint under the `_jellyfin._tcp` service type; this browser subscribes
/// to that type and publishes resolved results as `DiscoveredServer`s on the
/// main actor. Results are cached for the session — `start()` is idempotent,
/// and the browser stays live while the login/onboarding flow is on screen
/// so late-arriving advertisements still appear.
///
/// Uses `NWBrowser` (Network.framework) instead of the older `NetService` API
/// because `NWBrowser` delivers change sets on a dispatch queue and handles
/// add/remove transitions explicitly — which keeps the published `servers`
/// array stable even when the mDNS responder reflows (e.g. on Wi-Fi
/// transitions).
@Observable
@MainActor
final class ServerDiscovery {
    /// All currently-visible Jellyfin servers on the LAN. Sorted by name for
    /// a stable dropdown order. Empty until `start()` completes its first
    /// browse result; consumers check `.isEmpty` to decide whether to render
    /// the dropdown at all.
    private(set) var servers: [DiscoveredServer] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.lyrebird.server-discovery")

    /// Start browsing for `_jellyfin._tcp` advertisements. Idempotent — a
    /// second call is a no-op when a browse is already in flight. Safe to
    /// call from `.onAppear`; the view doesn't need to stash a handle.
    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_jellyfin._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results: results)
            }
        }
        browser.start(queue: queue)
    }

    /// Stop the browser and clear the published list. Called from
    /// `.onDisappear` so a login/onboarding session that outlives the view
    /// doesn't keep the radio active.
    func stop() {
        browser?.cancel()
        browser = nil
        servers = []
    }

    private func apply(results: Set<NWBrowser.Result>) {
        var collected: [DiscoveredServer] = []
        for result in results {
            let (name, seedURL) = extract(result: result)
            guard !name.isEmpty else { continue }
            collected.append(
                DiscoveredServer(id: name, name: name, url: seedURL)
            )
        }
        servers = collected
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pull a friendly name + best-effort URL out of an `NWBrowser.Result`.
    ///
    /// Bonjour browses deliver `.service` endpoints until the consumer
    /// resolves them by opening a connection. We skip the resolve step
    /// (the login form immediately probes the URL with the core anyway)
    /// and synthesise a `.local` URL using the service name plus the port
    /// advertised in the TXT record if available, else Jellyfin's stock
    /// 8096. Users can always edit the URL field before submit.
    private func extract(result: NWBrowser.Result) -> (name: String, seedURL: String) {
        let name: String
        switch result.endpoint {
        case .service(let serviceName, _, _, _):
            name = serviceName
        case .hostPort(let host, _):
            name = hostString(from: host)
        default:
            name = ""
        }
        // TXT record may carry an explicit port; Jellyfin servers advertised
        // via the standard `_jellyfin._tcp` service type default to 8096.
        var port: UInt16 = 8096
        if case let .bonjour(txt) = result.metadata {
            if let advertised = txt.dictionary["port"], let p = UInt16(advertised) {
                port = p
            }
        }
        let scheme = (port == 443) ? "https" : "http"
        let host = "\(name).local"
        let seedURL = name.isEmpty ? "" : "\(scheme)://\(host):\(port)"
        return (name, seedURL)
    }

    private func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let s, _):
            return s
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            return "\(addr)"
        @unknown default:
            return ""
        }
    }
}

// MARK: - Server URL probe (inline validation)

/// Outcome of a `ServerProbe` run. `.idle` is the initial state before the
/// user has typed a URL that looks submittable; `.checking` drives the
/// "Checking…" affordance; `.ok` carries the server version/name for the
/// success row; `.failed` carries a user-facing message for the error row.
enum ServerProbeState: Equatable {
    case idle
    case checking
    case ok(version: String, name: String)
    case failed(message: String)
}

/// Debounces server URL validation against `core.probeServer`.
///
/// The login and onboarding forms both want "start typing → wait ~400ms after
/// the user stops → probe the server → surface version or error" behaviour.
/// Rather than build that debounce inline in each view, this observable owns
/// the cancellation loop and publishes a single `state` the view binds to.
/// A single call to `schedule(url:)` cancels any in-flight probe and kicks
/// off a fresh one after the debounce window.
///
/// The probe runs on a detached Task at `userInitiated`, so even a slow
/// server doesn't block the main actor while typing.
@Observable
@MainActor
final class ServerProbe {
    /// Current state. `.idle` until `schedule` fires the first real probe.
    private(set) var state: ServerProbeState = .idle

    /// Debounce window after the last keystroke before hitting the server.
    /// 400ms matches the issue spec — long enough to avoid probing on every
    /// character of a paste, short enough that the user sees feedback within
    /// ~1s of pausing.
    private let debounceNanos: UInt64 = 400_000_000

    private var task: Task<Void, Never>?
    private weak var core: LyrebirdCore?

    func configure(core: LyrebirdCore) {
        self.core = core
    }

    /// Schedule a probe for the given URL. Cancels any pending probe.
    /// When the URL doesn't look like a submittable address (no scheme or no
    /// host yet), the state is reset to `.idle` instead of probing — that way
    /// the "Checking…" row doesn't flash on the first few keystrokes.
    func schedule(url: String) {
        task?.cancel()
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard ServerProbe.looksSubmittable(trimmed) else {
            state = .idle
            return
        }
        let core = self.core
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 400_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.state = .checking }
            guard let core else {
                await MainActor.run {
                    self?.state = .failed(message: "Couldn't reach server")
                }
                return
            }
            do {
                let server = try await Task.detached(priority: .userInitiated) {
                    try core.probeServer(url: trimmed)
                }.value
                if Task.isCancelled { return }
                let version = server.version ?? "unknown"
                await MainActor.run {
                    self?.state = .ok(version: version, name: server.name)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.state = .failed(message: "Couldn't reach server")
                }
            }
        }
    }

    /// Clear the probe state. Called when the URL field is emptied so the
    /// validation row disappears.
    func reset() {
        task?.cancel()
        state = .idle
    }

    /// Return `true` when the URL has enough shape to bother probing. We
    /// accept either an explicit `http(s)://host` or a bare `host[:port]`
    /// since many Jellyfin users memorise an IP + port, not a full URL.
    /// The core's `probeServer` normalises either shape internally.
    static func looksSubmittable(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return true
        }
        // Bare "host" or "host:port" — treat a dot or colon followed by
        // something as enough signal to probe.
        return url.contains(".") || url.contains(":")
    }
}

// MARK: - Last-connected tracking

/// Tiny persisted store for "when did we last successfully reach the server?".
///
/// Drives the #203 "Last connected {date}. Trying offline mode." message on
/// the login screen after repeated unreachable failures. Stored in
/// `UserDefaults` because it's a UI hint, not a trust-sensitive fact — the
/// core already owns auth/keychain state.
enum LastConnectedStore {
    private static let defaultsKey = "macos.lastSuccessfulServerContact"

    static func noteSuccess(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: defaultsKey)
    }

    static var lastSuccess: Date? {
        UserDefaults.standard.object(forKey: defaultsKey) as? Date
    }

    /// Relative, user-friendly phrase like "3 days ago". Returns `nil` when
    /// we have no record — callers use that to decide whether to render the
    /// offline-mode hint at all.
    static func relativeLastConnected(now: Date = Date()) -> String? {
        guard let last = lastSuccess else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: last, relativeTo: now)
    }
}
