//! Scrobbling — submit "listens" to a ListenBrainz-compatible server.
//!
//! ListenBrainz is the MVP target because it is the simplest of the common
//! scrobbling backends: a single user token authenticates every request and
//! the submit endpoint takes plain JSON, so there is no session handshake (as
//! Last.fm requires) to maintain. The user pastes their token from
//! <https://listenbrainz.org/profile/> into the Scrobbling preferences pane;
//! the platform UI feeds track-start and threshold-crossing events here.
//!
//! Two kinds of submission, mirroring the ListenBrainz API:
//!
//! - **`playing_now`** — sent once when a track starts. Drives the "now
//!   playing" indicator on the user's ListenBrainz profile. Carries no
//!   timestamp and is never counted as a listen.
//! - **`single`** — sent once a track has been played long enough to count
//!   (the [`scrobble_threshold_reached`] rule: at least half the track, or
//!   four minutes, whichever comes first). This is the durable listen that
//!   shows up in the user's history.
//!
//! The token is a secret. It is never logged: error paths log the HTTP status
//! and a generic message, never the `Authorization` header or its value.

use crate::error::{LyrebirdError, Result};
use crate::models::Track;
use reqwest::Client as HttpClient;
use serde_json::{json, Value};
use std::time::Duration;

/// The canonical public ListenBrainz ingest endpoint. Stored as a field on
/// [`Scrobbler`] (rather than hard-coded at the call site) so tests can point
/// the client at a wiremock server.
pub const LISTENBRAINZ_API_ROOT: &str = "https://api.listenbrainz.org";

/// Submit-listens path appended to the API root.
const SUBMIT_LISTENS_PATH: &str = "/1/submit-listens";

/// Client identity stamped into every listen's `additional_info`. Mirrors the
/// `CLIENT_NAME` / `CLIENT_VERSION` the Jellyfin client uses, but kept local
/// here so this module has no dependency on `client.rs`'s private constants.
const SCROBBLE_CLIENT_NAME: &str = "Lyrebird Desktop";
const SCROBBLE_CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// A track counts as "listened" — and so earns a `single` submission — once it
/// has been played for at least half its length **or** four minutes,
/// whichever comes first. This matches the long-standing Last.fm / ListenBrainz
/// community scrobble rule (see the ListenBrainz docs and the original AudioScrobbler
/// spec).
///
/// `position_secs` is the current playhead; `runtime_secs` is the track's full
/// duration. A `runtime_secs` of `0` (unknown duration) falls back to the
/// four-minute wall-clock rule alone, so a track with no reported length still
/// scrobbles after four minutes of play rather than never.
///
/// Returns `false` for a zero/negative position so a freshly-started track
/// (or a seek back to the very beginning) never trips the threshold.
pub fn scrobble_threshold_reached(position_secs: f64, runtime_secs: f64) -> bool {
    /// Four minutes, the absolute cap from the scrobble spec.
    const FOUR_MINUTES: f64 = 240.0;
    /// Tracks shorter than this are too short to scrobble under the spec
    /// (ListenBrainz/Last.fm both ignore sub-30-second items). Guards against
    /// counting a stinger / interstitial as a real listen.
    const MIN_TRACK_SECS: f64 = 30.0;

    if position_secs <= 0.0 {
        return false;
    }
    // Tracks under the minimum length are never eligible — but only when we
    // actually know the runtime. Unknown runtime (0) defers entirely to the
    // four-minute rule below.
    if runtime_secs > 0.0 && runtime_secs < MIN_TRACK_SECS {
        return false;
    }

    if position_secs >= FOUR_MINUTES {
        return true;
    }
    if runtime_secs > 0.0 && position_secs >= runtime_secs / 2.0 {
        return true;
    }
    false
}

/// Build the inner `track_metadata` object shared by both `playing_now` and
/// `single` submissions. Split out so the payload shape is unit-testable
/// without standing up an HTTP server.
///
/// Maps [`Track`] fields onto the ListenBrainz schema:
/// - `artist_name`  ← `track.artist_name`
/// - `track_name`   ← `track.name`
/// - `release_name` ← `track.album_name` (omitted when absent)
///
/// `additional_info` always carries the submitting client name + version so
/// the listen is attributable in the user's ListenBrainz history, and echoes
/// the Jellyfin item id under a namespaced key for debugging / dedupe.
fn track_metadata(track: &Track) -> Value {
    let mut metadata = json!({
        "artist_name": track.artist_name,
        "track_name": track.name,
        "additional_info": {
            "media_player": SCROBBLE_CLIENT_NAME,
            "submission_client": SCROBBLE_CLIENT_NAME,
            "submission_client_version": SCROBBLE_CLIENT_VERSION,
            "music_service_name": "Jellyfin",
            "jellyfin_item_id": track.id,
        }
    });
    if let Some(album) = track.album_name.as_ref().filter(|a| !a.is_empty()) {
        metadata["release_name"] = json!(album);
    }
    metadata
}

