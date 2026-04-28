use crate::enums::{self, ImageType, ItemField, ItemKind, ItemSortBy, SortOrder};
use crate::error::{JellifyError, Result};
use crate::models::*;
use crate::query::ItemsQuery;
use parking_lot::Mutex;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};
use reqwest::{Client as HttpClient, RequestBuilder, Response, StatusCode};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tokio_util::sync::CancellationToken;
use url::Url;

/// A generic paginated wrapper used by [`ItemsQuery`] before the raw items
/// are mapped to a concrete model type. Mirrors the shape of the per-model
/// `PaginatedAlbums` / `PaginatedArtists` / etc. records, but generic over
/// the element type so the query layer doesn't need to know which model
/// the caller wants.
#[derive(Clone, Debug)]
pub struct PaginatedItems<T> {
    pub items: Vec<T>,
    pub total_count: u32,
}

const CLIENT_NAME: &str = "Jellify Desktop";
const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Maximum number of HTTP attempts per logical request, inclusive of the
/// initial try. With the backoff ladder below this caps a single request at
/// ~3.5s of added latency in the worst case.
const MAX_ATTEMPTS: u32 = 3;

/// Exponential backoff schedule between retries, in milliseconds. The entry
/// at index `N` is the delay *before* attempt `N+1`. `±15%` jitter is
/// applied on top of each base delay at send time. Tuned to be fast enough
/// to mask a transient blip on home Wi-Fi without making the UI feel
/// stuck on a legit server outage.
const BACKOFF_BASE_MS: [u64; 3] = [200, 400, 800];

/// Upper bound on the delay granted by a server-side `Retry-After` header.
/// Any value larger than this is clamped — we'd rather surface the error to
/// the user than hang for the duration the server suggested.
const RETRY_AFTER_CAP: Duration = Duration::from_secs(5);

/// Pluggable silent re-auth callback. Invoked by [`JellyfinClient`]'s 401
/// interceptor; see [`JellyfinClient::set_refresh_callback`].
///
/// Implementations return the new access token on success, or a concrete
/// [`JellifyError`] on failure. A `None` return means "credentials are
/// still valid but the keyring has no fresher token" — callers treat that
/// the same as a failure and surface [`JellifyError::AuthExpired`].
pub type RefreshTokenFn = dyn Fn() -> Result<Option<String>> + Send + Sync;

/// Per-client memoization of the library-resolution lookups behind
/// [`JellyfinClient::music_library_id`] and
/// [`JellyfinClient::playlist_library_id`]. Both endpoints are hit once at
/// sign-in by the UI and then again by nearly every library query, so a
/// plain in-memory cache pays for itself immediately. Invalidated on
/// [`JellyfinClient::set_session`] so re-auth against a different user or
/// server picks up fresh ids.
#[derive(Default)]
struct LibraryCache {
    music: Option<String>,
    playlist: Option<String>,
}

pub struct JellyfinClient {
    http: HttpClient,
    base_url: Url,
    device_id: String,
    device_name: String,
    /// Current access token. Stored behind a `Mutex` so the 401 interceptor
    /// can swap in a freshly-fetched token under `&self` without fighting
    /// the rest of the client's borrow graph.
    token: Mutex<Option<String>>,
    user_id: Option<String>,
    library_cache: Mutex<LibraryCache>,
    /// Optional silent re-auth hook invoked on the first 401 per request.
    /// Wired by [`crate::JellifyCore`] at login / resume time; tests may
    /// leave it unset to exercise the "no refresh available" fallback.
    refresh_cb: Mutex<Option<Arc<RefreshTokenFn>>>,
    /// Cancellation signal shared with any background task (e.g. the
    /// heartbeat scheduler) that holds a reference to this client. When
    /// cancelled, the internal retry loop abandons any pending backoff
    /// sleep between retry attempts and returns
    /// [`JellifyError::Other`]`("cancelled")` immediately. See issue #605.
    pub cancel: CancellationToken,
}

impl JellyfinClient {
    pub fn new(base_url: &str, device_id: String, device_name: String) -> Result<Self> {
        let mut url = Url::parse(base_url)?;
        if !url.path().ends_with('/') {
            let path = format!("{}/", url.path());
            url.set_path(&path);
        }
        let http = HttpClient::builder()
            .user_agent(format!("{CLIENT_NAME}/{CLIENT_VERSION}"))
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| JellifyError::Network(e.to_string()))?;
        Ok(Self {
            http,
            base_url: url,
            device_id,
            device_name,
            token: Mutex::new(None),
            user_id: None,
            library_cache: Mutex::new(LibraryCache::default()),
            refresh_cb: Mutex::new(None),
            cancel: CancellationToken::new(),
        })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub fn http(&self) -> &HttpClient {
        &self.http
    }

    pub fn user_id(&self) -> Option<&str> {
        self.user_id.as_deref()
    }

    pub fn token(&self) -> Option<String> {
        self.token.lock().clone()
    }

    pub fn set_session(&mut self, token: String, user_id: String) {
        *self.token.lock() = Some(token);
        self.user_id = Some(user_id);
        // Library ids are tied to `(server, user)`, so re-auth must drop
        // the memoized lookups before the new session resumes traffic.
        *self.library_cache.lock() = LibraryCache::default();
    }

    /// Register a silent re-auth callback invoked on 401 responses.
    ///
    /// The callback is called at most once per logical request — if it
    /// surfaces a new token the request is retried with it, otherwise the
    /// client returns [`JellifyError::AuthExpired`] so the UI can drive the
    /// re-auth sheet. Wired by [`crate::JellifyCore`] at login/resume so the
    /// callback can re-read the OS credential store without the client
    /// having to know about the [`crate::storage::Database`].
    pub fn set_refresh_callback(&self, cb: Arc<RefreshTokenFn>) {
        *self.refresh_cb.lock() = Some(cb);
    }

    /// Strip control characters (`\r`, `\n`, `\0`, and any other C0/C1 code
    /// point) from a string intended for use inside an HTTP header value,
    /// then truncate to `max_len` characters. Prevents header-injection
    /// attacks when a caller-supplied `device_name` contains embedded CRLF
    /// sequences (see issue #608).
    fn sanitize_header_field(s: &str, max_len: usize) -> String {
        let cleaned: String = s.chars().filter(|c| !c.is_control()).collect();
        if cleaned.len() > max_len {
            cleaned.chars().take(max_len).collect()
        } else {
            cleaned
        }
    }

    fn auth_header(&self) -> String {
        let token_guard = self.token.lock();
        let token_part = token_guard
            .as_deref()
            .map(|t| format!(", Token=\"{t}\""))
            .unwrap_or_default();
        let safe_device = Self::sanitize_header_field(&self.device_name, 100);
        format!(
            "MediaBrowser Client=\"{client}\", Device=\"{device}\", DeviceId=\"{device_id}\", Version=\"{version}\"{token}",
            client = CLIENT_NAME,
            device = safe_device,
            device_id = self.device_id,
            version = CLIENT_VERSION,
            token = token_part,
        )
    }

