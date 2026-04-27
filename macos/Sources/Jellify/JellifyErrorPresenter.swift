import Foundation
import SwiftUI

/// Maps a `JellifyError` surfaced by the core (via UniFFI) into a
/// presentation-quality localized message.
///
/// Issue #351. The core declares `JellifyError` as a UniFFI `flat_error`, so on
/// the Swift side we only receive the rendered `thiserror` Display string —
/// there is no Swift enum with associated values to pattern-match on. The
/// presenter therefore works by substring-matching the Display text against the
/// known variant prefixes. The mapping is intentionally conservative: anything
/// we can't place with confidence falls through to `error.other`, which reads
/// as "Something went wrong." rather than leaking low-level jargon.
///
/// ### Why a dedicated presenter?
///
/// Prior to this module, error call-sites stuffed `"<prefix>: \(error.localizedDescription)"`
/// into `AppModel.errorMessage`, which meant the banner string carried
/// technical detail (`"network error: error sending request"`, etc.) and was
/// impossible to localize — the Display string is hardcoded English from the
/// Rust side. The presenter funnels every surfacing path through a single
/// `String(localized:)` lookup so translators see a small, stable key set in
/// `Localizable.xcstrings`.
///
/// ### Usage
///
/// ```swift
/// do { try core.listAlbums(...) } catch {
///     if handleAuthError(error) { return }
///     errorMessage = JellifyErrorPresenter.message(for: error, context: .libraryLoad)
/// }
/// ```
///
/// `context` is an optional hint used to pick a more specific banner when the
/// error itself is generic (e.g. a search failure vs. a library load failure,
/// both of which might be `JellifyError::Server`). When the mapped variant
/// already carries enough context (Auth, NotFound, RateLimit) the `context`
/// parameter is ignored.
enum JellifyErrorPresenter {
    /// Surfaces the user-facing banner copy for `error`, honouring the
    /// provided `context` for generic failures. Always returns a non-empty
    /// string — the default is `error.other` → "Something went wrong."
    static func message(for error: Error, context: Context = .generic) -> String {
        let key = key(for: error, context: context)
        // `String(localized:)` wants `String.LocalizationValue`, whose `init(_:)`
        // treats the argument as the catalog key. Wrapping explicitly keeps
        // the compiler from misreading the String as an already-rendered
        // value.
        return String(localized: String.LocalizationValue(key), bundle: .main)
    }

    /// Returns the stable semantic key we'd surface for `error`. Exposed so
    /// callers that want a `Text(LocalizedStringKey(...))` binding can skip the
    /// bundle-lookup round-trip and still share the mapping.
    static func key(for error: Error, context: Context = .generic) -> String {
        let description = error.localizedDescription.lowercased()

        // Auth family has the highest priority — a 401 dressed as
        // `JellifyError::Server` still means "credentials are bad", and
        // treating it as a transport error would leak a stale token into
        // the UI. `handleAuthError` on `AppModel` already intercepts most
        // of these; this branch covers the fall-through cases (e.g. an
        // error bubbled from an async task that bypassed the helper).
        if description.contains("not logged in")
            || description.contains("authentication expired")
            || description.contains("authentication failed")
            || description.contains("401")
        {
            return "error.auth.expired"
        }

        // `JellifyError::Server` renders as "server returned an error:
        // {status} {message}". Pattern-match the status digits embedded
        // in the Display so 403/404/429 get specialised banners even
        // though the Rust side lumps them under one variant.
        if description.contains("server returned an error:") {
            if description.contains(" 403") || description.contains("forbidden") {
                return "error.forbidden"
            }
            if description.contains(" 404") || description.contains("not found") {
                return "error.not_found"
            }
            if description.contains(" 429") || description.contains("rate limit") {
                return "error.rate_limit"
            }
            // Any other status (500s, gateway errors, etc.) — prefer the
            // caller's context banner if it was supplied; otherwise the
            // generic "server ran into a problem" fallback.
            return context.fallbackKey ?? "error.server"
        }

        // Non-server variants, keyed off the `thiserror` Display prefix
        // declared in `core/src/error.rs`. Order mirrors the enum to keep
        // this readable.
        if description.contains("network error") {
            return "error.network"
        }
        if description.contains("decode error") {
            return "error.decode"
        }
        if description.contains("storage error") {
            return "error.storage"
        }
        if description.contains("credential store") {
            return "error.credentials"
        }
        if description.contains("audio error") {
            return "error.audio"
        }
        if description.contains("invalid input") {
            return "error.invalid_input"
        }

        return context.fallbackKey ?? "error.other"
    }

    /// Hint the call-site can pass so generic failures get a more specific
    /// banner. Each case maps to a key in `Localizable.xcstrings`. `generic`
    /// is the catch-all and flows to `error.other` / `error.server`.
    enum Context {
        case generic
        case login
        case libraryLoad
        case playlistsLoad
        case playlistLoad
        case albumTracks
        case playlistTracks
        case search
        case playback
        case favorite
        case markPlayed
        case playlistAdd

        fileprivate var fallbackKey: String? {
            switch self {
            case .generic: return nil
            case .login: return "error.login.failed"
            case .libraryLoad: return "error.library.load"
            case .playlistsLoad: return "error.playlists.load"
            case .playlistLoad: return "error.playlist.load"
            case .albumTracks: return "error.album.tracks"
            case .playlistTracks: return "error.playlist.tracks"
            case .search: return "error.search"
            case .playback: return "error.playback"
            case .favorite: return "error.favorite"
            case .markPlayed: return "error.markPlayed"
            case .playlistAdd: return "error.playlist.add"
            }
        }
    }
}
