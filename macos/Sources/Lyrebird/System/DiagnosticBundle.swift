import Foundation
import OSLog

/// Assembles a shareable diagnostic `.zip` for bug reports. Closes #455.
///
/// The Help → "Export Diagnostic Bundle…" menu item writes a zip containing
/// three plain-text artifacts:
///
/// 1. `logs.txt` — recent `os.Logger` output for the `org.lyrebird.desktop`
///    subsystem, the same filter the Advanced pane's "Open in Console.app"
///    button preloads (`Log.subsystem`). Lines are formatted
///    `<iso8601> [<category>] <message>`.
/// 2. `manifest.json` — app version / build, the sanitized server host
///    (host only — no scheme, userinfo, port, path, or query), the macOS
///    version, and an allowlist of non-secret settings.
/// 3. `README.txt` — a one-paragraph note describing what's inside and,
///    crucially, what was deliberately left out, so a user can eyeball the
///    bundle before attaching it to a public issue.
///
/// ## Redaction contract
///
/// The bundle must never contain secrets. Concretely:
/// - **No access token / password / device id.** The `Session` carries an
///   `accessToken`; only `session.server.url` is read, and only its host
///   survives `redactServerHost`.
/// - **No raw server URL.** `https://user:pw@music.example.com:8443/jf?x=1`
///   collapses to `music.example.com`. Userinfo, port, path, and query are
///   all dropped — they can encode reverse-proxy secrets or internal
///   hostnames the user may not want public.
/// - **Settings allowlist, not denylist.** Only keys in
///   ``settingsAllowlist`` are copied out of `UserDefaults`. Free-text user
///   data (recent searches, pinned stations) is intentionally excluded
///   because it can carry PII; adding a new toggle does NOT silently leak it.
///
/// ## Testability
///
/// The two side-effecting pieces — reading `OSLogStore` and reading
/// `UserDefaults` — are injected, so ``assemble(version:build:serverURL:osVersion:logReader:defaults:)``
/// is a pure function over its inputs and the redaction + manifest shaping
/// are unit-testable without a live log store, a signed-in session, or any
/// file I/O. ``export(to:version:build:serverURL:)`` is the thin wrapper that
/// the menu calls: it lays the artifacts into a temp directory and zips it
/// via `NSFileCoordinator`'s `.forUploading` coordination (Foundation's only
/// public, dependency-free zip path on macOS).
enum DiagnosticBundle {

    // MARK: - Errors

    enum BundleError: Error, LocalizedError {
        case zipCoordinationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .zipCoordinationFailed(let underlying):
                return "Could not compress the diagnostic bundle: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - Log reading seam

    /// Abstracts the source of recent log lines so tests can feed a canned
    /// transcript instead of touching the real unified log. `subsystem` is
    /// passed through (rather than hard-coding `Log.subsystem` in the reader)
    /// so a test can assert the collector requests the right scope.
    protocol LogReading {
        func recentLines(subsystem: String, since: Date) throws -> [String]
    }

    /// Production reader backed by `OSLogStore` scoped to the current process.
    /// Process scope (not `.system`) is deliberate: the app is sandboxed and
    /// can't read the system-wide store without the
    /// `com.apple.private.logging.stream` entitlement, and process scope
    /// already contains everything `Log.*` emitted this session.
    struct OSLogStoreReader: LogReading {
        func recentLines(subsystem: String, since: Date) throws -> [String] {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            // Scoped subsystem predicate — matches the field every `Log.*`
            // entry carries, exactly like the Console.app filter token in
            // PreferencesAdvanced.
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            return entries.compactMap { entry in
                guard let log = entry as? OSLogEntryLog else { return nil }
                return DiagnosticBundle.formatLogLine(
                    date: entry.date,
                    category: log.category,
                    message: entry.composedMessage
                )
            }
        }
    }

    // MARK: - Settings allowlist