    pub fn build_headers(&self) -> Result<HeaderMap> {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&self.auth_header())
                .map_err(|e| JellifyError::InvalidInput(e.to_string()))?,
        );
        Ok(headers)
    }

    pub(crate) fn endpoint(&self, path: &str) -> Result<Url> {
        let trimmed = path.trim_start_matches('/');
        self.base_url.join(trimmed).map_err(Into::into)
    }

    /// Bail out with [`JellifyError::NotAuthenticated`] when no access token
    /// is present. Mirrors the old inline `self.token.as_ref().ok_or(...)?`
    /// idiom now that the field lives behind a `Mutex`.
    fn require_token(&self) -> Result<()> {
        if self.token.lock().is_some() {
            Ok(())
        } else {
            Err(JellifyError::NotAuthenticated)
        }
    }

    async fn check(resp: Response) -> Result<Response> {
        check_response(resp).await
    }

    /// Build and issue a raw [`ItemsQuery`] against this client. Convenience
    /// passthrough for [`ItemsQuery::execute`] so callers can write
    /// `client.query().item_types(...).limit(...).execute().await` without
    /// importing the query module directly.
    pub fn query(&self) -> ItemsQuery {
        ItemsQuery::new()
    }

    /// Is the HTTP status worth retrying?
    ///
    /// Retriable:
    ///   * `408 Request Timeout` — the server gave up before we did.
    ///   * `429 Too Many Requests` — caller will honour `Retry-After`.
    ///   * `5xx` except `501 Not Implemented`, which is a semantic "we
    ///     don't do that" and will never succeed on retry.
    fn is_retriable_status(status: StatusCode) -> bool {
        if status == StatusCode::REQUEST_TIMEOUT || status == StatusCode::TOO_MANY_REQUESTS {
            return true;
        }
        if status.is_server_error() && status != StatusCode::NOT_IMPLEMENTED {
            return true;
        }
        false
    }

    /// Is the transport-layer error worth retrying?
    ///
    /// Heuristic: we retry on timeouts, connect-phase failures (resolve,
    /// refused, reset), and reqwest's built-in `is_request()` which covers
    /// things like early TLS handshake failures. Body-decode errors after a
    /// `2xx` are non-retriable — the server already committed to the
    /// response.
    fn is_retriable_transport_error(err: &reqwest::Error) -> bool {
        if err.is_timeout() || err.is_connect() {
            return true;
        }
        if err.is_request() {
            // `is_request()` covers a grab-bag of early failures including
            // failed TLS negotiation and cancelled sends — all worth a
            // second chance.
            return true;
        }
        false
    }

    /// Parse a `Retry-After` header as a delay. Accepts both the integer
    /// seconds form and the HTTP-date form (best effort — falls back to
    /// `None` on parse failure rather than fighting the server). Clamped by
    /// [`RETRY_AFTER_CAP`].
    fn parse_retry_after(headers: &HeaderMap) -> Option<Duration> {
        let value = headers.get(reqwest::header::RETRY_AFTER)?.to_str().ok()?;
        if let Ok(secs) = value.parse::<u64>() {
            return Some(Duration::from_secs(secs).min(RETRY_AFTER_CAP));
        }
        // Jellyfin doesn't emit HTTP-date-form Retry-After, so we don't pull
        // in an `httpdate` crate just for this — callers that run into such
        // a header fall back to the exponential backoff schedule below.
        None
    }

    /// Backoff for attempt `n` (1-indexed: attempt 1 is the first *retry*,
    /// i.e. the backoff *after* the initial send failed). Applies ±15%
    /// symmetric jitter seeded from the system clock.
    fn backoff_for(attempt: u32) -> Duration {
        let idx = (attempt.saturating_sub(1) as usize).min(BACKOFF_BASE_MS.len() - 1);
        let base = BACKOFF_BASE_MS[idx] as f64;
        // Cheap `±15%` jitter: the high bits of the system clock's
        // subsecond nanos are plenty random for breaking up synchronized
        // retries. Pulling in `rand` for this would be overkill.
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        // Map nanos [0, 1e9) onto jitter factor [0.85, 1.15].
        let jitter = 0.85 + (seed as f64 / 1_000_000_000.0) * 0.30;
        Duration::from_millis((base * jitter).round() as u64)
    }

    /// Issue a request with retry + backoff + silent re-auth, returning the
    /// raw [`Response`] for callers that need status inspection (e.g.
    /// `lyrics()` turning `404` into `Ok(None)`, or the favorite endpoints
    /// falling back from the preferred path to a legacy path on `404/405`).
    ///
    /// The caller passes a closure that returns a fresh
    /// [`RequestBuilder`] per attempt. Rebuilding (rather than cloning) is
    /// important for two reasons:
    ///   1. The `Authorization` header must reflect the *current* token,
    ///      not the one that was in place before a 401 refresh.
    ///   2. `RequestBuilder::try_clone` returns `None` for streaming bodies
    ///      — for uniformity we always rebuild, even when the body is a
    ///      cheap JSON blob we could have cloned.
    ///
    /// Retry rules live in [`Self::is_retriable_status`] /
    /// [`Self::is_retriable_transport_error`]; backoff ladder lives in
    /// [`BACKOFF_BASE_MS`]. `401` is handled specially: if a refresh
    /// callback is wired and returns a new token, the request is retried
    /// once; otherwise this returns [`JellifyError::AuthExpired`].
    async fn send_with_retry_raw<F>(&self, mut build: F) -> Result<Response>
    where
        F: FnMut() -> Result<RequestBuilder>,
    {
        let mut attempt: u32 = 0;
        let mut reauth_attempted = false;
        loop {
            attempt += 1;
            let builder = build()?;
            let outcome = builder.send().await;

            match outcome {
                Ok(resp) => {
                    let status = resp.status();

                    // Silent re-auth on the first 401. If we've already
                    // tried a refresh on this request, don't loop — the
                    // credentials are truly stale and the UI needs to
                    // prompt.
                    if status == StatusCode::UNAUTHORIZED && !reauth_attempted {
                        reauth_attempted = true;
                        match self.try_refresh_token() {
                            Ok(true) => {
                                tracing::warn!(
                                    "jellyfin 401 — refreshed token from keyring, retrying"
                                );
                                continue;
                            }
                            Ok(false) => return Err(JellifyError::AuthExpired),
                            Err(e) => {
                                tracing::warn!(error = %e, "token refresh failed");
                                return Err(JellifyError::AuthExpired);
                            }
                        }
                    }

                    if Self::is_retriable_status(status) && attempt < MAX_ATTEMPTS {
                        let delay = Self::parse_retry_after(resp.headers())
                            .unwrap_or_else(|| Self::backoff_for(attempt));
                        tracing::warn!(
                            attempt,
                            status = status.as_u16(),
                            delay_ms = delay.as_millis() as u64,
                            "jellyfin request retriable, backing off"
                        );
                        drop(resp);
                        // Respect the cancellation signal: if the caller's
                        // future is being torn down (e.g. user navigated away
                        // during a search) bail out immediately instead of
                        // sleeping through the full backoff delay. See #605.
                        tokio::select! {
                            _ = tokio::time::sleep(delay) => {}
                            _ = self.cancel.cancelled() => {
                                return Err(JellifyError::Other("request cancelled".into()));
                            }
                        }
                        continue;
                    }

                    return Ok(resp);
                }
                Err(err) => {
                    if Self::is_retriable_transport_error(&err) && attempt < MAX_ATTEMPTS {
                        let delay = Self::backoff_for(attempt);
                        tracing::warn!(
                            attempt,
                            error = %err,
                            delay_ms = delay.as_millis() as u64,
                            "jellyfin transport error, backing off"
                        );
                        // Same cancellation check between retries. See #605.
                        tokio::select! {
                            _ = tokio::time::sleep(delay) => {}
                            _ = self.cancel.cancelled() => {
                                return Err(JellifyError::Other("request cancelled".into()));
                            }
                        }
                        continue;
                    }
                    // Route through `From<reqwest::Error>` so cert-validation
                    // failures are mapped to `JellifyError::SelfSignedCertificate`
                    // rather than the generic `Network` variant.
                    return Err(err.into());
                }
            }
        }
    }

    /// Convenience wrapper that runs [`Self::send_with_retry_raw`] and
    /// additionally runs the response through [`Self::check`] — the path
    /// almost every caller takes. Use [`Self::send_with_retry_raw`] when a
    /// caller needs to inspect non-success status codes (e.g. 404 → Ok(None))
    /// or dispatch to a fallback endpoint.
    async fn send_with_retry<F>(&self, build: F) -> Result<Response>
    where
        F: FnMut() -> Result<RequestBuilder>,
    {
        let resp = self.send_with_retry_raw(build).await?;
        Self::check(resp).await
    }

    /// GET the given URL through the retry + silent re-auth pipeline, returning
    /// the successful response. Used by [`crate::query::ItemsQuery::execute`]
    /// so builder-driven calls participate in the same 401 refresh and backoff
    /// semantics as the per-endpoint methods in this file.
    pub(crate) async fn send_get(&self, url: Url) -> Result<Response> {
        self.send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await
    }

    /// Silent re-auth hook. Invokes the registered [`RefreshTokenFn`] (if
    /// any) and, on success, swaps the client's in-memory token so the
    /// next attempt picks it up via [`Self::auth_header`].
    ///
    /// Returns `Ok(true)` when a usable new token was installed,
    /// `Ok(false)` when either no callback is wired or the callback
    /// returned `None`, and `Err(_)` when the callback itself errored.
    fn try_refresh_token(&self) -> Result<bool> {
        let cb = match self.refresh_cb.lock().clone() {
            Some(cb) => cb,
            None => return Ok(false),
        };
        match cb()? {
            Some(new_token) => {
                // Only swap if the new token actually differs — otherwise
                // the keyring handed back the same stale token and another
                // retry would just loop.
                let changed = {
                    let mut guard = self.token.lock();
                    let differs = guard.as_deref() != Some(new_token.as_str());
                    if differs {
                        *guard = Some(new_token);
                    }
                    differs
                };
                Ok(changed)
            }
            None => Ok(false),
        }
    }

    // ----- Public info / ping -----

    pub async fn public_info(&self) -> Result<PublicSystemInfo> {
        let url = self.endpoint("System/Info/Public")?;
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone())))
            .await?;
        resp.json().await.map_err(Into::into)
    }

    // ----- Auth -----

    pub async fn authenticate_by_name(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<Session> {
        let url = self.endpoint("Users/AuthenticateByName")?;
        let body = AuthByNameBody {
            username: username.to_string(),
            pw: password.to_string(),
        };
        let resp = self
            .send_with_retry(|| {
                Ok(self
                    .http
                    .post(url.clone())
                    .headers(self.build_headers()?)
                    .json(&body))
            })
            .await?;
        let auth: AuthResult = resp.json().await?;
        *self.token.lock() = Some(auth.access_token.clone());
        self.user_id = Some(auth.user.id.clone());
        Ok(Session {
            server: Server {
                url: self.base_url.to_string(),
                name: auth.server_name.unwrap_or_default(),
                version: None,
                id: auth.server_id,
            },
            user: User {
                id: auth.user.id,
                name: auth.user.name,
                server_id: auth.user.server_id,
                primary_image_tag: auth.user.primary_image_tag,
            },
            access_token: auth.access_token,
            device_id: self.device_id.clone(),
        })
    }

    // ----- Library queries -----

    pub async fn artists(&self, paging: Paging) -> Result<PaginatedArtists> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        // `Artists/AlbumArtists` is a dedicated endpoint, not a standard
        // `/Items` query, so we issue the request directly rather than
        // going through [`ItemsQuery::execute`]. We still format the params
        // via the typed enum helpers so the set of allowed values lives in
        // one place.
        let mut url = self.endpoint("Artists/AlbumArtists")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("userId", user_id);
            q.append_pair("Recursive", "true");
            // Deliberate: no `IncludeItemTypes=MusicArtist`. Verified live
            // against music.skalthoff.com — Jellyfin 10.11 returns 0 items
            // from `/Artists/AlbumArtists` when `IncludeItemTypes=MusicArtist`
            // is supplied (the endpoint already scopes to MusicArtist by
            // path, and the server's query builder AND-intersects against
            // the type list, which apparently excludes the endpoint's own
            // inherent type on some configs). Without the filter the
            // endpoint returns the full artist list.
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", ItemSortBy::SortName.as_str());
            q.append_pair("SortOrder", SortOrder::Ascending.as_str());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[ItemField::Genres, ItemField::PrimaryImageAspectRatio],
                    ItemField::as_str,
                ),
            );
            q.append_pair("EnableUserData", "true");
            q.append_pair("EnableImages", "true");
            q.append_pair("ImageTypeLimit", "1");
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(PaginatedArtists {
            items: raw.items.into_iter().map(Artist::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    pub async fn albums(&self, paging: Paging) -> Result<PaginatedAlbums> {
        // Thin wrapper over the typed `ItemsQuery` builder — kept for
        // backwards compatibility with existing call sites. New code should
        // prefer `client.query().item_types(...).fetch_albums(...)` directly.
        ItemsQuery::new()
            .recursive()
            .item_types(vec![ItemKind::MusicAlbum])
            .limit(paging.limit)
            .offset(paging.offset)
            .sort(ItemSortBy::SortName, SortOrder::Ascending)
            .fields(vec![
                ItemField::Genres,
                ItemField::ProductionYear,
                ItemField::ChildCount,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data()
            .fetch_albums(self)
            .await
    }

    /// Every album where the given artist is the primary (album) artist,
    /// paginated and sorted by `SortName` ascending. Scopes via
    /// `AlbumArtistIds` (not `ArtistIds`) so compilations the artist only
    /// appears on don't show up in their Discography — the rule music
    /// players conventionally apply for "artist's own work".
    ///
    /// Backed by `GET /Users/{id}/Items?AlbumArtistIds={artist_id}
    /// &IncludeItemTypes=MusicAlbum&Recursive=true`. Returns a
    /// [`PaginatedAlbums`] whose `total_count` is the server's authoritative
    /// count so callers can drive "N of M" sublines.
    ///
    /// See issue #60: closes the `ArtistDetailView` gap where the
    /// Discography section silently rendered empty for any artist past
    /// the first page of the library-wide `albums` cache.
    pub async fn albums_by_artist(
        &self,
        artist_id: &str,
        paging: Paging,
    ) -> Result<PaginatedAlbums> {
        ItemsQuery::new()
            .recursive()
            .album_artist(artist_id)
            .item_types(vec![ItemKind::MusicAlbum])
            .limit(paging.limit)
            .offset(paging.offset)
            .sort(ItemSortBy::SortName, SortOrder::Ascending)
            .fields(vec![
                ItemField::Genres,
                ItemField::ProductionYear,
                ItemField::ChildCount,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data()
            .fetch_albums(self)
            .await
    }

    /// Fetch the most recently added albums in a library, respecting the
    /// authenticated user's parental controls (enforced server-side via
    /// `userId`). Backed by `GET /Items/Latest`.
    ///
    /// Notes:
    /// - The response is a bare `BaseItemDto[]` (not wrapped in
    ///   `{ Items, TotalRecordCount }` like most library endpoints).
    /// - `groupItems=true` asks the server to collapse audio children into
    ///   their parent album when both land in the "recent" window, so the
    ///   Home "Recently Added" row shows albums rather than loose tracks.
    /// - `library_id` is the music library's collection id (a "Views" item);
    ///   callers typically resolve it once at sign-in and cache it.
    ///
    /// # Pagination caveat
    ///
    /// The underlying `/Items/Latest` endpoint does NOT accept a
    /// `StartIndex` query parameter (see Jellyfin's
    /// `UserLibraryController.GetLatestMedia` — only `Limit` is exposed).
    /// To still offer a uniform `Paging` surface, this method asks the
    /// server for `offset + limit` items and slices the tail client-side.
    /// That means `offset` values larger than Jellyfin's internal
    /// "most recent" window will return an empty page even if more albums
    /// exist in the library. Callers that need the full catalog should use
    /// [`JellyfinClient::albums`] instead; `latest_albums` is optimized for
    /// the Home "Recently Added" row.
    ///
    /// `total_count` on the returned [`PaginatedAlbums`] is the number of
    /// items the server returned for this request, NOT the library total —
    /// `/Items/Latest` does not report `TotalRecordCount`.
    pub async fn latest_albums(&self, library_id: &str, paging: Paging) -> Result<PaginatedAlbums> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let limit = paging.limit.max(1);
        let server_limit = paging.offset.saturating_add(limit).max(1);
        let mut url = self.endpoint("Items/Latest")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("ParentId", library_id);
            q.append_pair("IncludeItemTypes", ItemKind::MusicAlbum.as_str());
            q.append_pair("Limit", &server_limit.to_string());
            q.append_pair("GroupItems", "true");
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::Genres,
                        ItemField::ProductionYear,
                        ItemField::ChildCount,
                        ItemField::PrimaryImageAspectRatio,
                    ],
                    ItemField::as_str,
                ),
            );
            q.append_pair("EnableUserData", "true");
            q.append_pair("EnableImages", "true");
            q.append_pair("ImageTypeLimit", "1");
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let items: Vec<RawItem> = resp.json().await?;
        let total_count = items.len() as u32;
        let sliced: Vec<Album> = items
            .into_iter()
            .skip(paging.offset as usize)
            .take(limit as usize)
            .map(Album::from)
            .collect();
        Ok(PaginatedAlbums {
            items: sliced,
            total_count,
        })
    }

    /// All audio tracks in the current user's library, sorted alphabetically
    /// by `SortName` ascending. Backed by `GET /Users/{id}/Items` with
    /// `IncludeItemTypes=Audio` and `Recursive=true`.
    ///
    /// `music_library_id` is the `MusicLibrary` CollectionFolder id; when
    /// provided it scopes the query via `ParentId`. When `None`, Jellyfin
    /// searches across all libraries the user can access — matching the
    /// behaviour of [`JellyfinClient::recently_played`].
    ///
    /// `total_count` on the returned [`PaginatedTracks`] is the server's
    /// `TotalRecordCount` so callers can drive a "N of M" subline and a
    /// page-until-done load-more trigger without issuing a separate count
    /// query.
    pub async fn list_tracks(
        &self,
        music_library_id: Option<&str>,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        let mut q = ItemsQuery::new()
            .recursive()
            .item_types(vec![ItemKind::Audio])
            .limit(paging.limit)
            .offset(paging.offset)
            .sort(ItemSortBy::SortName, SortOrder::Ascending)
            .fields(vec![
                ItemField::ParentId,
                ItemField::AlbumId,
                ItemField::AlbumArtist,
                ItemField::Artists,
                ItemField::ProductionYear,
                ItemField::RunTimeTicks,
            ])
            .enable_user_data();
        if let Some(parent) = music_library_id {
            q = q.parent(parent);
        }
        q.fetch_tracks(self).await
    }

    /// Recently played audio tracks for the current user, sorted by
    /// `DatePlayed` descending. Jellyfin implicitly omits tracks with a null
    /// `UserData.LastPlayedDate` from this sort, so the result is the user's
    /// listening history.
    ///
    /// `music_library_id` is the `MusicLibrary` CollectionFolder id; when
    /// provided it scopes the query via `ParentId`. When `None`, Jellyfin
    /// searches across all libraries the user can access.
    pub async fn recently_played(
        &self,
        music_library_id: Option<&str>,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        let mut q = ItemsQuery::new()
            .recursive()
            .item_types(vec![ItemKind::Audio])
            .limit(paging.limit)
            .offset(paging.offset)
            .sort(ItemSortBy::DatePlayed, SortOrder::Descending)
            .fields(vec![
                ItemField::ParentId,
                ItemField::MediaSources,
                ItemField::UserData,
                ItemField::ProductionYear,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data();
        if let Some(parent) = music_library_id {
            q = q.parent(parent);
        }
        q.fetch_tracks(self).await
    }

    /// Fetch every playlist visible to the current user under the given
    /// Playlists library view, paginated.
    ///
    /// `playlist_library_id` is the Playlists view id (the CollectionFolder
    /// with `CollectionType == "playlists"`). Resolving that id is handled
    /// by [`JellyfinClient::playlist_library_id`].
    ///
    /// Historical note: previous versions filtered by `Path.contains("/data/")`
    /// on the assumption that Jellyfin stores user-owned playlists under the
    /// user profile dir. That's only true on default-install servers — any
    /// server where the Playlists library is mounted elsewhere (e.g.
    /// `/sMusic/playlists/` as on music.skalthoff.com) hides *every* playlist
    /// from the client, leaving "0 OF 78 PLAYLISTS" on the UI. The filter is
    /// removed; "user-owned vs public" is a split that needs a proper
    /// discriminator (e.g. `CanDelete` or `OwnerId` from `Fields`), tracked
    /// separately.
    pub async fn user_playlists(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<PaginatedPlaylists> {
        let raw = self.playlists_items(playlist_library_id, paging).await?;
        let items: Vec<Playlist> = raw.items.into_iter().map(Playlist::from).collect();
        Ok(PaginatedPlaylists {
            items,
            total_count: raw.total_record_count,
        })
    }

    /// Same implementation as [`JellyfinClient::user_playlists`] until a
    /// reliable user-vs-public discriminator is wired. Kept as a distinct
    /// method so callers that care about the intent — a future "Community
    /// Playlists" surface — don't have to change when the split lands.
    ///
    /// Previous behaviour filtered on `!Path.contains("/data/")`. That was a
    /// false discriminator (returned everything when the Playlists library
    /// was mounted outside the user profile dir, returned nothing when it
    /// was). Same fix rationale as `user_playlists`.
    pub async fn public_playlists(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<PaginatedPlaylists> {
        // Same query today; see doc comment. Avoid duplicating the HTTP call.
        self.user_playlists(playlist_library_id, paging).await
    }

    /// Shared `GET /Items` request that returns all playlists under the
    /// given Playlists library view. `user_playlists` / `public_playlists`
    /// partition the result by `Path`. Returns the raw [`RawItems`] wrapper
    /// so callers can forward `total_record_count` to their paginated
    /// response shape.
    async fn playlists_items(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<RawItems<RawItem>> {
        // Like `playlist_tracks`, this endpoint pins the bare `/Items` path
        // with an explicit `UserId` query param (rather than
        // `/Users/{id}/Items`) so we issue the request directly rather than
        // through `ItemsQuery::execute`. Field names still come from the
        // typed enums.
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", playlist_library_id);
            q.append_pair("UserId", user_id);
            q.append_pair("IncludeItemTypes", ItemKind::Playlist.as_str());
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair(
                "Fields",
                &enums::csv(&[ItemField::ChildCount, ItemField::Path], ItemField::as_str),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw)
    }

    /// Fetch the audio tracks on a playlist, preserving the server's playlist
    /// order. Backed by `GET /Items?ParentId={playlistId}&IncludeItemTypes=Audio`.
    ///
    /// Order is load-bearing: playlists are ordered collections, so this
    /// endpoint intentionally does NOT pass `SortBy`/`SortOrder` — Jellyfin
    /// returns items in the playlist's stored order when no sort is specified.
    /// Callers that need a different sort can do it client-side.
    ///
    /// Caller-ID guard: if a caller accidentally hands the Playlists
    /// CollectionFolder id (the library-view id, not a single playlist) as
    /// `playlist_id`, the server **ignores `IncludeItemTypes=Audio`** under a
    /// folder parent and returns the folder's children — 78 Playlist-typed
    /// entries that would otherwise get mapped through `Track::from` and
    /// render as minute-long "tracks" on the UI. Defend with a
    /// post-response `kind == "Audio"` filter so the pipe refuses to accept
    /// non-audio rows regardless of what the server returns.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn playlist_tracks(
        &self,
        playlist_id: &str,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        // Note: we intentionally do NOT pass `SortBy`/`SortOrder` here —
        // playlists are ordered collections and Jellyfin returns items in
        // their stored order when no sort is specified. The test asserts on
        // the absence of those params.
        //
        // Also note: the original call site used the bare `/Items` endpoint
        // with an explicit `UserId=...` query param rather than the
        // `/Users/{id}/Items` form `ItemsQuery::execute` dispatches to.
        // We preserve that by hand-rolling the URL here so the test that
        // pins `query_param("ParentId", ...)` against the bare `/Items`
        // path keeps matching.
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", playlist_id);
            q.append_pair("UserId", user_id);
            q.append_pair("IncludeItemTypes", ItemKind::Audio.as_str());
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::MediaSources,
                        ItemField::ParentId,
                        ItemField::Path,
                        ItemField::PlaylistItemId,
                        ItemField::SortName,
                    ],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        let items: Vec<Track> = raw
            .items
            .into_iter()
            .filter(|i| i.kind.as_deref() == Some("Audio"))
            .map(Track::from)
            .collect();
        // `total_count` is the server's `TotalRecordCount` — may over-count
        // if we just rejected non-Audio entries. That's fine for the UI
        // (our items.len() is the authoritative "what we rendered"); leaving
        // total as the server value preserves the pagination contract.
        Ok(PaginatedTracks {
            items,
            total_count: raw.total_record_count,
        })
    }

    /// Append tracks (or any items) to the end of a playlist.
    ///
    /// Backed by `POST /Playlists/{playlistId}/Items?Ids={csv}&UserId={userId}`.
    /// The endpoint accepts a comma-separated `Ids` query parameter and
    /// returns 204 on success with no body — mirroring Jellify's
    /// `addManyToPlaylist` so track/album/artist "Add to playlist" actions
    /// (and sidebar drag-drop) can batch writes in one round-trip.
    ///
    /// The request body is empty; all parameters are in the query string.
    /// Callers should invalidate their `playlist_tracks` cache on success.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn add_to_playlist(
        &self,
        playlist_id: &str,
        item_ids: &[&str],
        position: Option<u32>,
    ) -> Result<()> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Playlists/{playlist_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Ids", &item_ids.join(","));
            q.append_pair("UserId", user_id);
            if let Some(pos) = position {
                q.append_pair("StartIndex", &pos.to_string());
            }
        }
        self.send_with_retry(|| Ok(self.http.post(url.clone()).headers(self.build_headers()?)))
            .await?;
        Ok(())
    }

    pub async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        // `album_tracks` returns the flat `Vec<Track>` the callers expect
        // (no total count — album children fit in a single page), so we
        // don't use `fetch_tracks`. `SortBy=ParentIndexNumber,IndexNumber,
        // SortName` is hand-built because `ItemSortBy` doesn't have a
        // `ParentIndexNumber`/`IndexNumber` variant — those are shape-less
        // numeric index fields specific to albums, not general `ItemFields`
        // the server advertises as sort columns.
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", album_id);
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", "Audio");
            // Three sort fields → three parallel SortOrder values (Jellyfin
            // requires SortBy and SortOrder to be comma-separated arrays of
            // equal length).  Fixes #571.
            q.append_pair("SortBy", "ParentIndexNumber,IndexNumber,SortName");
            // Three sort fields → three parallel SortOrder values. Fixes #571.
            q.append_pair(
                "SortOrder",
                &enums::csv(
                    &[
                        SortOrder::Ascending,
                        SortOrder::Ascending,
                        SortOrder::Ascending,
                    ],
                    SortOrder::as_str,
                ),
            );
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::MediaSources,
                        ItemField::UserData,
                        ItemField::ProductionYear,
                        ItemField::PrimaryImageAspectRatio,
                    ],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(Track::from).collect())
    }

    /// Fetch every audio track in an artist's catalog, ordered for "play all"
    /// — albums alphabetised, each album in disc + track order. Filters by
    /// `AlbumArtistIds` (not `ArtistIds`) so guest features on other artists'
    /// albums don't leak in; matches [`Self::albums_by_artist`]'s scope.
    ///
    /// Backed by `GET /Users/{id}/Items?AlbumArtistIds={id}&IncludeItemTypes=Audio
    /// &Recursive=true&SortBy=Album,ParentIndexNumber,IndexNumber
    /// &SortOrder=Ascending,Ascending,Ascending`. The three-column sort matches
    /// `album_tracks` (#571 fix) — `ItemSortBy` doesn't expose
    /// ParentIndexNumber / IndexNumber so the URL is hand-rolled. `paging`
    /// drives the standard `Limit` / `StartIndex` pair; callers wanting the
    /// full discography pass a generous `limit` (e.g. 500) and accept the
    /// soft cap. See #156.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn tracks_by_artist(
        &self,
        artist_id: &str,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("AlbumArtistIds", artist_id);
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", ItemKind::Audio.as_str());
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            // Three-field sort gives proper catalog order: album name,
            // then disc, then track. Hand-rolled because ItemSortBy doesn't
            // expose ParentIndexNumber / IndexNumber.
            q.append_pair("SortBy", "Album,ParentIndexNumber,IndexNumber");
            q.append_pair(
                "SortOrder",
                &enums::csv(
                    &[
                        SortOrder::Ascending,
                        SortOrder::Ascending,
                        SortOrder::Ascending,
                    ],
                    SortOrder::as_str,
                ),
            );
            q.append_pair("EnableUserData", "true");
            q.append_pair("EnableImages", "true");
            q.append_pair("ImageTypeLimit", "1");
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::MediaSources,
                        ItemField::UserData,
                        ItemField::ParentId,
                        ItemField::AlbumId,
                        ItemField::AlbumArtist,
                        ItemField::Artists,
                        ItemField::ProductionYear,
                        ItemField::PrimaryImageAspectRatio,
                        ItemField::RunTimeTicks,
                    ],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        let items: Vec<Track> = raw.items.into_iter().map(Track::from).collect();
        Ok(PaginatedTracks {
            items,
            total_count: raw.total_record_count,
        })
    }

    /// Fetch an artist's "top tracks" — audio items credited to the given
    /// artist, sorted by the user's `PlayCount` descending with `SortName` as
    /// a stable tiebreaker. Backed by
    /// `GET /Items?artistIds={id}&IncludeItemTypes=Audio&SortBy=PlayCount,SortName&SortOrder=Descending,Ascending`.
    ///
    /// Powers the Artist detail "Top Tracks" section (#229). Tracks the user
    /// has never played come back with `PlayCount = 0`; Jellyfin still
    /// returns them but the 0-count rows naturally sort to the bottom.
    /// Callers typically pass `limit = 5` for the compact row on the
    /// artist page.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn artist_top_tracks(&self, artist_id: &str, limit: u32) -> Result<Vec<Track>> {
        let page = ItemsQuery::new()
            .artist(artist_id)
            .recursive()
            .item_types(vec![ItemKind::Audio])
            .limit(limit)
            .sort_by(vec![ItemSortBy::PlayCount, ItemSortBy::SortName])
            .sort_order(vec![SortOrder::Descending, SortOrder::Ascending])
            .fields(vec![
                ItemField::MediaSources,
                ItemField::UserData,
                ItemField::ParentId,
                ItemField::ProductionYear,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data()
            .fetch_tracks(self)
            .await?;
        Ok(page.items)
    }

    /// Seed a station around any item — track, album, artist, playlist, or
    /// genre — via Jellyfin's polymorphic `GET /Items/{id}/InstantMix`.
    /// Returns a freshly generated queue of audio tracks the caller drops
    /// into the player.
    ///
    /// Jellyfin exposes per-type siblings (`/Artists/{id}/InstantMix`,
    /// `/Albums/{id}/InstantMix`, ...) but the generic `/Items` variant
    /// accepts any id — so a single method covers every "Start Radio"
    /// context-menu entry in the app.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn instant_mix(&self, item_id: &str, limit: u32) -> Result<Vec<Track>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Items/{item_id}/InstantMix"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("Limit", &limit.max(1).to_string());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::MediaSources,
                        ItemField::UserData,
                        ItemField::ParentId,
                        ItemField::ProductionYear,
                        ItemField::PrimaryImageAspectRatio,
                    ],
                    ItemField::as_str,
                ),
            );
            q.append_pair("EnableUserData", "true");
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(Track::from).collect())
    }

    /// Server-curated suggestions for the Home "You might like" row.
    /// Backed by `GET /Items/Suggestions?mediaType=Audio&type=MusicAlbum,MusicArtist`.
    ///
    /// Jellyfin ranks the result on the server side using tag / play-history
    /// overlap, so this is more useful than the pure recency-ordered
    /// [`JellyfinClient::latest_albums`] for long-tail discovery. The UI
    /// typically only needs a short shelf (12 is a reasonable default).
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn suggestions(&self, limit: u32) -> Result<Vec<Track>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items/Suggestions")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair(
                "IncludeItemTypes",
                &enums::csv(&[ItemKind::Audio, ItemKind::MusicAlbum], ItemKind::as_str),
            );
            q.append_pair("Limit", &limit.max(1).to_string());
            q.append_pair("EnableUserData", "true");
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(Track::from).collect())
    }

    /// Artists similar to `artist_id` — Jellyfin's `GET /Artists/{id}/Similar`.
    /// Used by the artist detail "Fans also like" shelf. Server uses tag /
    /// genre overlap for similarity, so results are reasonable even on
    /// modest libraries.
    pub async fn similar_artists(&self, artist_id: &str, limit: u32) -> Result<Vec<Artist>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Artists/{artist_id}/Similar"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("Limit", &limit.max(1).to_string());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[ItemField::Genres, ItemField::PrimaryImageAspectRatio],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(Artist::from).collect())
    }

    /// Albums similar to `album_id` — Jellyfin's `GET /Albums/{id}/Similar`.
    /// Used by the album detail "Similar albums" shelf.
    pub async fn similar_albums(&self, album_id: &str, limit: u32) -> Result<Vec<Album>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Albums/{album_id}/Similar"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("Limit", &limit.max(1).to_string());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::Genres,
                        ItemField::ProductionYear,
                        ItemField::ChildCount,
                        ItemField::PrimaryImageAspectRatio,
                    ],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(Album::from).collect())
    }

    /// Generic similar-items fallback via `GET /Items/{id}/Similar` — used
    /// when the caller doesn't know (or doesn't care about) the item kind.
    /// Returns [`ItemRef`]s carrying the server's `Type` so the UI can
    /// dispatch to the right detail screen without a second fetch.
    pub async fn similar_items(&self, item_id: &str, limit: u32) -> Result<Vec<ItemRef>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Items/{item_id}/Similar"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("Limit", &limit.max(1).to_string());
            q.append_pair(
                "Fields",
                "PrimaryImageAspectRatio,BasicSyncInfo,MediaSourceCount,UserData",
            );
            q.append_pair("EnableUserData", "true");
            q.append_pair("EnableImages", "true");
            q.append_pair("ImageTypeLimit", "1");
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawItem> = resp.json().await?;
        Ok(raw.items.into_iter().map(ItemRef::from).collect())
    }

    /// Most frequently played audio tracks for the current user. Backed by
    /// `GET /Users/{id}/Items?SortBy=PlayCount&SortOrder=Descending`. Powers
    /// the Home "Play It Again" / "On Repeat" row — Jellyfin increments
    /// `PlayCount` server-side on each completed play, so the order tracks
    /// actual listening history.
    ///
    /// Returns tracks with `PlayCount >= 1` at the top; brand-new libraries
    /// with no play history will fall back to the server's `SortName`
    /// tiebreaker (every row at `PlayCount = 0`).
    pub async fn frequently_played_tracks(&self, limit: u32) -> Result<Vec<Track>> {
        let page = ItemsQuery::new()
            .recursive()
            .item_types(vec![ItemKind::Audio])
            .limit(limit)
            .sort_by(vec![ItemSortBy::PlayCount, ItemSortBy::SortName])
            .sort_order(vec![SortOrder::Descending, SortOrder::Ascending])
            .fields(vec![
                ItemField::MediaSources,
                ItemField::UserData,
                ItemField::ParentId,
                ItemField::ProductionYear,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data()
            .fetch_tracks(self)
            .await?;
        Ok(page.items)
    }

    /// All music genres in the user's library, paginated. Backed by
    /// `GET /Genres?IncludeItemTypes=Audio,MusicAlbum,MusicArtist` with
    /// `Fields=ItemCounts` so each returned [`Genre`] carries `song_count` /
    /// `album_count` in a single round-trip.
    pub async fn genres(&self, paging: Paging) -> Result<PaginatedGenres> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Genres")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("userId", user_id);
            q.append_pair("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", ItemSortBy::SortName.as_str());
            q.append_pair("SortOrder", SortOrder::Ascending.as_str());
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[ItemField::ItemCounts, ItemField::PrimaryImageAspectRatio],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawGenre> = resp.json().await?;
        Ok(PaginatedGenres {
            items: raw.items.into_iter().map(Genre::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    /// Items (albums by default) belonging to a given genre, paginated.
    /// Backed by `GET /Users/{id}/Items?GenreIds={id}&IncludeItemTypes=MusicAlbum`.
    ///
    /// Returns a [`PaginatedAlbums`] — most genre landing pages lead with
    /// albums. Callers that want per-kind filtering can follow up with
    /// [`JellyfinClient::albums`] / `artists` / `list_tracks` using
    /// `GenreIds` (a future refactor; see Issue 38).
    pub async fn items_by_genre(&self, genre_id: &str, paging: Paging) -> Result<PaginatedAlbums> {
        ItemsQuery::new()
            .genre(genre_id)
            .recursive()
            .item_types(vec![ItemKind::MusicAlbum])
            .limit(paging.limit)
            .offset(paging.offset)
            .sort(ItemSortBy::SortName, SortOrder::Ascending)
            .fields(vec![
                ItemField::Genres,
                ItemField::ProductionYear,
                ItemField::ChildCount,
                ItemField::PrimaryImageAspectRatio,
            ])
            .enable_user_data()
            .fetch_albums(self)
            .await
    }

    /// Full artist record with biography, backdrops, and external links —
    /// extends [`JellyfinClient::fetch_item`] with an artist-focused field
    /// projection. Powers the artist detail header (bio + MusicBrainz /
    /// Last.fm / Discogs shortcut icons).
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn artist_detail(&self, artist_id: &str) -> Result<ArtistDetail> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Ids", artist_id);
            q.append_pair("userId", user_id);
            q.append_pair(
                "Fields",
                &enums::csv(
                    &[
                        ItemField::Overview,
                        ItemField::Genres,
                        ItemField::Tags,
                        ItemField::ProviderIds,
                        ItemField::ExternalUrls,
                        ItemField::BackdropImageTags,
                        ItemField::PrimaryImageAspectRatio,
                    ],
                    ItemField::as_str,
                ),
            );
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawArtistDetail> = resp.json().await?;
        let first = raw
            .items
            .into_iter()
            .next()
            .ok_or_else(|| JellifyError::NotFound(format!("artist not found: {artist_id}")))?;
        Ok(ArtistDetail::from(first))
    }

    /// Fetch lyrics for a track via `GET /Audio/{itemId}/Lyrics`. Returns
    /// `Ok(None)` when the server reports `404` — lyrics are opt-in
    /// metadata and missing-lyrics is the common case. Other errors
    /// propagate as [`JellifyError`].
    ///
    /// Handles both timed (`IsSynced = true`, LRC-style) and plain-text
    /// (`IsSynced = false`, a single line at `Start = 0`) payloads. The
    /// returned [`LyricLine::time_seconds`] is already converted out of
    /// Jellyfin's 100-ns tick units so UIs can compare directly against
    /// the audio engine's playback position.
    pub async fn lyrics(&self, track_id: &str) -> Result<Option<Lyrics>> {
        self.require_token()?;
        let url = self.endpoint(&format!("Audio/{track_id}/Lyrics"))?;
        let resp = self
            .send_with_retry_raw(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        if resp.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let raw: RawLyrics = Self::check(resp).await?.json().await?;
        Ok(Some(Lyrics::from(raw)))
    }

    /// Fetch a single item by id with a caller-selected set of `Fields`.
    ///
    /// Uses `GET /Items?Ids={id}&Fields=...` as a workaround for the
    /// deprecated `/Users/{userId}/Items/{itemId}` endpoint. Returns the
    /// first element of the `Items` array as raw JSON so callers can pick
    /// whichever fields they asked for without this layer pre-projecting.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    ///
    /// Returns [`JellifyError::Server`] with status `404` when the server
    /// responds successfully but the `Items` array is empty (item not
    /// found or not visible to the current user).
    pub async fn fetch_item(&self, item_id: &str, fields: &[&str]) -> Result<serde_json::Value> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Ids", item_id);
            if !fields.is_empty() {
                q.append_pair("Fields", &fields.join(","));
            }
            q.append_pair("userId", user_id);
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let mut body: serde_json::Value = resp.json().await?;
        let items = body
            .get_mut("Items")
            .and_then(|v| v.as_array_mut())
            .ok_or_else(|| {
                JellifyError::Decode("fetch_item: response missing Items array".into())
            })?;
        if items.is_empty() {
            return Err(JellifyError::NotFound(format!("item not found: {item_id}")));
        }
        Ok(items.swap_remove(0))
    }

    /// Mark an item as a favorite for the current user.
    ///
    /// Uses the preferred `POST /UserFavoriteItems/{itemId}` endpoint, where
    /// the current user is inferred from the authentication token. If the
    /// server does not support that route (404/405 — older Jellyfin builds),
    /// this falls back to the legacy `POST /Users/{userId}/FavoriteItems/{itemId}`
    /// endpoint when a `user_id` is available.
    ///
    /// Returns the updated [`FavoriteState`] so callers can refresh UI state
    /// without refetching the item.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn set_favorite(&self, item_id: &str) -> Result<FavoriteState> {
        self.require_token()?;

        let url = self.endpoint(&format!("UserFavoriteItems/{item_id}"))?;
        let resp = self
            .send_with_retry_raw(|| Ok(self.http.post(url.clone()).headers(self.build_headers()?)))
            .await?;

        if resp.status().is_success() {
            return resp.json().await.map_err(Into::into);
        }

        if matches!(
            resp.status(),
            StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/FavoriteItems/{item_id}"))?;
                let legacy_resp = self
                    .send_with_retry(|| {
                        Ok(self
                            .http
                            .post(legacy_url.clone())
                            .headers(self.build_headers()?))
                    })
                    .await?;
                return legacy_resp.json().await.map_err(Into::into);
            }
        }

        Self::check(resp).await?.json().await.map_err(Into::into)
    }

    /// Remove the favorite flag from an item for the current user.
    ///
    /// Uses the preferred `DELETE /UserFavoriteItems/{itemId}` endpoint, where
    /// the current user is inferred from the authentication token. If the
    /// server does not support that route (404/405 — older Jellyfin builds),
    /// this falls back to the legacy `DELETE /Users/{userId}/FavoriteItems/{itemId}`
    /// endpoint when a `user_id` is available.
    ///
    /// Returns the updated [`FavoriteState`] so callers can refresh UI state
    /// without refetching the item.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn unset_favorite(&self, item_id: &str) -> Result<FavoriteState> {
        self.require_token()?;

        let url = self.endpoint(&format!("UserFavoriteItems/{item_id}"))?;
        let resp = self
            .send_with_retry_raw(|| {
                Ok(self.http.delete(url.clone()).headers(self.build_headers()?))
            })
            .await?;

        if resp.status().is_success() {
            return resp.json().await.map_err(Into::into);
        }

        if matches!(
            resp.status(),
            StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/FavoriteItems/{item_id}"))?;
                let legacy_resp = self
                    .send_with_retry(|| {
                        Ok(self
                            .http
                            .delete(legacy_url.clone())
                            .headers(self.build_headers()?))
                    })
                    .await?;
                return legacy_resp.json().await.map_err(Into::into);
            }
        }

        Self::check(resp).await?.json().await.map_err(Into::into)
    }

    /// Convenience dispatcher: route to [`Self::set_favorite`] when
    /// `favorite` is `true` and [`Self::unset_favorite`] otherwise. Used by
    /// the platform remote-control surface (macOS `MPFeedbackCommand.like`)
    /// where the transport layer only knows the desired *target* state, not
    /// whether the current item is already favorited. See issue #35.
    pub async fn toggle_favorite(&self, item_id: &str, favorite: bool) -> Result<FavoriteState> {
        if favorite {
            self.set_favorite(item_id).await
        } else {
            self.unset_favorite(item_id).await
        }
    }

    /// Mark an item (track / album / playlist) as played for the current user.
    ///
    /// Uses the preferred `POST /UserPlayedItems/{itemId}` endpoint (user
    /// inferred from the authentication token). Older Jellyfin builds that
    /// answer 404 / 405 to that route fall back to the legacy
    /// `POST /Users/{userId}/PlayedItems/{itemId}` endpoint.
    ///
    /// Returns the full updated [`UserItemData`] so the UI can update both
    /// its `played` glyph and the `play_count` text without refetching the
    /// item. Server-side this bumps `PlayCount` by one and stamps a fresh
    /// `LastPlayedDate` (Jellyfin does NOT cascade to children — calling
    /// this on an album does not increment per-track play counts).
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set. See #133.
    pub async fn mark_played(&self, item_id: &str) -> Result<UserItemData> {
        self.require_token()?;

        let url = self.endpoint(&format!("UserPlayedItems/{item_id}"))?;
        let resp = self
            .send_with_retry_raw(|| Ok(self.http.post(url.clone()).headers(self.build_headers()?)))
            .await?;

        if resp.status().is_success() {
            let raw: RawUserData = resp.json().await?;
            return Ok(raw.into());
        }

        if matches!(
            resp.status(),
            StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/PlayedItems/{item_id}"))?;
                let legacy_resp = self
                    .send_with_retry(|| {
                        Ok(self
                            .http
                            .post(legacy_url.clone())
                            .headers(self.build_headers()?))
                    })
                    .await?;
                let raw: RawUserData = legacy_resp.json().await?;
                return Ok(raw.into());
            }
        }

        let raw: RawUserData = Self::check(resp).await?.json().await?;
        Ok(raw.into())
    }

    /// Clear the played flag from an item for the current user.
    ///
    /// Uses the preferred `DELETE /UserPlayedItems/{itemId}` endpoint, with
    /// a fallback to `DELETE /Users/{userId}/PlayedItems/{itemId}` for
    /// older Jellyfin builds that answer 404 / 405.
    ///
    /// Server-side this resets `PlayCount` to zero and clears
    /// `LastPlayedDate`. Returns the updated [`UserItemData`] for the same
    /// no-refetch UI refresh as [`Self::mark_played`].
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set. See #133.
    pub async fn mark_unplayed(&self, item_id: &str) -> Result<UserItemData> {
        self.require_token()?;

        let url = self.endpoint(&format!("UserPlayedItems/{item_id}"))?;
        let resp = self
            .send_with_retry_raw(|| {
                Ok(self.http.delete(url.clone()).headers(self.build_headers()?))
            })
            .await?;

        if resp.status().is_success() {
            let raw: RawUserData = resp.json().await?;
            return Ok(raw.into());
        }

        if matches!(
            resp.status(),
            StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/PlayedItems/{item_id}"))?;
                let legacy_resp = self
                    .send_with_retry(|| {
                        Ok(self
                            .http
                            .delete(legacy_url.clone())
                            .headers(self.build_headers()?))
                    })
                    .await?;
                let raw: RawUserData = legacy_resp.json().await?;
                return Ok(raw.into());
            }
        }

        let raw: RawUserData = Self::check(resp).await?.json().await?;
        Ok(raw.into())
    }

    /// Convenience dispatcher: route to [`Self::mark_played`] when `played`
    /// is `true` and [`Self::mark_unplayed`] otherwise. Mirrors the shape
    /// of [`Self::toggle_favorite`] for callers that only know the desired
    /// target state. See #133.
    pub async fn set_played(&self, item_id: &str, played: bool) -> Result<UserItemData> {
        if played {
            self.mark_played(item_id).await
        } else {
            self.mark_unplayed(item_id).await
        }
    }

    /// Create a new playlist for the current user via `POST /Playlists`.
    ///
    /// The request body uses Jellyfin's PascalCase keys:
    /// `{Name, Ids, UserId, MediaType: "Audio"}`. `Ids` may be empty — in
    /// that case Jellyfin creates an empty playlist the caller can later
    /// populate. Jellyfin returns a `PlaylistCreationResult { Id }`; this
    /// method returns the new playlist id so callers can refetch the full
    /// record (e.g. via [`JellyfinClient::fetch_item`]) if they need it.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn create_playlist(
        &self,
        name: &str,
        item_ids: &[&str],
        position: Option<u32>,
    ) -> Result<String> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Playlists")?;
        if let Some(pos) = position {
            url.query_pairs_mut()
                .append_pair("StartIndex", &pos.to_string());
        }
        let body = CreatePlaylistBody {
            name: name.to_string(),
            ids: item_ids.iter().map(|s| s.to_string()).collect(),
            user_id: user_id.clone(),
            media_type: "Audio".to_string(),
        };
        let resp = self
            .send_with_retry(|| {
                Ok(self
                    .http
                    .post(url.clone())
                    .headers(self.build_headers()?)
                    .json(&body))
            })
            .await?;
        let result: CreatePlaylistResult = resp.json().await?;
        Ok(result.id)
    }

    /// Report current playback progress to Jellyfin. Jellify calls this
    /// roughly every 10 seconds during playback, and whenever pause/resume/
    /// seek transitions occur, so the server can drive "Now Playing" state
    /// and durable resume points.
    ///
    /// Uses `POST /Sessions/Playing/Progress` with a
    /// `PlaybackProgressInfo`-shaped JSON body. `position_ticks` is in
    /// Jellyfin's 100-ns tick units (i.e. `seconds * 10_000_000`).
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] when no token is set.
    pub async fn report_playback_progress(&self, info: PlaybackProgressInfo) -> Result<()> {
        self.require_token()?;

        let url = self.endpoint("Sessions/Playing/Progress")?;
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .json(&info))
        })
        .await?;
        Ok(())
    }

    /// Full-search query against `Users/{id}/Items?SearchTerm=…`. Returns
    /// fully-hydrated records split into typed sections (artists / albums /
    /// tracks) — use this for a "See all results" page where the UI wants
    /// cards rather than raw hints. For a debounced omnibox, prefer
    /// [`JellyfinClient::search_hints`].
    ///
    /// `paging` applies to the combined response: Jellyfin does not offer
    /// per-type pagination on this endpoint, so `total_record_count` is the
    /// server's total across ALL matched item types. Callers that want to
    /// page a single kind (only tracks, only albums) should issue typed
    /// requests via [`JellyfinClient::albums`] / `artists` etc. with
    /// `SearchTerm` — a follow-up once the UI grows that affordance.
    pub async fn search(&self, query: &str, paging: Paging) -> Result<SearchResults> {
        let page = ItemsQuery::new()
            .recursive()
            .search(query)
            .item_types(vec![
                ItemKind::MusicArtist,
                ItemKind::MusicAlbum,
                ItemKind::Audio,
            ])
            .limit(paging.limit)
            .offset(paging.offset)
            .fields(vec![
                ItemField::Genres,
                ItemField::ProductionYear,
                ItemField::PrimaryImageAspectRatio,
                ItemField::UserData,
                ItemField::MediaSources,
                ItemField::AlbumId,
            ])
            .enable_user_data()
            .execute(self)
            .await?;

        let mut artists = Vec::new();
        let mut albums = Vec::new();
        let mut tracks = Vec::new();
        for item in page.items {
            match item.kind.as_deref() {
                Some(s) if s == ItemKind::MusicArtist.as_str() => artists.push(Artist::from(item)),
                Some(s) if s == ItemKind::MusicAlbum.as_str() => albums.push(Album::from(item)),
                Some(s) if s == ItemKind::Audio.as_str() => tracks.push(Track::from(item)),
                _ => {}
            }
        }
        Ok(SearchResults {
            artists,
            albums,
            tracks,
            total_record_count: page.total_count,
        })
    }

    /// Fast typeahead search backed by `GET /Search/Hints`.
    ///
    /// Unlike [`JellyfinClient::search`], which issues a full
    /// `Users/{id}/Items` query and returns fully-hydrated records, this
    /// endpoint returns the server's trimmed [`SearchHint`] DTO: just the
    /// columns an omnibox/typeahead needs (`Name`, `Type`, `AlbumArtist`,
    /// `PrimaryImageTag`, `MatchedTerm`, ...). That makes it the right
    /// call for the debounced-per-keystroke case — cheap to fetch, cheap
    /// to render, and the results include `Type`/`MediaType` so a single
    /// flat list can be split into typed sections client-side.
    ///
    /// Scoped to music by default
    /// (`includeItemTypes=Audio,MusicAlbum,MusicArtist,Playlist`). Requires
    /// an authenticated session; returns [`JellifyError::NotAuthenticated`]
    /// if no `user_id` is set.
    ///
    /// `paging.offset` maps to Jellyfin's `startIndex` so callers can page
    /// deeper into the hint list ("Show more" in the typeahead). The
    /// returned `total_record_count` is the server-side unpaged total and
    /// is stable across pages for the same query.
    pub async fn search_hints(&self, query: &str, paging: Paging) -> Result<SearchHintResults> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Search/Hints")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("userId", user_id);
            q.append_pair("searchTerm", query);
            q.append_pair("includeItemTypes", "Audio,MusicAlbum,MusicArtist,Playlist");
            q.append_pair("limit", &paging.limit.max(1).to_string());
            q.append_pair("startIndex", &paging.offset.to_string());
        }
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawSearchHintResults = resp.json().await?;
        Ok(SearchHintResults {
            search_hints: raw.search_hints.into_iter().map(SearchHint::from).collect(),
            total_record_count: raw.total_record_count,
        })
    }

    // ----- Playback reporting -----

    /// Report that playback of an item has stopped.
    ///
    /// Backed by `POST /Sessions/Playing/Stopped`. Drives Jellyfin's
    /// server-side PlayCount increment for tracks — the server treats a
    /// stop report with `PositionTicks` near `RunTimeTicks` as a completed
    /// play. `MediaSourceId` must match the value from `/PlaybackInfo` so
    /// the server can clean up any active transcode job.
    ///
    /// Callers invoke this on track end, user-driven skip, and app quit.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn report_playback_stopped(&self, info: PlaybackStopInfo) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint("Sessions/Playing/Stopped")?;
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .json(&info))
        })
        .await?;
        Ok(())
    }

    /// Report that playback of an item has just started. Backed by
    /// `POST /Sessions/Playing` with a `PlaybackStartInfo` body.
    ///
    /// Jellyfin uses this to mark the session as "Now Playing" — other
    /// clients (Jellyfin Web etc.) then surface this device in the
    /// remote-control panel. Callers send it once per track load, right
    /// after the audio engine has begun decoding.
    ///
    /// Serialises every field in PascalCase to match the server's
    /// `PlaybackStartInfo` DTO. Optional fields are omitted when `None` so
    /// unused flags don't flip the server's default behaviour.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn report_playback_started(&self, info: PlaybackStartInfo) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint("Sessions/Playing")?;
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .json(&info))
        })
        .await?;
        Ok(())
    }

    /// Invalidate the current server session. Backed by `POST /Sessions/Logout`.
    ///
    /// Call this **before** clearing local credentials so the `Authorization`
    /// header is still valid. On success the server marks the token revoked;
    /// on any network or server error the caller should log and continue with
    /// local cleanup — an unreachable server must not block a sign-out.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn post_logout_session(&self) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint("Sessions/Logout")?;
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .header(reqwest::header::CONTENT_LENGTH, "0"))
        })
        .await?;
        Ok(())
    }

    /// Register this session's capabilities with the server. Backed by
    /// `POST /Sessions/Capabilities/Full` with a `ClientCapabilitiesDto`
    /// body.
    ///
    /// Called once post-auth (and whenever the device profile changes) so
    /// Jellyfin knows we're a music playback target. Populates the
    /// remote-control surface Jellyfin Web exposes — without this the
    /// "Play on macOS" option never appears.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn post_capabilities(&self, caps: ClientCapabilities) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint("Sessions/Capabilities/Full")?;
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .json(&caps)) // ClientCapabilities is Clone so the body can be rebuilt each attempt via serde
        })
        .await?;
        Ok(())
    }

    /// Resolve the playable media source and transcoding strategy for an
    /// item. Backed by `POST /Items/{itemId}/PlaybackInfo`.
    ///
    /// This is the canonical pre-stream hop: the server inspects the
    /// client's `DeviceProfile`, decides direct-play vs. transcode, and
    /// returns both a `PlaySessionId` (to echo on subsequent
    /// `/Sessions/Playing*` reports) and the `TranscodingUrl` to hit when
    /// direct play is not viable.
    ///
    /// `opts.user_id` is filled in from the current session when the
    /// caller leaves it `None` — Jellyfin requires `UserId` either in the
    /// body or as a query arg, and we prefer the body.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn playback_info(
        &self,
        item_id: &str,
        opts: PlaybackInfoOpts,
    ) -> Result<PlaybackInfoResponse> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        // Fill in the user id from the live session if the caller did not
        // override it. Jellyfin accepts either the body's `UserId` or a
        // `?userId=` query param; the body wins when both are supplied.
        let mut body = opts;
        if body.user_id.is_none() {
            body.user_id = Some(user_id.clone());
        }
        let url = self.endpoint(&format!("Items/{item_id}/PlaybackInfo"))?;
        let resp = self
            .send_with_retry(|| {
                Ok(self
                    .http
                    .post(url.clone())
                    .headers(self.build_headers()?)
                    .json(&body))
            })
            .await?;
        resp.json().await.map_err(Into::into)
    }

    // ----- Library resolution -----

    /// Fetch every user view visible to the current user. Backed by
    /// `GET /UserViews?userId={id}`.
    ///
    /// Each entry is a top-level library (Music, Playlists, Movies, ...).
    /// Callers typically filter by `collection_type` — `"music"` for the
    /// music library id, `"playlists"` for the playlists library id.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn user_views(&self) -> Result<Vec<Library>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("UserViews")?;
        url.query_pairs_mut().append_pair("userId", user_id);
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let raw: RawItems<RawLibrary> = resp.json().await?;
        Ok(raw.items.into_iter().map(Library::from).collect())
    }

    /// Resolve the music library's id — the CollectionFolder with
    /// `CollectionType == "music"`. Cached on the client after the first
    /// call; invalidated on [`JellyfinClient::set_session`].
    ///
    /// Errors with [`JellifyError::NotAuthenticated`] if no session is
    /// active, or [`JellifyError::Server`] with status 404 when the
    /// server has no music library (a genuinely empty install).
    pub async fn music_library_id(&self) -> Result<String> {
        if let Some(id) = self.library_cache.lock().music.clone() {
            return Ok(id);
        }
        let views = self.user_views().await?;
        let id = views
            .into_iter()
            .find(|v| v.collection_type.as_deref() == Some("music"))
            .map(|v| v.id)
            .ok_or_else(|| JellifyError::NotFound("no music library found in user views".into()))?;
        self.library_cache.lock().music = Some(id.clone());
        Ok(id)
    }

    /// Resolve the playlists library's id — the `UserView` with
    /// `CollectionType == "playlists"`. Cached on the client after the
    /// first call; invalidated on [`JellyfinClient::set_session`].
    ///
    /// Uses the same `/UserViews` endpoint as [`Self::music_library_id`].
    /// An earlier implementation hit
    /// `/Items?includeItemTypes=ManualPlaylistsFolder` on the (documented-
    /// but-wrong) assumption that the UserView wasn't surfaced. That
    /// endpoint does surface a playlists-typed item — but with a
    /// `ManualPlaylistsFolder` id that is **not a valid `ParentId`** for
    /// `/Items?ParentId=…&IncludeItemTypes=Playlist`. The UserView id is
    /// the one `/Items` actually scopes to, so that's what callers need.
    /// Verified live against Jellyfin 10.11.8: `/UserViews` surfaces
    /// `{ Type: "UserView", CollectionType: "playlists", Id: <viewId> }`
    /// and that id returns the 78 user playlists when used as `ParentId`.
    ///
    /// Errors with [`JellifyError::NotAuthenticated`] if no session is
    /// active, or [`JellifyError::Server`] with status 404 when the
    /// server has no playlists library (rare — Jellyfin synthesises one
    /// the first time a playlist is created).
    pub async fn playlist_library_id(&self) -> Result<String> {
        if let Some(id) = self.library_cache.lock().playlist.clone() {
            return Ok(id);
        }
        let views = self.user_views().await?;
        let id = views
            .into_iter()
            .find(|v| v.collection_type.as_deref() == Some("playlists"))
            .map(|v| v.id)
            .ok_or_else(|| {
                JellifyError::NotFound("no playlists library found in user views".into())
            })?;
        self.library_cache.lock().playlist = Some(id.clone());
        Ok(id)
    }

    // ----- Playlist mutation -----

    /// Remove one or more entries from a playlist. Backed by
    /// `DELETE /Playlists/{playlistId}/Items?entryIds=...`.
    ///
    /// The `entry_ids` here are `PlaylistItemId` values — the per-entry
    /// id Jellyfin exposes on playlist children, NOT the underlying item
    /// id. A single item appearing twice in a playlist has two distinct
    /// `PlaylistItemId`s, which is why the controller keys the delete on
    /// entry ids rather than item ids.
    ///
    /// Server responds 204 on success, 403 when the caller is not the
    /// playlist owner (or lacks an edit share), 404 when the playlist
    /// doesn't exist or an `entryId` isn't in it. Callers should treat
    /// 404 as "already gone" rather than fatal.
    ///
    /// Returns `Ok(())` without contacting the server when `entry_ids` is
    /// empty — saves a pointless round-trip for multi-select UIs where
    /// the selection can be cleared after checkbox toggles.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn remove_from_playlist(
        &self,
        playlist_id: &str,
        entry_ids: &[String],
    ) -> Result<()> {
        self.require_token()?;
        if entry_ids.is_empty() {
            return Ok(());
        }
        let mut url = self.endpoint(&format!("Playlists/{playlist_id}/Items"))?;
        url.query_pairs_mut()
            .append_pair("entryIds", &entry_ids.join(","));
        self.send_with_retry(|| Ok(self.http.delete(url.clone()).headers(self.build_headers()?)))
            .await?;
        Ok(())
    }

    /// Rename a playlist by updating its `Name` field via `POST /Items/{id}`.
    ///
    /// The `POST /Items/{id}` endpoint requires the full item body, so we first
    /// fetch the existing item with `GET /Items/{id}` and then re-POST with only
    /// `Name` changed. Responds 204 on success.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn rename_playlist(&self, playlist_id: &str, new_name: &str) -> Result<()> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        // Fetch the current item to prefill required fields.
        let existing = self.fetch_item(playlist_id, &[]).await?;
        // Build the update body from the existing item, overwriting Name.
        let mut body = existing;
        body["Name"] = serde_json::Value::String(new_name.to_string());
        let mut url = self.endpoint(&format!("Items/{playlist_id}"))?;
        url.query_pairs_mut().append_pair("UserId", user_id);
        self.send_with_retry(|| {
            Ok(self
                .http
                .post(url.clone())
                .headers(self.build_headers()?)
                .json(&body))
        })
        .await?;
        Ok(())
    }

    /// Delete a playlist via `DELETE /Items/{id}`.
    ///
    /// Responds 204 on success, 403 when the caller does not own the playlist
    /// (some Jellyfin configurations also accept
    /// `DELETE /Items?Ids={id}` for batch deletes — this method uses the
    /// single-item path which is broadly supported). Callers should remove
    /// the item from any in-memory caches after this returns.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn delete_playlist(&self, playlist_id: &str) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint(&format!("Items/{playlist_id}"))?;
        self.send_with_retry(|| Ok(self.http.delete(url.clone()).headers(self.build_headers()?)))
            .await?;
        Ok(())
    }

    /// Move a playlist entry to a new position via
    /// `POST /Playlists/{playlistId}/Items/{playlistItemId}/Move/{newIndex}`.
    ///
    /// `playlist_item_id` is the per-entry `PlaylistItemId` returned by
    /// `playlist_tracks` (not the underlying `ItemId`). `new_index` is
    /// zero-based and is the desired final position in the playlist.
    ///
    /// Responds 204 on success. Callers should invalidate their
    /// `playlist_tracks` cache so the UI reflects the server order.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn reorder_playlist_track(
        &self,
        playlist_id: &str,
        playlist_item_id: &str,
        new_index: u32,
    ) -> Result<()> {
        self.require_token()?;
        let url = self.endpoint(&format!(
            "Playlists/{playlist_id}/Items/{playlist_item_id}/Move/{new_index}"
        ))?;
        self.send_with_retry(|| Ok(self.http.post(url.clone()).headers(self.build_headers()?)))
            .await?;
        Ok(())
    }

    // ----- Streaming -----

    /// Fetch the full audio payload for a track, authenticated. Returns the
    /// bytes plus the reported Content-Type (needed to pick the right decoder).
    pub async fn stream_bytes(&self, track_id: &str) -> Result<(Vec<u8>, Option<String>)> {
        let url = self.stream_url(track_id, None, None)?;
        let resp = self
            .send_with_retry(|| Ok(self.http.get(url.clone()).headers(self.build_headers()?)))
            .await?;
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let bytes = resp.bytes().await?;
        Ok((bytes.to_vec(), content_type))
    }

    /// Build the URL to stream a given track.
    ///
    /// `media_source_id` should come from `MediaSourceInfo::id` returned by
    /// `POST /Items/{id}/PlaybackInfo` so the server streams the correct source
    /// when an item has multiple audio versions. `play_session_id` should be
    /// the `PlaySessionId` returned by the same endpoint and must be echoed on
    /// every subsequent progress/stop report.
    ///
    /// Advertises all containers AVFoundation / MediaPlayer handle natively,
    /// so Jellyfin direct-streams whenever the source matches. Exotic source
    /// formats fall back to a transcoded MP3 stream.
    pub fn stream_url(
        &self,
        track_id: &str,
        media_source_id: Option<&str>,
        play_session_id: Option<&str>,
    ) -> Result<Url> {
        let mut url = self.endpoint(&format!("Audio/{track_id}/universal"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", self.user_id.as_deref().unwrap_or(""));
            q.append_pair("DeviceId", &self.device_id);
            q.append_pair("MaxStreamingBitrate", "320000");
            q.append_pair("Container", "mp3,aac,m4a,flac,alac,wav,ogg,opus");
            q.append_pair("AudioCodec", "mp3,aac,flac,alac,pcm,vorbis,opus");
            q.append_pair("TranscodingContainer", "mp3");
            q.append_pair("TranscodingProtocol", "http");
            if let Some(msid) = media_source_id {
                q.append_pair("MediaSourceId", msid);
            }
            if let Some(psid) = play_session_id {
                q.append_pair("PlaySessionId", psid);
            }
            if let Some(token) = self.token.lock().as_deref() {
                q.append_pair("api_key", token);
            }
        }
        Ok(url)
    }

    /// Render the `Authorization` header value used for every Jellyfin request.
    /// Platform audio engines (AVPlayer on macOS, etc.) attach this when
    /// streaming from the URL returned by `stream_url`.
    pub fn auth_header_value(&self) -> String {
        self.auth_header()
    }

    /// Build image URL for a track/album/artist primary image.
    ///
    /// Retained for backwards compatibility; delegates to
    /// [`JellyfinClient::image_url_of_type`] with `ImageType::Primary`.
    pub fn image_url(&self, item_id: &str, tag: Option<&str>, max_width: u32) -> Result<Url> {
        self.image_url_of_type(
            item_id,
            ImageType::Primary,
            None,
            tag,
            Some(max_width),
            None,
        )
    }

    /// Build a Jellyfin image URL for any [`ImageType`].
    ///
    /// Endpoint: `GET /Items/{id}/Images/{type}/{index?}` with optional query
    /// parameters `maxWidth`, `maxHeight`, `quality`, and `tag`. `index` is
    /// meaningful for types that are keyed (notably `Backdrop`, which has one
    /// URL per entry in `BackdropImageTags`).
    pub fn image_url_of_type(
        &self,
        item_id: &str,
        image_type: ImageType,
        index: Option<u32>,
        tag: Option<&str>,
        max_width: Option<u32>,
        max_height: Option<u32>,
    ) -> Result<Url> {
        let path = match index {
            Some(i) => format!("Items/{item_id}/Images/{}/{i}", image_type.as_path()),
            None => format!("Items/{item_id}/Images/{}", image_type.as_path()),
        };
        let mut url = self.endpoint(&path)?;
        {
            let mut q = url.query_pairs_mut();
            if let Some(w) = max_width {
                q.append_pair("maxWidth", &w.to_string());
            }
            if let Some(h) = max_height {
                q.append_pair("maxHeight", &h.to_string());
            }
            q.append_pair("quality", "90");
            if let Some(t) = tag {
                q.append_pair("tag", t);
            }
        }
        Ok(url)
    }
}

