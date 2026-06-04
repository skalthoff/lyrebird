import Foundation

/// Single source of truth for reducing a server URL to its bare host.
///
/// Both ``DiagnosticBundle/redactServerHost(_:)`` (manifest.json) and
/// ``AboutInfo/connectedServerHost(from:)`` (the screenshot-prone About row)
/// must redact identically — they only differ in how they spell "no host"
/// (`"(not signed in)"` vs `nil`). Sharing the parse here keeps the two from
/// drifting; the parity is also asserted by `AboutInfoTests`.
///
/// ## Why not hand-roll the userinfo split
///
/// An earlier version stripped userinfo by cutting at the *first* `@`, which
/// leaked part of an embedded `user:p@ss@host` password into the manifest.
/// `URLComponents` already implements the correct RFC-3986 split (userinfo is
/// everything up to the *last* `@` of the authority), so we lean on it instead
/// of re-deriving the rule by hand.
///
/// Examples:
/// - `https://music.example.com/jellyfin` → `music.example.com`
/// - `https://user:pw@host:8443/x?token=abc` → `host`
/// - `music.example.com:8096` → `music.example.com`
/// - `ht!tp://weird host/with space` → `nil` (no plausible host)
/// - `""` → `nil`
enum ServerHostRedaction {

    /// Bare host of `urlString`, dropping scheme, userinfo, port, path, and
    /// query. `nil` when the input is empty or yields no plausible host.
    static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Structured parse first. `URLComponents` cleanly separates the host
        // from userinfo / port / path / query and splits userinfo on the last
        // `@`, so an embedded `user:p@ss@host` password can't leak through.
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            return host
        }

        // Bare `host[:port][/path]` and `user:pw@host` strings have no scheme,
        // so `URLComponents` parses the whole thing as a path and finds no
        // host. Prepend a default scheme and let the same parser do the work —
        // this still drops userinfo/port/path correctly rather than guessing.
        if let host = URLComponents(string: "https://" + trimmed)?.host,
           isPlausibleHost(host) {
            return host
        }

        // Malformed scheme-less input (e.g. `ht!tp://weird host`) can parse to
        // a junk "host" full of illegal characters. Reject it rather than write
        // garbage into a manifest / About row.
        return nil
    }

    /// Hostname / IP-literal characters only: ASCII letters, digits, `.`, `-`,
    /// plus `:` and `[` / `]` for IPv6 literals. Anything else (spaces, `!`,
    /// `?`, …) means `URLComponents` latched onto non-host text, so the
    /// candidate is rejected.
    private static let plausibleHostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return host.unicodeScalars.allSatisfy { plausibleHostCharacters.contains($0) }
    }
}