    /// Non-secret preference keys copied into the manifest. Allowlist, not
    /// denylist: a key is exported only if it appears here, so a future
    /// toggle that happens to hold sensitive data can't leak by accident.
    /// Mirrors the `@AppStorage` keys used across the app, minus free-text
    /// user data (`recentSearches`, `pinned_stations`) which can carry PII.
    static let settingsAllowlist: [String] = [
        "advanced.verboseLogging",
        "advanced.showInternalIds",
        "appearance.density",
        "appearance.mode",
        "audio.transcodingPreference",
        "downloads.storageBudgetGb",
        "general.autoStartOnLogin",
        "general.language",
        "general.showInMenuBar",
        "hasCompletedOnboarding",
        "libraryViewMode",
        "playback.crossfadeSeconds",
        "playback.downloadQuality",
        "playback.gaplessEnabled",
        "playback.normalization",
        "playback.preGainDb",
        "playback.preferredCodec",
        "playback.stopAfterCurrent",
        "playback.streamingQuality",
    ]

    // MARK: - Redaction

    /// Reduce a server URL to its bare host, dropping scheme, userinfo, port,
    /// path, and query. Returns `"(not signed in)"` when the input is empty
    /// so the manifest never carries an empty/secret-looking value.
    ///
    /// Examples:
    /// - `https://music.example.com/jellyfin` → `music.example.com`
    /// - `https://user:pw@host:8443/x?token=abc` → `host`
    /// - `music.example.com:8096` → `music.example.com`
    /// - `""` → `(not signed in)`
    static func redactServerHost(_ urlString: String) -> String {
        ServerHostRedaction.host(from: urlString) ?? "(not signed in)"
    }

    // MARK: - Manifest

    /// Snapshot of the non-secret metadata serialized to `manifest.json`.
    /// Kept `Codable` + `Equatable` so tests assert on the shaped value
    /// rather than parsing JSON text.
    struct Manifest: Codable, Equatable {
        var appVersion: String
        var appBuild: String
        var serverHost: String
        var osVersion: String
        var generatedAt: String
        /// Non-secret settings, keyed by preference name. String-valued so the
        /// JSON is stable and human-eyeballable regardless of the underlying
        /// `UserDefaults` storage type.
        var settings: [String: String]
    }

    /// Read the allowlisted settings out of a `UserDefaults`, stringifying
    /// each present value. Missing keys are simply omitted.
    static func collectSettings(from defaults: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for key in settingsAllowlist where out[key] == nil {
            guard let value = defaults.object(forKey: key) else { continue }
            out[key] = stringify(value)
        }
        return out
    }

    /// Stable string form for an arbitrary `UserDefaults` value. Bool-backed
    /// `NSNumber`s render as `true`/`false` (not `1`/`0`) so toggle states read
    /// cleanly in the manifest.
    static func stringify(_ value: Any) -> String {
        if let number = value as? NSNumber {
            // `UserDefaults` stores Bool as a CFBoolean-backed NSNumber;
            // distinguish it from a numeric NSNumber so a toggle doesn't show
            // up as `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let s = value as? String {
            return s
        }
        return String(describing: value)
    }

    // MARK: - Assembly (pure)

    /// Assemble the in-memory artifact set for the bundle. Pure over its
    /// inputs: no `Bundle.main`, no live `OSLogStore`, no `UserDefaults.standard`
    /// reach in here — the menu wrapper supplies them. Returns a map of
    /// filename → file contents.
    ///
    /// `logWindow` bounds how far back log lines are read; the default of one
    /// hour covers a typical reproduce-then-export session without dragging in
    /// the whole boot transcript.
    static func assemble(
        version: String,
        build: String,
        serverURL: String,
        osVersion: String,
        now: Date = Date(),
        logWindow: TimeInterval = 3600,
        logReader: LogReading,
        defaults: UserDefaults
    ) -> [String: Data] {
        let host = redactServerHost(serverURL)

        let manifest = Manifest(
            appVersion: version,
            appBuild: build,
            serverHost: host,
            osVersion: osVersion,
            generatedAt: Self.iso8601(now),
            settings: collectSettings(from: defaults)
        )

        var files: [String: Data] = [:]

        // manifest.json — sorted keys for deterministic, diff-friendly output.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let manifestData = try? encoder.encode(manifest) {
            files["manifest.json"] = manifestData
        }