/// Classify a [`reqwest::Response`] as success or a structured
/// [`JellifyError`] variant. Shared between [`JellyfinClient::check`] and
/// the query-layer helpers in [`crate::query`].
///
/// On non-2xx responses this reads the `Retry-After` header (for 429
/// rate-limit responses) and the body text (for the general `Server`
/// variant), and dispatches via [`JellifyError::from_status`] so the caller
/// can match on the narrow error kind rather than parsing a message.
pub(crate) async fn check_response(resp: Response) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let retry_after = resp
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u64>().ok());
    let body = resp.text().await.unwrap_or_default();
    Err(JellifyError::from_status(
        status.as_u16(),
        body,
        retry_after,
    ))
}

// ============================================================================
// Wire types (Jellyfin's JSON shapes)
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct PublicSystemInfo {
    #[serde(rename = "ServerName")]
    pub server_name: Option<String>,
    #[serde(rename = "Version")]
    pub version: Option<String>,
    #[serde(rename = "Id")]
    pub id: Option<String>,
}

#[derive(Serialize)]
struct AuthByNameBody {
    #[serde(rename = "Username")]
    username: String,
    #[serde(rename = "Pw")]
    pw: String,
}

// PlaybackProgressBody and PlaybackStoppedBody are kept as thin private
// wrappers so the public PlaybackProgressInfo / PlaybackStopInfo models can
// be serialised directly — the rename_all = "PascalCase" attribute on those
// models handles the wire format without a separate private type.
// (These aliases are no longer needed; serialisation is done via the public
// models directly in the client methods below.)

