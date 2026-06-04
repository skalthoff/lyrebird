import Foundation
import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the Help → Export Diagnostic Bundle collector (#455).
///
/// The two side-effecting inputs — the unified log and `UserDefaults` — are
/// injected, so every assertion runs against `DiagnosticBundle.assemble`
/// (pure) or the redaction / stringify helpers, with no live `OSLogStore`,
/// signed-in session, or file I/O. The contract being defended:
///
/// 1. The bundle redacts the server URL down to its bare host.
/// 2. No access token / password / device id ever lands in the bundle.
/// 3. Only allowlisted settings are copied; free-text user data is excluded.
/// 4. A log-read failure degrades to an in-file note instead of throwing.
final class DiagnosticBundleTests: XCTestCase {

    // MARK: - Test doubles

    /// Canned log source. Records the requested subsystem so the collector's
    /// scope can be asserted, and can be flipped to throw.
    private final class FakeLogReader: DiagnosticBundle.LogReading {
        var lines: [String]
        var error: Error?
        private(set) var requestedSubsystem: String?

        init(lines: [String] = [], error: Error? = nil) {
            self.lines = lines
            self.error = error
        }

        func recentLines(subsystem: String, since: Date) throws -> [String] {
            requestedSubsystem = subsystem
            if let error { throw error }
            return lines
        }
    }

    private struct DummyError: Error {}

    /// Fresh, isolated defaults so the test never reads or mutates the real
    /// user domain. Caller seeds whatever keys it needs.
    private func makeDefaults(_ seed: [String: Any]) -> UserDefaults {
        let suiteName = "DiagnosticBundleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        for (k, v) in seed { defaults.set(v, forKey: k) }
        return defaults
    }

    private func decodeManifest(_ files: [String: Data]) throws -> DiagnosticBundle.Manifest {
        let data = try XCTUnwrap(files["manifest.json"], "bundle must contain manifest.json")
        return try JSONDecoder().decode(DiagnosticBundle.Manifest.self, from: data)
    }

    private func logsText(_ files: [String: Data]) throws -> String {
        let data = try XCTUnwrap(files["logs.txt"], "bundle must contain logs.txt")
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Redaction

    func testRedactStripsSchemePathAndQuery() {
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("https://music.example.com/jellyfin?x=1"),
            "music.example.com",
            "scheme, path, and query must be dropped"
        )
    }

    func testRedactStripsUserinfoAndPort() {
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("https://admin:hunter2@host.internal:8443/jf"),
            "host.internal",
            "userinfo and port must be dropped — they can carry secrets"
        )
    }

    func testRedactHandlesBareHostWithoutScheme() {
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("music.example.com:8096/jf"),
            "music.example.com",
            "a scheme-less host:port/path string must still reduce to the host"
        )
    }

    func testRedactEmptyURLIsNotSignedIn() {
        XCTAssertEqual(DiagnosticBundle.redactServerHost(""), "(not signed in)")
        XCTAssertEqual(DiagnosticBundle.redactServerHost("   "), "(not signed in)")
    }

    func testRedactSchemelessUserinfoDoesNotLeakPassword() {
        // A scheme-less URL with embedded credentials must drop the WHOLE
        // `user:pw@` userinfo, not just the part before the first `@`. A
        // password that itself contains `@` is the worst case.
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("admin:p@ssw0rd@host.internal:8443/jf"),
            "host.internal",
            "an embedded password (even one containing '@') must not leak into the host"
        )
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("user:pw@bare.example.com:9000"),
            "bare.example.com"
        )
    }

    func testRedactMalformedSchemelessInputIsNotSignedIn() {
        // Garbage that parses to a non-host (spaces / illegal chars) must NOT be
        // written verbatim into the manifest — it falls back to "(not signed in)".
        XCTAssertEqual(
            DiagnosticBundle.redactServerHost("ht!tp://weird host/with space"),
            "(not signed in)",
            "a non-host candidate must not be emitted as the server host"
        )
        XCTAssertEqual(DiagnosticBundle.redactServerHost("???"), "(not signed in)")
        XCTAssertEqual(DiagnosticBundle.redactServerHost("weird host"), "(not signed in)")
    }

    // MARK: - Secret exclusion (the core safety property)

    func testBundleNeverContainsTokenOrPassword() throws {
        let reader = FakeLogReader(lines: ["2026-06-04T00:00:00Z [auth] signed in"])
        let defaults = makeDefaults(["playback.gaplessEnabled": true])

        let files = DiagnosticBundle.assemble(
            version: "1.2.3",
            build: "456",
            // A maximally hostile URL: token in the query, password in
            // userinfo. None of it may survive into any artifact.
            serverURL: "https://user:SuperSecretPassword@music.example.com:8443/jf?api_key=TOPSECRETTOKEN",
            osVersion: "macOS 26.4",
            logReader: reader,
            defaults: defaults
        )

        // Scan every emitted byte across every file for the secrets.
        let haystack = files.values
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")

        XCTAssertFalse(haystack.contains("SuperSecretPassword"), "password must never appear in the bundle")
        XCTAssertFalse(haystack.contains("TOPSECRETTOKEN"), "access token must never appear in the bundle")
        XCTAssertFalse(haystack.contains("api_key"), "query string must be stripped entirely")
        XCTAssertFalse(haystack.contains("8443"), "port must not survive redaction")

        // And the host that SHOULD survive does.
        let manifest = try decodeManifest(files)
        XCTAssertEqual(manifest.serverHost, "music.example.com")
    }

    // MARK: - Settings allowlist

    func testOnlyAllowlistedSettingsAreCopied() throws {
        let defaults = makeDefaults([
            "playback.gaplessEnabled": true,            // allowlisted
            "appearance.density": "comfortable",        // allowlisted
            "recentSearches": ["my private query"],     // NOT allowlisted (PII)
            "pinned_stations": ["secret station"],      // NOT allowlisted (PII)
            "some.unknown.key": "whatever",             // NOT allowlisted
        ])

        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logReader: FakeLogReader(),
            defaults: defaults
        )
        let manifest = try decodeManifest(files)

        XCTAssertEqual(manifest.settings["playback.gaplessEnabled"], "true", "Bool toggles render as true/false")
        XCTAssertEqual(manifest.settings["appearance.density"], "comfortable")
        XCTAssertNil(manifest.settings["recentSearches"], "free-text searches must not be exported")
        XCTAssertNil(manifest.settings["pinned_stations"], "pinned stations must not be exported")
        XCTAssertNil(manifest.settings["some.unknown.key"], "non-allowlisted keys must not be exported")

        // The PII values must not leak anywhere in the bundle either.
        let haystack = files.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(haystack.contains("my private query"))
        XCTAssertFalse(haystack.contains("secret station"))
    }

    func testMissingSettingsAreOmittedNotDefaulted() throws {
        // Empty defaults — no allowlisted key present.
        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logReader: FakeLogReader(),
            defaults: makeDefaults([:])
        )
        let manifest = try decodeManifest(files)
        XCTAssertTrue(manifest.settings.isEmpty, "absent keys must be omitted, not invented")
    }

    func testStringifyRendersBoolAndNumberDistinctly() {
        XCTAssertEqual(DiagnosticBundle.stringify(true), "true", "Bool must not render as 1")
        XCTAssertEqual(DiagnosticBundle.stringify(false), "false")
        XCTAssertEqual(DiagnosticBundle.stringify(3), "3")
        XCTAssertEqual(DiagnosticBundle.stringify(2.5), "2.5")
        XCTAssertEqual(DiagnosticBundle.stringify("hello"), "hello")
    }

    // MARK: - Manifest metadata

    func testManifestCarriesVersionBuildAndOS() throws {
        let files = DiagnosticBundle.assemble(
            version: "9.9.9",
            build: "777",
            serverURL: "https://music.example.com",
            osVersion: "macOS 26.4 (Build 99X)",
            logReader: FakeLogReader(),
            defaults: makeDefaults([:])
        )
        let manifest = try decodeManifest(files)
        XCTAssertEqual(manifest.appVersion, "9.9.9")
        XCTAssertEqual(manifest.appBuild, "777")
        XCTAssertEqual(manifest.osVersion, "macOS 26.4 (Build 99X)")
        XCTAssertFalse(manifest.generatedAt.isEmpty, "a generation timestamp must be recorded")
    }

    // MARK: - Logs artifact

    func testLogsArtifactRequestsCorrectSubsystemAndJoinsLines() throws {
        let reader = FakeLogReader(lines: [
            "2026-06-04T00:00:01Z [app] launched",
            "2026-06-04T00:00:02Z [net] GET /Items 200",
        ])
        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logReader: reader,
            defaults: makeDefaults([:])
        )

        XCTAssertEqual(reader.requestedSubsystem, Log.subsystem, "must scope the read to the app's subsystem")
        let text = try logsText(files)
        XCTAssertTrue(text.contains("launched"))
        XCTAssertTrue(text.contains("GET /Items 200"))
    }

    func testLogReadFailureDegradesGracefully() throws {
        let reader = FakeLogReader(error: DummyError())
        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logReader: reader,
            defaults: makeDefaults([:])
        )

        // A failed log read must not drop the artifact or sink the bundle —
        // the manifest must still be present and the logs file must explain.
        XCTAssertNotNil(files["manifest.json"], "manifest must survive a log-read failure")
        let text = try logsText(files)
        XCTAssertTrue(text.contains("could not read the unified log"), "the failure must be noted in-file")
    }

    func testEmptyLogsProducesExplanatoryNote() throws {
        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logWindow: 1800,
            logReader: FakeLogReader(lines: []),
            defaults: makeDefaults([:])
        )
        let text = try logsText(files)
        XCTAssertTrue(text.contains("no log entries"), "an empty read must say so")
        XCTAssertTrue(text.contains("30 minutes"), "the window should be reported in minutes")
    }

    // MARK: - README + file set

    func testBundleAlwaysContainsThreeArtifacts() {
        let files = DiagnosticBundle.assemble(
            version: "1.0.0",
            build: "1",
            serverURL: "https://host",
            osVersion: "macOS 26.4",
            logReader: FakeLogReader(),
            defaults: makeDefaults([:])
        )
        XCTAssertEqual(Set(files.keys), ["manifest.json", "logs.txt", "README.txt"])
    }

    func testReadmeStatesWhatIsExcluded() {
        // The README is the user's pre-share safety check; it must explicitly
        // promise no token/password and host-only URL.
        let readme = DiagnosticBundle.readmeText
        XCTAssertTrue(readme.contains("access token"))
        XCTAssertTrue(readme.contains("password"))
        XCTAssertTrue(readme.lowercased().contains("host"))
    }

    // MARK: - Filename stamp

    func testFilenameStampIsPathSafe() {
        let stamp = DiagnosticBundle.filenameStamp(Date(timeIntervalSince1970: 0))
        XCTAssertFalse(stamp.contains(":"), "colons are not valid in macOS display filenames")
        XCTAssertFalse(stamp.contains("/"), "slashes would create unintended path components")
    }

    // MARK: - End-to-end zip write

    func testExportWritesAZipFileToDisk() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: dest) }

        try DiagnosticBundle.export(
            to: dest,
            version: "1.0.0",
            build: "1",
            serverURL: "https://music.example.com/jf",
            osVersion: "macOS 26.4",
            logReader: FakeLogReader(lines: ["2026-06-04T00:00:00Z [app] hi"]),
            defaults: makeDefaults(["playback.gaplessEnabled": true])
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "a .zip must be written at the destination")
        let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "the written zip must be non-empty")

        // A second export to the same path must overwrite cleanly, not throw.
        XCTAssertNoThrow(
            try DiagnosticBundle.export(
                to: dest,
                version: "1.0.1",
                build: "2",
                serverURL: "https://music.example.com/jf",
                osVersion: "macOS 26.4",
                logReader: FakeLogReader(),
                defaults: makeDefaults([:])
            ),
            "re-exporting over an existing file must overwrite it"
        )
    }
}