        // logs.txt — best-effort. A failure to read the store must not sink
        // the whole export, so a read error becomes an in-file note instead.
        let logBody: String
        do {
            let lines = try logReader.recentLines(subsystem: Log.subsystem, since: now.addingTimeInterval(-logWindow))
            logBody = lines.isEmpty
                ? "(no log entries in the last \(Int(logWindow / 60)) minutes for subsystem \(Log.subsystem))"
                : lines.joined(separator: "\n")
        } catch {
            logBody = "(could not read the unified log: \(error.localizedDescription))"
        }
        files["logs.txt"] = Data((logBody + "\n").utf8)

        // README.txt — states what's in and what's deliberately out.
        files["README.txt"] = Data(readmeText.utf8)

        return files
    }

    /// Human-readable explainer that ships inside every bundle so a user can
    /// confirm no secrets are present before attaching it to a public issue.
    static let readmeText = """
        Lyrebird Diagnostic Bundle
        ==========================

        This archive was generated by Help → Export Diagnostic Bundle… to help
        diagnose a problem. Attach it to a GitHub issue or send it to a
        maintainer.

        Contents:
          • manifest.json — app version/build, macOS version, the server HOST
            ONLY (no scheme, port, path, or query), and your non-secret
            settings.
          • logs.txt      — recent log output for subsystem
            org.lyrebird.desktop, the same data shown by Console.app.

        Deliberately NOT included:
          • Your access token, password, or device id.
          • The full server URL — only the bare host is recorded.
          • Recent searches, pinned stations, or any free-text you entered.

        You can open both files in any text editor to review them before
        sharing.

        """

    // MARK: - Export (I/O)

    /// Write the assembled artifacts into a temporary directory and compress
    /// that directory to the destination `.zip` at `destination`.
    ///
    /// Uses `NSFileCoordinator`'s `.forUploading` coordination, which hands
    /// back a system-produced zip of the coordinated directory — Foundation's
    /// only public, dependency-free zip primitive on macOS. The temp staging
    /// directory is cleaned up in a `defer` regardless of outcome.
    ///
    /// This is intentionally thin: all shaping/redaction lives in
    /// ``assemble(version:build:serverURL:osVersion:now:logWindow:logReader:defaults:)``,
    /// which the tests cover directly.
    static func export(
        to destination: URL,
        version: String,
        build: String,
        serverURL: String,
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        logReader: LogReading = OSLogStoreReader(),
        defaults: UserDefaults = .standard
    ) throws {
        let files = assemble(
            version: version,
            build: build,
            serverURL: serverURL,
            osVersion: osVersion,
            logReader: logReader,
            defaults: defaults
        )

        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("LyrebirdDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for (name, data) in files {
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }

        // Coordinate a read with `.forUploading` to get a zip of `staging`,
        // then copy it to the user's chosen location. The coordinator's temp
        // zip is only valid inside the accessor block, so we copy out within
        // it. If a stale file sits at the destination, remove it first so the
        // copy doesn't fail.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: staging,
            options: [.forUploading],
            error: &coordinationError
        ) { zippedURL in
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: zippedURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw BundleError.zipCoordinationFailed(underlying: coordinationError)
        }
        if let copyError {
            throw copyError
        }
    }

    // MARK: - Formatting helpers

    /// `<iso8601> [<category>] <message>` — the per-line shape in `logs.txt`.
    static func formatLogLine(date: Date, category: String, message: String) -> String {
        "\(iso8601(date)) [\(category)] \(message)"
    }

    /// Shared ISO-8601 formatter. Stable, locale-independent timestamps so the
    /// manifest and log lines sort and diff predictably across machines.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Filename-safe timestamp (`yyyy-MM-dd-HHmmss`) for the default save-panel
    /// name. Colons from ISO-8601 aren't valid in HFS+/APFS display names, so
    /// this uses a flat, sortable form instead.
    static func filenameStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }
}