/// Build a full `playing_now` request body for a track. No timestamp — the
/// ListenBrainz API rejects `playing_now` payloads that carry `listened_at`.
pub fn playing_now_payload(track: &Track) -> Value {
    json!({
        "listen_type": "playing_now",
        "payload": [
            { "track_metadata": track_metadata(track) }
        ]
    })
}

/// Build a full `single` (durable listen) request body. `listened_at` is the
/// Unix timestamp (seconds) at which the track began playing — ListenBrainz
/// keys the listen on this value, so callers should pass the *start* time, not
/// the moment the threshold was crossed.
pub fn single_listen_payload(track: &Track, listened_at: i64) -> Value {
    json!({
        "listen_type": "single",
        "payload": [
            {
                "listened_at": listened_at,
                "track_metadata": track_metadata(track)
            }
        ]
    })
}

/// A configured ListenBrainz client. Cheap to construct; holds a `reqwest`
/// client (connection-pooled) and the user token. Created per-submission by
/// [`crate::LyrebirdCore`] from the persisted token, so a token change takes
/// effect on the very next scrobble without any cached-client invalidation.
pub struct Scrobbler {
    http: HttpClient,
    api_root: String,
    token: String,
}

impl Scrobbler {
    /// Construct a scrobbler against the public ListenBrainz endpoint.
    /// Returns `InvalidInput` for an empty token so the caller surfaces a
    /// clear "token not configured" error rather than firing a request that
    /// would 401.
    pub fn new(token: impl Into<String>) -> Result<Self> {
        Self::with_root(LISTENBRAINZ_API_ROOT, token)
    }

    /// Construct a scrobbler against an arbitrary API root. Used by tests to
    /// target a wiremock server; production always goes through
    /// [`Self::new`].
    pub fn with_root(api_root: impl Into<String>, token: impl Into<String>) -> Result<Self> {
        let token = token.into();
        if token.trim().is_empty() {
            return Err(LyrebirdError::InvalidInput(
                "scrobble token is empty".into(),
            ));
        }
        let http = HttpClient::builder()
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| LyrebirdError::Network(e.to_string()))?;
        Ok(Self {
            http,
            api_root: api_root.into(),
            token,
        })
    }

    /// `Authorization` header value. ListenBrainz uses `Token <user-token>`
    /// (not `Bearer`). Kept private so the secret never escapes this module.
    fn auth_header(&self) -> String {
        format!("Token {}", self.token)
    }

    /// POST a pre-built submission body to `/1/submit-listens`.
    ///
    /// On a non-2xx response the body is read for diagnostics but the token is
    /// never logged. The whole non-success path is routed through
    /// [`LyrebirdError::from_status`] so 401/403/404/429 map to the same
    /// concrete variants as the rest of the client — in particular a `429`
    /// surfaces as [`LyrebirdError::RateLimit`] carrying the parsed
    /// `Retry-After` instead of being flattened into a generic `Server`
    /// error. (401 stays `LyrebirdError::Auth`, which `from_status` produces.)
    async fn submit(&self, body: Value) -> Result<()> {
        let url = format!(
            "{}{}",
            self.api_root.trim_end_matches('/'),
            SUBMIT_LISTENS_PATH
        );
        let resp = self
            .http
            .post(&url)
            .header("Authorization", self.auth_header())
            .json(&body)
            .send()
            .await
            .map_err(|e| LyrebirdError::Network(e.to_string()))?;

        let status = resp.status();
        if status.is_success() {
            return Ok(());
        }
        // Parse `Retry-After` (integer-seconds form) before consuming the body
        // so a 429 can carry the server's backoff hint.
        let retry_after = resp
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok());
        // Read the body for the error message but keep it short; never echo
        // the request (which carries the token).
        let snippet = resp.text().await.unwrap_or_default();
        let snippet: String = snippet.chars().take(500).collect();
        Err(LyrebirdError::from_status(
            status.as_u16(),
            snippet,
            retry_after,
        ))
    }

    /// Submit a `playing_now` for the given track.
    pub async fn submit_playing_now(&self, track: &Track) -> Result<()> {
        validate_scrobble_track(track)?;
        self.submit(playing_now_payload(track)).await
    }

    /// Submit a durable `single` listen for the given track, keyed to the Unix
    /// `listened_at` start time.
    pub async fn submit_listen(&self, track: &Track, listened_at: i64) -> Result<()> {
        validate_scrobble_track(track)?;
        self.submit(single_listen_payload(track, listened_at)).await
    }
}

/// Reject a track that can't form a valid ListenBrainz listen *before* we
/// spend a round-trip on it. ListenBrainz requires both `artist_name` and
/// `track_name` to be present and non-empty; a payload missing either is
/// rejected server-side, so guard at the boundary and surface a clear
/// [`LyrebirdError::InvalidInput`] the caller can swallow as "nothing to
/// scrobble".
fn validate_scrobble_track(track: &Track) -> Result<()> {
    if track.name.trim().is_empty() || track.artist_name.trim().is_empty() {
        return Err(LyrebirdError::InvalidInput(
            "track missing name/artist for scrobble".into(),
        ));
    }
    Ok(())
}