#[derive(Serialize)]
struct CreatePlaylistBody {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Ids")]
    ids: Vec<String>,
    #[serde(rename = "UserId")]
    user_id: String,
    #[serde(rename = "MediaType")]
    media_type: String,
}

#[derive(Debug, Deserialize)]
struct CreatePlaylistResult {
    #[serde(rename = "Id")]
    id: String,
}

#[derive(Debug, Deserialize)]
struct AuthResult {
    #[serde(rename = "AccessToken")]
    access_token: String,
    #[serde(rename = "ServerId")]
    server_id: Option<String>,
    #[serde(rename = "ServerName")]
    server_name: Option<String>,
    #[serde(rename = "User")]
    user: RawUser,
}

#[derive(Debug, Deserialize)]
struct RawUser {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "ServerId")]
    server_id: Option<String>,
    #[serde(rename = "PrimaryImageTag")]
    primary_image_tag: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct RawItems<T> {
    #[serde(rename = "Items", default)]
    pub(crate) items: Vec<T>,
    #[serde(rename = "TotalRecordCount", default)]
    pub(crate) total_record_count: u32,
}

#[derive(Debug, Default, Deserialize)]
pub struct RawItem {
    #[serde(rename = "Id")]
    pub id: String,
    #[serde(rename = "Name", default)]
    pub name: String,
    #[serde(rename = "Type")]
    pub kind: Option<String>,
    #[serde(rename = "AlbumId")]
    pub album_id: Option<String>,
    #[serde(rename = "Album")]
    pub album: Option<String>,
    #[serde(rename = "AlbumArtist")]
    pub album_artist: Option<String>,
    #[serde(rename = "AlbumArtistId")]
    pub album_artist_id: Option<String>,
    #[serde(rename = "ArtistItems", default)]
    pub artist_items: Vec<NamedItem>,
    #[serde(rename = "Artists", default)]
    pub artists: Vec<String>,
    #[serde(rename = "ProductionYear")]
    pub production_year: Option<i32>,
    #[serde(rename = "IndexNumber")]
    pub index_number: Option<u32>,
    #[serde(rename = "ParentIndexNumber")]
    pub parent_index_number: Option<u32>,
    #[serde(rename = "RunTimeTicks", default)]
    pub runtime_ticks: u64,
    #[serde(rename = "ChildCount")]
    pub child_count: Option<u32>,
    #[serde(rename = "Genres", default)]
    pub genres: Vec<String>,
    #[serde(rename = "UserData")]
    pub user_data: Option<RawUserData>,
    #[serde(rename = "ImageTags", default)]
    pub image_tags: std::collections::HashMap<String, String>,
    #[serde(rename = "Container")]
    pub container: Option<String>,
    #[serde(rename = "Bitrate")]
    pub bitrate: Option<u32>,
    #[serde(rename = "Path")]
    pub path: Option<String>,
    #[serde(rename = "PlaylistItemId")]
    pub playlist_item_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NamedItem {
    #[serde(rename = "Id")]
    pub id: String,
    #[serde(rename = "Name", default)]
    pub name: String,
}

/// A trimmed `BaseItemDto` used by library-resolution endpoints
/// (`/UserViews`, `GET /Items?includeItemTypes=ManualPlaylistsFolder`).
/// Only the fields the client needs to partition libraries by type.
#[derive(Debug, Default, Deserialize)]
pub struct RawLibrary {
    #[serde(rename = "Id")]
    pub id: String,
    #[serde(rename = "Name", default)]
    pub name: String,
    #[serde(rename = "CollectionType")]
    pub collection_type: Option<String>,
}

impl From<RawLibrary> for Library {
    fn from(r: RawLibrary) -> Self {
        Library {
            id: r.id,
            name: r.name,
            collection_type: r.collection_type,
        }
    }
}

#[derive(Debug, Deserialize, Default)]
pub struct RawUserData {
    #[serde(rename = "IsFavorite", default)]
    pub is_favorite: bool,
    #[serde(rename = "Played", default)]
    pub played: bool,
    #[serde(rename = "PlayCount", default)]
    pub play_count: u32,
    #[serde(rename = "PlaybackPositionTicks", default)]
    pub playback_position_ticks: i64,
    #[serde(rename = "LastPlayedDate", default)]
    pub last_played_date: Option<String>,
    #[serde(rename = "Likes", default)]
    pub likes: Option<bool>,
    #[serde(rename = "Rating", default)]
    pub rating: Option<f64>,
}

impl From<RawUserData> for UserItemData {
    fn from(r: RawUserData) -> Self {
        UserItemData {
            is_favorite: r.is_favorite,
            played: r.played,
            play_count: r.play_count,
            playback_position_ticks: r.playback_position_ticks,
            last_played_at: r.last_played_date,
            likes: r.likes,
            rating: r.rating,
        }
    }
}

#[derive(Debug, Deserialize)]
struct RawSearchHintResults {
    #[serde(rename = "SearchHints", default)]
    search_hints: Vec<RawSearchHint>,
    #[serde(rename = "TotalRecordCount", default)]
    total_record_count: u32,
}

#[derive(Debug, Deserialize)]
struct RawSearchHint {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name", default)]
    name: String,
    #[serde(rename = "Type")]
    kind: Option<String>,
    #[serde(rename = "MediaType")]
    media_type: Option<String>,
    #[serde(rename = "Album")]
    album: Option<String>,
    #[serde(rename = "AlbumId")]
    album_id: Option<String>,
    #[serde(rename = "AlbumArtist")]
    album_artist: Option<String>,
    #[serde(rename = "MatchedTerm")]
    matched_term: Option<String>,
    #[serde(rename = "PrimaryImageTag")]
    primary_image_tag: Option<String>,
    #[serde(rename = "ThumbImageTag")]
    thumb_image_tag: Option<String>,
    #[serde(rename = "BackdropImageTag")]
    backdrop_image_tag: Option<String>,
    #[serde(rename = "PrimaryImageAspectRatio")]
    primary_image_aspect_ratio: Option<f64>,
    #[serde(rename = "ProductionYear")]
    production_year: Option<i32>,
    #[serde(rename = "IndexNumber")]
    index_number: Option<u32>,
    #[serde(rename = "ParentIndexNumber")]
    parent_index_number: Option<u32>,
    #[serde(rename = "RunTimeTicks")]
    run_time_ticks: Option<u64>,
    #[serde(rename = "Artists", default)]
    artists: Vec<String>,
    #[serde(rename = "IsFolder")]
    is_folder: Option<bool>,
}

impl From<RawSearchHint> for SearchHint {
    fn from(r: RawSearchHint) -> Self {
        SearchHint {
            id: r.id,
            name: r.name,
            kind: r.kind,
            media_type: r.media_type,
            album: r.album,
            album_id: r.album_id,
            album_artist: r.album_artist,
            matched_term: r.matched_term,
            primary_image_tag: r.primary_image_tag,
            thumb_image_tag: r.thumb_image_tag,
            backdrop_image_tag: r.backdrop_image_tag,
            primary_image_aspect_ratio: r.primary_image_aspect_ratio,
            production_year: r.production_year,
            index_number: r.index_number,
            parent_index_number: r.parent_index_number,
            runtime_ticks: r.run_time_ticks,
            artists: r.artists,
            is_folder: r.is_folder,
        }
    }
}

// ============================================================================
// Conversions
// ============================================================================

impl From<RawItem> for Artist {
    fn from(r: RawItem) -> Self {
        let user_data = r.user_data.map(UserItemData::from);
        Artist {
            id: r.id,
            name: r.name,
            album_count: 0,
            song_count: 0,
            genres: r.genres,
            image_tag: r.image_tags.get("Primary").cloned(),
            user_data,
        }
    }
}

impl From<RawItem> for Album {
    fn from(r: RawItem) -> Self {
        let artist_name = r
            .album_artist
            .clone()
            .or_else(|| r.artists.first().cloned())
            .unwrap_or_default();
        let artist_id = r
            .album_artist_id
            .clone()
            .or_else(|| r.artist_items.first().map(|a| a.id.clone()));
        let user_data = r.user_data.map(UserItemData::from);
        Album {
            id: r.id,
            name: r.name,
            artist_name,
            artist_id,
            year: r.production_year,
            track_count: r.child_count.unwrap_or(0),
            runtime_ticks: r.runtime_ticks,
            genres: r.genres,
            image_tag: r.image_tags.get("Primary").cloned(),
            user_data,
        }
    }
}

impl From<RawItem> for Playlist {
    fn from(r: RawItem) -> Self {
        Playlist {
            id: r.id,
            name: r.name,
            track_count: r.child_count.unwrap_or(0),
            runtime_ticks: r.runtime_ticks,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}

impl From<RawItem> for Track {
    fn from(r: RawItem) -> Self {
        let artist_name = r
            .album_artist
            .clone()
            .or_else(|| r.artists.first().cloned())
            .unwrap_or_default();
        let artist_id = r
            .album_artist_id
            .clone()
            .or_else(|| r.artist_items.first().map(|a| a.id.clone()));
        // Preserve the pre-refactor convenience fields on Track even when
        // the server didn't send `UserData` — `is_favorite`/`play_count`
        // default to `false`/`0` the same way they did before the
        // `user_data: Option<UserItemData>` field landed. Callers that need
        // the full payload (including last-played-at, position ticks,
        // thumbs rating) read `user_data`.
        let raw_user = r.user_data;
        let (is_fav, play_count) = raw_user
            .as_ref()
            .map(|u| (u.is_favorite, u.play_count))
            .unwrap_or((false, 0));
        let user_data = raw_user.map(UserItemData::from);
        Track {
            id: r.id,
            name: r.name,
            album_id: r.album_id,
            album_name: r.album,
            artist_name,
            artist_id,
            index_number: r.index_number,
            disc_number: r.parent_index_number,
            year: r.production_year,
            runtime_ticks: r.runtime_ticks,
            is_favorite: is_fav,
            play_count,
            container: r.container,
            bitrate: r.bitrate,
            image_tag: r.image_tags.get("Primary").cloned(),
            playlist_item_id: r.playlist_item_id,
            user_data,
        }
    }
}

impl From<RawItem> for ItemRef {
    fn from(r: RawItem) -> Self {
        ItemRef {
            id: r.id,
            name: r.name,
            kind: r.kind,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}

/// `GET /MusicGenres` returns `BaseItemDto`s with `ItemCounts` projected, so
/// the counts land at top-level `SongCount` / `AlbumCount` — a different
/// shape from [`RawItem`]'s music-item fields. Kept as a standalone wire
/// type so the parser can't silently pick up the wrong counters.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawGenre {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    song_count: u32,
    #[serde(default)]
    album_count: u32,
    #[serde(default)]
    image_tags: std::collections::HashMap<String, String>,
}

impl From<RawGenre> for Genre {
    fn from(r: RawGenre) -> Self {
        Genre {
            id: r.id,
            name: r.name,
            song_count: r.song_count,
            album_count: r.album_count,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}

/// Wire shape for a single element of `GET /Items?Ids={id}` projected with
/// artist-detail fields. Separate from [`RawItem`] because the interesting
/// fields — `Overview`, `BackdropImageTags`, `ExternalUrls` — aren't on
/// the music-item path.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawArtistDetail {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    genres: Vec<String>,
    #[serde(default)]
    image_tags: std::collections::HashMap<String, String>,
    overview: Option<String>,
    #[serde(default)]
    backdrop_image_tags: Vec<String>,
    #[serde(default)]
    external_urls: Vec<RawExternalUrl>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawExternalUrl {
    #[serde(default)]
    name: String,
    #[serde(default)]
    url: String,
}

impl From<RawExternalUrl> for ExternalUrl {
    fn from(r: RawExternalUrl) -> Self {
        ExternalUrl {
            name: r.name,
            url: r.url,
        }
    }
}

impl From<RawArtistDetail> for ArtistDetail {
    fn from(r: RawArtistDetail) -> Self {
        ArtistDetail {
            id: r.id,
            name: r.name,
            genres: r.genres,
            image_tag: r.image_tags.get("Primary").cloned(),
            overview: r.overview,
            backdrop_image_tags: r.backdrop_image_tags,
            external_urls: r.external_urls.into_iter().map(ExternalUrl::from).collect(),
        }
    }
}

/// `GET /Audio/{id}/Lyrics` returns `LyricDto { Metadata, Lyrics }`.
/// Jellyfin keys timestamps on `Start` in 100-ns ticks; we convert to
/// seconds on deserialization so callers can compare directly against the
/// platform audio engine's playback position.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawLyrics {
    #[serde(default)]
    metadata: RawLyricsMetadata,
    #[serde(default, rename = "Lyrics")]
    lines: Vec<RawLyricLine>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawLyricsMetadata {
    #[serde(default)]
    is_synced: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct RawLyricLine {
    #[serde(default)]
    start: i64,
    #[serde(default)]
    text: String,
}

impl From<RawLyrics> for Lyrics {
    fn from(r: RawLyrics) -> Self {
        Lyrics {
            is_synced: r.metadata.is_synced,
            lines: r
                .lines
                .into_iter()
                .map(|l| LyricLine {
                    time_seconds: l.start as f64 / 10_000_000.0,
                    text: l.text,
                })
                .collect(),
        }
    }
}
