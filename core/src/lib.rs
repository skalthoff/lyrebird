//! Lyrebird core — shared Rust library for the desktop apps.
//!
//! The public surface is the [`LyrebirdCore`] type, which owns the Jellyfin
//! HTTP client, the local database, and queue/player bookkeeping. Platform
//! UIs consume this either via UniFFI bindings (Swift/C#) or directly (GTK /
//! Rust).
//!
//! Audio output is NOT in the core — it lives on the platform side
//! (AVFoundation on macOS, MediaPlayer on Windows, GStreamer on Linux).
//! The core exposes authenticated stream URLs; the platform decides how to
//! play them and calls back with status updates.

pub mod client;
pub mod downloads;
pub mod enums;
pub mod error;
pub mod models;
pub mod player;
pub mod query;
pub mod scrobble;
pub mod storage;

pub use enums::{ImageType, ItemField, ItemKind, ItemSortBy, SortOrder};
pub use error::{LyrebirdError, Result};
pub use models::*;
pub use player::{PlaybackState, Player, PlayerStatus, RepeatMode};
pub use query::ItemsQuery;

use crate::client::{JellyfinClient, PublicSystemInfo};
use crate::storage::{CredentialStore, Database};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::Arc;
use uuid::Uuid;

uniffi::setup_scaffolding!();

/// **Legacy** settings-table key under which pre-keyring builds persisted the
/// ListenBrainz token in plaintext. The token now lives in the OS keyring (see
/// [`storage::CredentialStore::save_scrobble_token`]); this key is retained
/// only so [`LyrebirdCore::set_scrobble_token`] can scrub a leftover plaintext
/// value from an upgraded install.
const SCROBBLE_TOKEN_KEY: &str = "scrobble_listenbrainz_token";

/// Handle for a running heartbeat task.  Dropping or calling [`stop`] cancels
/// the background interval so there are no leaked timers after skip / logout.
struct HeartbeatHandle {
    abort: tokio::task::AbortHandle,
}

impl HeartbeatHandle {
    fn stop(&self) {
        self.abort.abort();
    }
}

impl Drop for HeartbeatHandle {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

/// Default number of offline downloads allowed to stream in parallel (#819:
/// "default 2 parallel transfers"). Bounds [`LyrebirdCore::download_semaphore`].
const DOWNLOAD_PARALLELISM: usize = 2;

/// The main handle a UI holds.
#[derive(uniffi::Object)]
pub struct LyrebirdCore {
    inner: Arc<Mutex<Inner>>,
    player: Arc<Player>,
    runtime: tokio::runtime::Runtime,
    /// Running heartbeat task, if one was started via [`Self::start_heartbeat`].
    heartbeat: Mutex<Option<HeartbeatHandle>>,
    /// Caps how many offline downloads stream concurrently (#819 — default
    /// [`DOWNLOAD_PARALLELISM`]). Acquired by `downloads::fetch` for the
    /// duration of each transfer. Shared (not behind the `Inner` mutex) so the
    /// permit can be held across the network stream without keeping the FFI
    /// lock — `download_track` clones this `Arc` under the lock, then awaits
    /// outside it.
    download_semaphore: Arc<tokio::sync::Semaphore>,
    /// Serialises offline-download budget planning + the size-checked commit so
    /// two concurrent `download_track` calls can't each pass the budget check
    /// and collectively overshoot. Held only around the cheap plan/commit
    /// critical sections, never across the byte stream. See `downloads::fetch`.
    download_budget_lock: Arc<tokio::sync::Mutex<()>>,
}

struct Inner {
    /// Wrapped in `Arc` so callers (`with_client`, the heartbeat scheduler,
    /// the 401 interceptor) can hold a handle to the live client without
    /// keeping `Inner`'s `Mutex` locked across HTTP I/O. Every synchronous
    /// FFI entry point clones this `Arc` under the lock, then drops the
    /// guard before `tokio::block_on`, so in-flight requests do not stall
    /// concurrent main-thread FFIs.
    client: Option<Arc<JellyfinClient>>,
    /// Wrapped in `Arc` so the HTTP client's 401 interceptor can close over
    /// a standalone handle (see [`JellyfinClient::set_refresh_callback`])
    /// without needing to re-lock `Inner`. Keeping the refresh path off the
    /// `Inner` mutex sidesteps any risk of recursion or contention with
    /// whichever thread kicked off the 401-returning request.
    db: Arc<Database>,
    device_id: String,
    device_name: String,
    /// Resolved root data directory (the parent of `lyrebird.db`). Held so the
    /// downloads engine can locate the default offline-audio directory
    /// (`<data_dir>/downloads`) without recomputing it. See `downloads.rs`.
    data_dir: PathBuf,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreConfig {
    pub data_dir: String,
    pub device_name: String,
}

#[uniffi::export]
impl LyrebirdCore {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> std::result::Result<Arc<Self>, LyrebirdError> {
        let data_dir = if config.data_dir.is_empty() {
            storage::default_data_dir()
        } else {
            PathBuf::from(&config.data_dir)
        };
        let db_path = data_dir.join("lyrebird.db");
        let db = Arc::new(Database::open(&db_path)?);

        let device_id = match db.get_setting("device_id")? {
            Some(id) => id,
            None => {
                let id = Uuid::new_v4().to_string();
                db.set_setting("device_id", &id)?;
                id
            }
        };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| LyrebirdError::Other(format!("tokio runtime: {e}")))?;

        // Restore shuffle/repeat state from the previous launch.
        let player = Arc::new(Player::new());
        if let Ok((shuffle, repeat)) = db.load_shuffle_repeat() {
            player.set_shuffle(shuffle);
            player.set_repeat_mode(repeat);
        }

        Ok(Arc::new(Self {
            inner: Arc::new(Mutex::new(Inner {
                client: None,
                db,
                device_id,
                device_name: config.device_name,
                data_dir,
            })),
            player,
            runtime,
            heartbeat: Mutex::new(None),
            download_semaphore: Arc::new(tokio::sync::Semaphore::new(DOWNLOAD_PARALLELISM)),
            download_budget_lock: Arc::new(tokio::sync::Mutex::new(())),
        }))
    }

    pub fn device_id(&self) -> String {
        self.inner.lock().device_id.clone()
    }

    pub fn probe_server(&self, url: String) -> std::result::Result<Server, LyrebirdError> {
        let (device_id, device_name) = {
            let inner = self.inner.lock();
            (inner.device_id.clone(), inner.device_name.clone())
        };
        let client = JellyfinClient::new(&url, device_id, device_name)?;
        let info: PublicSystemInfo = self.runtime.block_on(client.public_info())?;
        Ok(Server {
            url: client.base_url().to_string(),
            name: info.server_name.unwrap_or_else(|| "Jellyfin".to_string()),
            version: info.version,
            id: info.id,
        })
    }

    pub fn login(
        &self,
        url: String,
        username: String,
        password: String,
    ) -> std::result::Result<models::Session, LyrebirdError> {
        let username = username.trim().to_string();
        let password = password.trim().to_string();
        // Jellyfin allows accounts with no password — the server is the
        // authority on whether a given (user, password) pair is valid, so
        // we only short-circuit on missing username. Empty password is
        // forwarded as `Pw: ""` to /Users/AuthenticateByName.
        if username.is_empty() {
            return Err(LyrebirdError::InvalidCredentials);
        }

        let (device_id, device_name, db) = {
            let inner = self.inner.lock();
            (
                inner.device_id.clone(),
                inner.device_name.clone(),
                inner.db.clone(),
            )
        };
        let mut client = JellyfinClient::new(&url, device_id, device_name)?;
        let session = self
            .runtime
            .block_on(client.authenticate_by_name(&username, &password))?;

        if let Some(server_id) = &session.server.id {
            CredentialStore::save_token(server_id, &session.user.name, &session.access_token)
                .map_err(|e| LyrebirdError::KeyringWrite {
                    reason: e.to_string(),
                })?;
        }
        {
            let inner = self.inner.lock();
            inner
                .db
                .set_setting("last_server_url", &session.server.url)?;
            inner.db.set_setting("last_username", &session.user.name)?;
            if let Some(server_id) = &session.server.id {
                inner.db.set_setting("last_server_id", server_id)?;
            }
            inner.db.set_setting("last_user_id", &session.user.id)?;
        }
        let client = Arc::new(client);
        Self::install_refresh_callback(&client, &db);
        self.inner.lock().client = Some(client);
        Ok(session)
    }

    /// Rehydrate the previous session from persisted state. Returns
    /// `Ok(Some(session))` when all of `last_server_url`, `last_username`,
    /// `last_server_id`, `last_user_id`, and the keyring token for that
    /// user/server pair are present; otherwise `Ok(None)` so the caller can
    /// fall back to the login screen.
    ///
    /// Best-effort hydration: `server.name` and `user.primary_image_tag` are
    /// left blank — the next library call will refresh them, and we do NOT
    /// block this call on network availability so users launching offline
    /// still see their cached library instantly.
    pub fn resume_session(&self) -> std::result::Result<Option<Session>, LyrebirdError> {
        let (device_id, device_name, db, server_url, username, server_id, user_id) = {
            let inner = self.inner.lock();
            let server_url = match inner.db.get_setting("last_server_url")? {
                Some(v) => v,
                None => return Ok(None),
            };
            let username = match inner.db.get_setting("last_username")? {
                Some(v) => {
                    let v = v.trim().to_string();
                    if v.is_empty() {
                        return Err(LyrebirdError::InvalidCredentials);
                    }
                    v
                }
                None => return Ok(None),
            };
            let server_id = match inner.db.get_setting("last_server_id")? {
                Some(v) => v,
                None => return Ok(None),
            };
            let user_id = match inner.db.get_setting("last_user_id")? {
                Some(v) => v,
                None => return Ok(None),
            };
            (
                inner.device_id.clone(),
                inner.device_name.clone(),
                inner.db.clone(),
                server_url,
                username,
                server_id,
                user_id,
            )
        };

        let token = match CredentialStore::load_token(&server_id, &username)? {
            Some(t) => t,
            None => return Ok(None),
        };

        let mut client = JellyfinClient::new(&server_url, device_id, device_name)?;
        client.set_session(token.clone(), user_id.clone());
        let client = Arc::new(client);
        Self::install_refresh_callback(&client, &db);
        let resolved_url = client.base_url().to_string();
        self.inner.lock().client = Some(client);

        Ok(Some(Session {
            server: Server {
                url: resolved_url,
                name: String::new(),
                version: None,
                id: Some(server_id.clone()),
            },
            user: User {
                id: user_id,
                name: username,
                server_id: Some(server_id),
                primary_image_tag: None,
            },
            access_token: token,
            device_id: self.inner.lock().device_id.clone(),
        }))
    }

    pub fn logout(&self) -> std::result::Result<(), LyrebirdError> {
        // 1. Invalidate the server session while the token is still valid.
        //    Log but do not abort on any error — an unreachable server must
        //    not prevent local cleanup (#592).
        let client = self.inner.lock().client.clone();
        if let Some(client) = client {
            if let Err(e) = self.runtime.block_on(client.post_logout_session()) {
                tracing::warn!("POST /Sessions/Logout failed (continuing): {e}");
            }
        }

        // 2. Stop the playback heartbeat timer so it can't fire another
        //    `/Sessions/Playing/Progress` after the session is torn down
        //    (#594).
        self.stop_heartbeat();

        // 3. Wipe user-scoped DB rows (play history, caches, session keys).
        //    Read the credentials out of the DB *before* clearing so we can
        //    still delete the keyring entry after the table wipe (#568).
        {
            let inner = self.inner.lock();
            let server_id = inner.db.get_setting("last_server_id").ok().flatten();
            let username = inner.db.get_setting("last_username").ok().flatten();
            if let Err(e) = inner.db.clear_user_data() {
                tracing::warn!("clear_user_data failed (continuing): {e}");
            }
            if let (Some(sid), Some(uname)) = (server_id, username) {
                let _ = CredentialStore::delete_token(&sid, &uname);
            }
        }

        // 4. Drop the in-memory client and clear the in-process queue.
        self.inner.lock().client = None;
        self.player.clear();
        Ok(())
    }

    /// Drop the stored access token (and the ids that key into it) without
    /// wiping the remembered server URL / username. Used by the auth-expired
    /// sheet so the login form pre-fills on the re-auth attempt.
    pub fn forget_token(&self) -> std::result::Result<(), LyrebirdError> {
        {
            let inner = self.inner.lock();
            if let (Ok(Some(server_id)), Ok(Some(username))) = (
                inner.db.get_setting("last_server_id"),
                inner.db.get_setting("last_username"),
            ) {
                let _ = CredentialStore::delete_token(&server_id, &username);
            }
            let _ = inner.db.delete_setting("last_server_id");
            let _ = inner.db.delete_setting("last_user_id");
        }
        self.stop_heartbeat();
        self.inner.lock().client = None;
        self.player.clear();
        Ok(())
    }

    // ---------- Library ----------

    /// Albums in the user's library, paginated.
    ///
    /// Returns a [`PaginatedAlbums`] whose `total_count` is the full server
    /// total so callers can drive "N of M" indicators and near-end
    /// load-more triggers without issuing a separate count query.
    pub fn list_albums(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.albums(Paging::new(offset, limit))))
    }

    /// Artists in the user's library, paginated. See [`Self::list_albums`].
    pub fn list_artists(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedArtists, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.artists(Paging::new(offset, limit))))
    }

    /// Album artists most recently added to the library, sorted by
    /// server-side `DateCreated` descending. Powers the Home "Recently
    /// Discovered Artists" row (#252). Same shape as [`Self::list_artists`],
    /// only the sort differs.
    pub fn list_recently_added_artists(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedArtists, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.recently_added_artists(Paging::new(offset, limit)))
        })
    }

    /// Every album where the given artist is the primary (album) artist,
    /// paginated. Scopes by `AlbumArtistIds` on the server so compilations
    /// the artist only appears on don't leak into the Discography section.
    /// See issue #60 — closes the `ArtistDetailView` gap where the
    /// Discography was rendered by filtering a paged library-wide cache.
    pub fn albums_by_artist(
        &self,
        artist_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.albums_by_artist(&artist_id, Paging::new(offset, limit)))
        })
    }

    pub fn album_tracks(&self, album_id: String) -> std::result::Result<Vec<Track>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.album_tracks(&album_id)))
    }

    /// Fetch an artist's most-played tracks (by server-tracked `PlayCount`
    /// descending, `SortName` ascending as tiebreaker). Powers the artist
    /// detail "Top Tracks" section — see #229.
    pub fn artist_top_tracks(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.artist_top_tracks(&artist_id, limit))
        })
    }

    /// Every audio track in an artist's catalog, paginated, in catalog order
    /// (album name → disc → track). Filters by `AlbumArtistIds` so guest
    /// features on other artists' albums don't leak in. Powers the artist
    /// page "Play All" / "Shuffle" affordances — see #156.
    pub fn tracks_by_artist(
        &self,
        artist_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.tracks_by_artist(&artist_id, Paging::new(offset, limit)))
        })
    }

    /// Seed a station around any item (track, album, artist, playlist,
    /// genre) via Jellyfin's polymorphic `/Items/{id}/InstantMix`. Returns a
    /// freshly generated queue of audio tracks the caller drops into the
    /// player. Powers the "Start Radio" context-menu action.
    pub fn instant_mix(
        &self,
        item_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.instant_mix(&item_id, limit)))
    }

    /// Server-curated suggestions for the Home "You might like" row. More
    /// useful than recency-ordered recent-adds for long-tail discovery.
    pub fn suggestions(&self, limit: u32) -> std::result::Result<Vec<Track>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.suggestions(limit)))
    }

    /// Artists similar to `artist_id` — Jellyfin's tag/genre-based
    /// similarity. Powers the artist detail "Fans also like" shelf.
    pub fn similar_artists(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Artist>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.similar_artists(&artist_id, limit)))
    }

    /// Albums similar to `album_id`. Powers the album detail "Similar
    /// albums" shelf.
    pub fn similar_albums(
        &self,
        album_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Album>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.similar_albums(&album_id, limit)))
    }

    /// Generic similar-items fallback — returns typed [`ItemRef`]s so the
    /// UI can dispatch to the right detail screen without re-fetching.
    pub fn similar_items(
        &self,
        item_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<ItemRef>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.similar_items(&item_id, limit)))
    }

    /// Most frequently played tracks for the current user, ordered by the
    /// server's `PlayCount` descending. Powers the Home "Play It Again" /
    /// "On Repeat" row.
    pub fn frequently_played_tracks(
        &self,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.frequently_played_tracks(limit)))
    }

    /// All music genres in the user's library, paginated. Each [`Genre`]
    /// carries `song_count` / `album_count` via `Fields=ItemCounts`, so the
    /// Genres tab can render counts without a second round-trip.
    pub fn genres(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedGenres, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.genres(Paging::new(offset, limit))))
    }

    /// Albums belonging to a genre, paginated. Powers the genre detail
    /// landing view.
    pub fn items_by_genre(
        &self,
        genre_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.items_by_genre(&genre_id, Paging::new(offset, limit)))
        })
    }

    /// Audio tracks belonging to a genre, paginated. Mirrors
    /// [`Self::items_by_genre`] but returns tracks instead of albums —
    /// feeds the genre detail "Shuffle Genre" action and the planned
    /// all-tracks tab on genre pages (#823).
    pub fn tracks_by_genre(
        &self,
        genre_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.tracks_by_genre(&genre_id, Paging::new(offset, limit)))
        })
    }

    /// Full artist record with biography, backdrop image tags, and
    /// external links (MusicBrainz / Last.fm / Discogs). Feeds the artist
    /// detail header.
    pub fn artist_detail(
        &self,
        artist_id: String,
    ) -> std::result::Result<ArtistDetail, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.artist_detail(&artist_id)))
    }

    /// Fetch lyrics for a track. Returns `None` when the server reports 404
    /// (no lyrics available — common). Handles both synced LRC and plain
    /// text; `LyricLine::time_seconds` is pre-converted out of Jellyfin's
    /// 100-ns tick units.
    pub fn lyrics(&self, track_id: String) -> std::result::Result<Option<Lyrics>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.lyrics(&track_id)))
    }

    /// Recently added albums for the Home "Recently Added" row.
    ///
    /// Server-side filtering respects the user's parental controls; the
    /// response is grouped by album so loose tracks never appear. Callers
    /// resolve `library_id` (the music collection view id) once at sign-in.
    ///
    /// Pagination caveat: Jellyfin's `/Items/Latest` endpoint does not
    /// accept `StartIndex`, so `offset` is applied client-side by slicing
    /// the top of the returned "most-recent" window. See
    /// [`JellyfinClient::latest_albums`] for details. `total_count` on the
    /// returned [`PaginatedAlbums`] is the number of items the server
    /// returned for this request, not the library total.
    pub fn latest_albums(
        &self,
        library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.latest_albums(&library_id, Paging::new(offset, limit)))
        })
    }

    /// Every audio track in the user's library, paginated and sorted by
    /// `SortName` ascending. Pass `music_library_id` to scope to a single
    /// `MusicLibrary` CollectionFolder; pass `None` to span every library
    /// the user can access.
    ///
    /// Returns a [`PaginatedTracks`] whose `total_count` is the server's
    /// `TotalRecordCount` so callers can drive "N of M" sublines and
    /// near-end load-more triggers without issuing a separate count query.
    pub fn list_tracks(
        &self,
        music_library_id: Option<String>,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.list_tracks(music_library_id.as_deref(), Paging::new(offset, limit)))
        })
    }

    /// Recently played tracks for the current user, sorted by server-side
    /// `DatePlayed` descending. Pass `music_library_id` to scope to a single
    /// `MusicLibrary` CollectionFolder.
    pub fn recently_played(
        &self,
        music_library_id: Option<String>,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, LyrebirdError> {
        self.with_client(|c| {
            self.runtime.block_on(
                c.recently_played(music_library_id.as_deref(), Paging::new(offset, limit)),
            )
        })
    }

    /// Playlists owned by the current user. Filtered client-side based on
    /// whether `Path` contains `/data/` (profile directory). `total_count`
    /// on the returned [`PaginatedPlaylists`] is the server's unfiltered
    /// count across both user- and public-owned playlists — see
    /// [`JellyfinClient::user_playlists`].
    pub fn user_playlists(
        &self,
        playlist_library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedPlaylists, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.user_playlists(&playlist_library_id, Paging::new(offset, limit)))
        })
    }

    /// Playlists in the user's Playlists library whose track list features the
    /// given artist, capped at `limit`. Powers the "Playlists featuring this
    /// artist" rail on the Artist detail screen. Matching is track-level
    /// (guest features count), scanned client-side because Jellyfin ignores
    /// `ArtistIds` under a playlist parent — see
    /// [`JellyfinClient::playlists_containing_artist`] for the cost bounds.
    pub fn playlists_containing_artist(
        &self,
        playlist_library_id: String,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Playlist>, LyrebirdError> {
        self.with_client(|c| {
            self.runtime.block_on(c.playlists_containing_artist(
                &playlist_library_id,
                &artist_id,
                limit,
            ))
        })
    }

    /// Tracks on a playlist, in the server's playlist order. Pass `offset`
    /// and `limit` for paging; the underlying `/Items` request does NOT sort
    /// server-side so the playlist's stored order is preserved. The
    /// returned [`PaginatedTracks`] carries the server total so callers can
    /// drive a page-until-done loop.
    pub fn playlist_tracks(
        &self,
        playlist_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.playlist_tracks(&playlist_id, Paging::new(offset, limit)))
        })
    }

    /// Append items (tracks/albums/artists) to a playlist in a single
    /// round-trip. Mirrors Jellify's `addManyToPlaylist`; callers should
    /// invalidate their `playlist_tracks` cache after this returns.
    ///
    /// When `position` is `Some(n)`, the Jellyfin `StartIndex` query param is
    /// set so the server inserts the items starting at index `n` rather than
    /// appending to the end.
    pub fn add_to_playlist(
        &self,
        playlist_id: String,
        item_ids: Vec<String>,
        position: Option<u32>,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| {
            let id_refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
            self.runtime
                .block_on(c.add_to_playlist(&playlist_id, &id_refs, position))
        })
    }

    /// Full-search query. Returns hydrated records split into typed
    /// sections (artists / albums / tracks), plus `total_record_count` so
    /// the UI can offer "Show all N results" affordances when more are
    /// available past the current page.
    pub fn search(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<SearchResults, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.search(&query, Paging::new(offset, limit)))
        })
    }

    /// Fast typeahead search — backed by Jellyfin's `/Search/Hints`.
    ///
    /// Use this for debounced omnibox queries. It returns a single flat
    /// list of [`SearchHint`] entries carrying the server-supplied `Type`
    /// so the UI can split results into typed sections without extra
    /// round-trips. Prefer [`LyrebirdCore::search`] for "see all results".
    ///
    /// `offset` maps to Jellyfin's `startIndex`; `total_record_count` on
    /// the returned [`SearchHintResults`] is stable across pages.
    pub fn search_hints(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<SearchHintResults, LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.search_hints(&query, Paging::new(offset, limit)))
        })
    }

    /// Mark an item (track, album, artist, playlist) as a favorite for the
    /// current user. Returns the updated [`FavoriteState`] so the UI can
    /// refresh without refetching. Errors with
    /// [`LyrebirdError::NotAuthenticated`] if no session is active.
    pub fn set_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.set_favorite(&item_id)))
    }

    /// Remove the favorite flag from an item for the current user. Returns the
    /// updated [`FavoriteState`] so the UI can refresh without refetching.
    /// Errors with [`LyrebirdError::NotAuthenticated`] if no session is active.
    pub fn unset_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.unset_favorite(&item_id)))
    }

    /// Set or clear an item's favorite flag in a single call. `favorite=true`
    /// dispatches to [`Self::set_favorite`], `false` dispatches to
    /// [`Self::unset_favorite`]. Intended for remote-control surfaces (the
    /// macOS `MPFeedbackCommand.like` toggle, etc.) that only know the
    /// desired target state. See issue #35.
    pub fn toggle_favorite(
        &self,
        item_id: String,
        favorite: bool,
    ) -> std::result::Result<FavoriteState, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.toggle_favorite(&item_id, favorite)))
    }

    /// Mark an item (track / album / playlist) as played for the current
    /// user. Returns the full updated [`UserItemData`] so the UI can update
    /// `played` + `play_count` + `last_played_at` without refetching. Errors
    /// with [`LyrebirdError::NotAuthenticated`] if no session is active.
    /// See issue #133.
    pub fn mark_played(&self, item_id: String) -> std::result::Result<UserItemData, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.mark_played(&item_id)))
    }

    /// Clear the played flag from an item for the current user. Returns the
    /// updated [`UserItemData`] (with `play_count = 0` and `last_played_at =
    /// None`). Errors with [`LyrebirdError::NotAuthenticated`] if no session
    /// is active. See issue #133.
    pub fn mark_unplayed(
        &self,
        item_id: String,
    ) -> std::result::Result<UserItemData, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.mark_unplayed(&item_id)))
    }

    /// Set or clear an item's played flag in a single call. `played=true`
    /// dispatches to [`Self::mark_played`], `false` dispatches to
    /// [`Self::mark_unplayed`]. Mirrors the shape of [`Self::toggle_favorite`]
    /// for multi-select callers that compute the target state from the
    /// majority current state of the selection. See issue #133.
    pub fn set_played(
        &self,
        item_id: String,
        played: bool,
    ) -> std::result::Result<UserItemData, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.set_played(&item_id, played)))
    }

    /// Create a new playlist for the current user. Returns the new
    /// playlist id — callers refetch the full [`Playlist`] via
    /// [`LyrebirdCore::fetch_item`] if they need the populated record.
    /// `item_ids` may be empty to create an empty playlist. Errors with
    /// [`LyrebirdError::NotAuthenticated`] if no session is active.
    ///
    /// There is no positional-insert parameter: `POST /Playlists` has no
    /// server-side `StartIndex` semantics, so the seed `item_ids` are
    /// appended in order. Positional insert is deferred to a dedicated
    /// `Playlists/{id}/Items` primitive (#282).
    pub fn create_playlist(
        &self,
        name: String,
        item_ids: Vec<String>,
    ) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| {
            let id_refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
            self.runtime.block_on(c.create_playlist(&name, &id_refs))
        })
    }

    /// Fetch a single item by id with a caller-selected `fields` projection
    /// (e.g. `["Overview", "Genres", "Tags", "People"]`). Returns the raw
    /// JSON object serialized as a string — callers decode whichever
    /// fields they asked for.
    pub fn fetch_item(
        &self,
        item_id: String,
        fields: Vec<String>,
    ) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| {
            let field_refs: Vec<&str> = fields.iter().map(String::as_str).collect();
            let value = self.runtime.block_on(c.fetch_item(&item_id, &field_refs))?;
            serde_json::to_string(&value).map_err(LyrebirdError::from)
        })
    }

    pub fn image_url(
        &self,
        item_id: String,
        tag: Option<String>,
        max_width: u32,
    ) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| {
            Ok(c.image_url(&item_id, tag.as_deref(), max_width)?
                .to_string())
        })
    }

    /// Build an image URL for any [`ImageType`] (Primary, Backdrop, Thumb, Disc,
    /// Logo, Banner, Art, Box). `index` is required for keyed types like
    /// `Backdrop` (one URL per `BackdropImageTags` entry); pass `None` for the
    /// first/only image.
    pub fn image_url_of_type(
        &self,
        item_id: String,
        image_type: ImageType,
        index: Option<u32>,
        tag: Option<String>,
        max_width: Option<u32>,
        max_height: Option<u32>,
    ) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| {
            Ok(c.image_url_of_type(
                &item_id,
                image_type,
                index,
                tag.as_deref(),
                max_width,
                max_height,
            )?
            .to_string())
        })
    }

    // ---------- Playback ----------

    /// Returns the fully-authenticated stream URL for a track.
    ///
    /// `media_source_id` should be `MediaSourceInfo::id` from the
    /// `PlaybackInfo` response so Jellyfin streams the correct source when an
    /// item has multiple audio versions (fixes #593). `play_session_id` should
    /// be the `PlaySessionId` returned by `PlaybackInfo` and is embedded in the
    /// URL so the server can correlate the stream with its transcode job.
    ///
    /// `max_streaming_bitrate` caps the transcode bitrate (#260): `Some(kbps)`
    /// sets Jellyfin's `MaxStreamingBitrate` ceiling; `None` omits it to request
    /// the original (no transcode cap). Callers that don't expose a quality
    /// control should pass `Some(320_000)` to preserve the historical default.
    pub fn stream_url(
        &self,
        track_id: String,
        media_source_id: Option<String>,
        play_session_id: Option<String>,
        max_streaming_bitrate: Option<u32>,
    ) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| {
            Ok(c.stream_url_with_bitrate(
                &track_id,
                media_source_id.as_deref(),
                play_session_id.as_deref(),
                max_streaming_bitrate,
            )?
            .to_string())
        })
    }

    /// The `Authorization` header value to attach to streaming requests.
    /// Cloudflare-fronted Jellyfin servers reject query-key-only auth.
    pub fn auth_header(&self) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| Ok(c.auth_header_value()))
    }

    /// Set the queue to a list of tracks and mark `tracks[start_index]` as
    /// the current track. Returns the track that should start playing now.
    ///
    /// Errors with [`LyrebirdError::InvalidIndex`] when `start_index` is
    /// out-of-bounds for `tracks`, or `tracks` is empty.
    pub fn set_queue(
        &self,
        tracks: Vec<Track>,
        start_index: u32,
    ) -> std::result::Result<Option<Track>, LyrebirdError> {
        self.player.set_queue(tracks, start_index)?;
        Ok(self.player.current_in_queue())
    }

    /// Insert `tracks` immediately after the currently-playing entry.
    /// "Play Next" semantics, per #282. Returns the new queue length.
    ///
    /// When the queue is empty there is no playhead to insert after, so this
    /// starts a fresh queue (priming `current` to the first track) — "Play
    /// Next" on a cold queue plays rather than dropping the tracks. A
    /// zero-length `tracks` is a no-op.
    pub fn play_next(&self, tracks: Vec<Track>) -> u32 {
        self.player.insert_next(tracks)
    }

    /// Append `tracks` to the end of the queue. "Add to Queue" semantics,
    /// per #282. Returns the new queue length. No-op when `tracks` is empty.
    /// When the queue was empty, the playhead is primed to the first appended
    /// track so the queue is immediately playable.
    pub fn add_to_queue(&self, tracks: Vec<Track>) -> u32 {
        self.player.append_to_queue(tracks)
    }

    /// Remove every entry from the queue except the currently playing track
    /// (which stays as a single-item queue so skip_next correctly reports
    /// `None`). Exposed so the UI's "Clear Up Next" action doesn't require
    /// stopping playback to reset the queue.
    pub fn clear_queue(&self) {
        self.player.clear_queue();
    }

    /// Mark `track` as the now-playing entry. Called from `AudioEngine.load`
    /// on every track transition, on the main thread.
    ///
    /// This only updates in-memory player state. It deliberately does NOT
    /// write a local play-history row: the server is the authority on play
    /// counts (incremented via `/Sessions/Playing*`, see CLAUDE.md
    /// "Resolved"), so a local `play_history` table was write-only dead
    /// storage that also (a) ran a synchronous SQLite INSERT under the
    /// `Inner` mutex on the main-thread load path and (b) counted a "play"
    /// on every load — including quick-skips — inflating counts relative to
    /// the server's threshold-based PlayCount. The table and its accessors
    /// were removed in the audit pass.
    pub fn mark_track_started(&self, track: Track) {
        self.player.set_current(track);
    }

    /// Store the `PlaySessionId` returned by `PlaybackInfo` on the current
    /// player state. Must be called at playback start; the id is then
    /// available via `status().play_session_id` so platform layers can echo
    /// it on every `PlaybackProgressInfo` / `PlaybackStopInfo` report.
    /// See issue #569.
    pub fn set_play_session_id(&self, play_session_id: Option<String>) {
        self.player.set_play_session_id(play_session_id);
    }

    /// Report that playback has stopped for an item — backed by
    /// `POST /Sessions/Playing/Stopped`.
    ///
    /// Drives Jellyfin's server-side PlayCount increment for tracks and
    /// cleans up any active transcode job. Callers invoke this on track
    /// end, user-driven skip, and app quit.
    pub fn report_playback_stopped(
        &self,
        info: PlaybackStopInfo,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_stopped(info)))
    }

    /// Report that playback of an item has started — backed by
    /// `POST /Sessions/Playing`. Jellyfin surfaces this session as a
    /// "Now Playing on macOS" remote-control target in Jellyfin Web.
    /// Callers send this once per track load.
    pub fn report_playback_started(
        &self,
        info: PlaybackStartInfo,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_started(info)))
    }

    /// Register this session as a playback target with the server —
    /// backed by `POST /Sessions/Capabilities/Full`. Called once post-auth
    /// (and whenever the device profile changes). Without this, Jellyfin
    /// Web cannot offer "Play on macOS" for this session.
    pub fn post_capabilities(
        &self,
        caps: ClientCapabilities,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.post_capabilities(caps)))
    }

    /// Resolve the playable media source and transcoding strategy for an
    /// item. Backed by `POST /Items/{id}/PlaybackInfo`. Returns the
    /// `PlaySessionId` the caller should echo on subsequent
    /// `/Sessions/Playing*` reports.
    pub fn playback_info(
        &self,
        item_id: String,
        opts: PlaybackInfoOpts,
    ) -> std::result::Result<PlaybackInfoResponse, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.playback_info(&item_id, opts)))
    }

    // ---------- Library resolution ----------

    /// Every top-level library the current user can browse. Backed by
    /// `GET /UserViews`. Callers typically filter by `collection_type`
    /// (`"music"`, `"playlists"`) to find the library ids they need.
    pub fn user_views(&self) -> std::result::Result<Vec<Library>, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.user_views()))
    }

    /// Resolve (and cache) the user's music library id. Every music-scoped
    /// query below the top level (albums, artists, tracks, genres, years)
    /// is parented to this id, so callers typically resolve it once at
    /// sign-in and hand it to subsequent requests.
    pub fn music_library_id(&self) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.music_library_id()))
    }

    /// Resolve (and cache) the user's playlists library id. Used as the
    /// `ParentId` for `user_playlists`.
    pub fn playlist_library_id(&self) -> std::result::Result<String, LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.playlist_library_id()))
    }

    // ---------- Playlist mutation ----------

    /// Remove entries from a playlist. `entry_ids` are `PlaylistItemId`
    /// values — each playlist child carries its own `PlaylistItemId`,
    /// which is distinct from the underlying `ItemId` because a single
    /// item can appear in the same playlist multiple times.
    pub fn remove_from_playlist(
        &self,
        playlist_id: String,
        entry_ids: Vec<String>,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.remove_from_playlist(&playlist_id, &entry_ids))
        })
    }

    /// Rename a playlist on the server. Fetches the current item to prefill
    /// the required `POST /Items/{id}` body, then re-POSTs with only `Name`
    /// changed. UI callers should update their local playlist cache on success.
    /// Errors with [`LyrebirdError::NotAuthenticated`] when no session is active.
    pub fn rename_playlist(
        &self,
        playlist_id: String,
        new_name: String,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.rename_playlist(&playlist_id, &new_name))
        })
    }

    /// Delete a playlist from the server via `DELETE /Items/{id}`. UI callers
    /// should drop the item from their local cache on success.
    /// Errors with [`LyrebirdError::NotAuthenticated`] when no session is active.
    pub fn delete_playlist(&self, playlist_id: String) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.delete_playlist(&playlist_id)))
    }

    /// Move a playlist entry to a new position via
    /// `POST /Playlists/{playlistId}/Items/{playlistItemId}/Move/{newIndex}`.
    ///
    /// `playlist_item_id` is the per-entry `PlaylistItemId` on the `Track`
    /// (populated by `playlist_tracks`). `new_index` is zero-based.
    /// Callers should reload playlist tracks after this returns so the UI
    /// reflects the server order.
    /// Errors with [`LyrebirdError::NotAuthenticated`] when no session is active.
    pub fn reorder_playlist_track(
        &self,
        playlist_id: String,
        playlist_item_id: String,
        new_index: u32,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| {
            self.runtime.block_on(c.reorder_playlist_track(
                &playlist_id,
                &playlist_item_id,
                new_index,
            ))
        })
    }

    /// A default macOS [`DeviceProfile`] advertising direct-play for
    /// FLAC / ALAC / MP3 / AAC / Opus / OGG / WAV with an MP3 320
    /// transcode fallback. Intended as a one-liner for UIs that don't
    /// need custom codec policies.
    pub fn default_macos_device_profile(&self) -> DeviceProfile {
        DeviceProfile::default_macos_profile()
    }

    pub fn mark_state(&self, state: PlaybackState) {
        self.player.mark_state(state);
    }

    pub fn mark_position(&self, seconds: f64) {
        self.player.mark_position(seconds);
    }

    /// Report playback progress to the server. Called by the platform
    /// playback engine roughly every 10 seconds and on pause/resume/seek
    /// transitions so Jellyfin can drive "Now Playing" state and resume
    /// points.
    pub fn report_playback_progress(
        &self,
        info: PlaybackProgressInfo,
    ) -> std::result::Result<(), LyrebirdError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_progress(info)))
    }

    // ---------- Scrobbling (ListenBrainz) ----------

    /// Persist the user's ListenBrainz token. Pass `None` (or an empty/blank
    /// string) to disconnect scrobbling and clear the stored token.
    ///
    /// The token is a secret and is stored in the **OS keyring** (the same
    /// secure store as the Jellyfin access token) — never in plaintext in the
    /// settings table. It is never written to logs and is intentionally
    /// excluded from the diagnostic bundle. Like shuffle/repeat it is an
    /// account-independent preference, so signing out of a Jellyfin server
    /// leaves the scrobble connection intact for the next sign-in.
    ///
    /// Any legacy plaintext token under the old settings key is removed on
    /// write so an upgraded install doesn't leave the secret on disk.
    pub fn set_scrobble_token(
        &self,
        token: Option<String>,
    ) -> std::result::Result<(), LyrebirdError> {
        let db = self.inner.lock().db.clone();
        match token
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
        {
            Some(t) => CredentialStore::save_scrobble_token(&t)?,
            None => CredentialStore::delete_scrobble_token()?,
        }
        // Belt-and-suspenders: scrub any plaintext token a pre-keyring build
        // may have written to the settings table.
        let _ = db.delete_setting(SCROBBLE_TOKEN_KEY);
        Ok(())
    }

    /// Whether a ListenBrainz token is currently stored. Returns a boolean
    /// rather than the token itself so the UI can render connected / not-
    /// connected state without the secret ever crossing the FFI boundary.
    pub fn is_scrobble_configured(&self) -> bool {
        CredentialStore::load_scrobble_token()
            .ok()
            .flatten()
            .map(|t| !t.trim().is_empty())
            .unwrap_or(false)
    }

    /// Submit a ListenBrainz `playing_now` for the track that just started.
    /// No-op error (`InvalidInput`) when no token is configured, which the
    /// platform layer treats as "scrobbling disabled" and swallows. Other
    /// errors (network, 401) propagate so the UI can surface a token problem.
    pub fn scrobble_now_playing(&self, track: Track) -> std::result::Result<(), LyrebirdError> {
        let token = self.scrobble_token()?;
        let scrobbler = scrobble::Scrobbler::new(token)?;
        self.runtime.block_on(scrobbler.submit_playing_now(&track))
    }

    /// Submit a durable ListenBrainz `single` listen for a track that has
    /// passed the scrobble threshold. `listened_at` is the Unix timestamp
    /// (seconds) at which the track *started* — ListenBrainz keys the listen
    /// on it. No-op error (`InvalidInput`) when no token is configured.
    pub fn scrobble_submit_listen(
        &self,
        track: Track,
        listened_at: i64,
    ) -> std::result::Result<(), LyrebirdError> {
        let token = self.scrobble_token()?;
        let scrobbler = scrobble::Scrobbler::new(token)?;
        self.runtime
            .block_on(scrobbler.submit_listen(&track, listened_at))
    }

    /// Pure threshold predicate exposed for the platform trigger gate: returns
    /// `true` once a track at `position_secs` of its `runtime_secs` has played
    /// long enough to count as a listen (half the track, or four minutes).
    /// Side-effect free — safe to call on the main thread.
    pub fn scrobble_threshold_reached(&self, position_secs: f64, runtime_secs: f64) -> bool {
        scrobble::scrobble_threshold_reached(position_secs, runtime_secs)
    }

    /// Start (or restart) the background heartbeat scheduler.
    ///
    /// Every `interval_secs` seconds (capped at 10 s — Jellyfin's server-side
    /// playback-ended detection threshold) the scheduler builds a
    /// [`PlaybackProgressInfo`] from the current [`Player`] state and POSTs it
    /// to `/Sessions/Playing/Progress`. `play_session_id` is the value returned
    /// by `playback_info` and must be echoed on every progress report.
    ///
    /// Calling this while a previous heartbeat is running silently cancels the
    /// old task first. The returned handle is stored internally; call
    /// [`Self::stop_heartbeat`] or just let the next `start_heartbeat` / logout
    /// implicitly cancel it. See issue #594.
    ///
    /// # Note on `Arc<Self>`
    ///
    /// This method requires `Arc<Self>` so the spawned task can hold a
    /// reference back to `LyrebirdCore` for the lifetime of the interval.
    pub fn start_heartbeat(self: &Arc<Self>, interval_secs: u32, play_session_id: Option<String>) {
        // Clamp to Jellyfin's detection threshold so the server never sees a
        // gap that looks like a dead client.
        let secs = interval_secs.clamp(1, 10) as u64;
        let interval = std::time::Duration::from_secs(secs);

        let core = Arc::clone(self);

        let handle = self.runtime.spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            // Consume the first tick so the first heartbeat fires after
            // `interval`, not immediately on start.
            ticker.tick().await;

            loop {
                ticker.tick().await;

                let status = core.player.status();
                // Don't heartbeat when playback is over (or hasn't begun).
                // The `current_track` can still be `Some` after a track ends
                // — without this guard the loop would keep POSTing
                // `/Sessions/Playing/Progress` with `is_paused=false`,
                // freezing a ghost "Now Playing" at the final position on the
                // server (and every other Jellyfin client) indefinitely.
                if matches!(
                    status.state,
                    crate::player::PlaybackState::Ended
                        | crate::player::PlaybackState::Stopped
                        | crate::player::PlaybackState::Idle
                ) {
                    continue;
                }
                // Only send a heartbeat when there is an active track —
                // sending progress with an empty `item_id` would confuse
                // the server.
                let item_id = match status.current_track {
                    Some(ref t) => t.id.clone(),
                    None => continue,
                };

                let position_ticks = (status.position_seconds * 10_000_000.0) as i64;
                let is_paused = matches!(status.state, crate::player::PlaybackState::Paused);

                let info = PlaybackProgressInfo {
                    item_id,
                    failed: false,
                    is_paused,
                    is_muted: false,
                    position_ticks,
                    play_session_id: play_session_id.clone(),
                    ..Default::default()
                };

                // Grab a clone of the Arc'd client so we can call the async
                // method without holding `inner`'s Mutex across an await.
                let client_arc = core.try_client_arc();
                let Some(client) = client_arc else {
                    // Session was logged out while the heartbeat was running.
                    continue;
                };
                if let Err(ref e) = client.report_playback_progress(info).await {
                    tracing::warn!(error = %e, "heartbeat progress report failed");
                }
            }
        });

        *self.heartbeat.lock() = Some(HeartbeatHandle {
            abort: handle.abort_handle(),
        });
    }

    /// Cancel the background heartbeat task started by [`Self::start_heartbeat`].
    /// A no-op when no heartbeat is running. Called automatically on
    /// `stop` / `logout` / track skip so there are no leaked interval timers.
    /// See issue #594.
    pub fn stop_heartbeat(&self) {
        if let Some(handle) = self.heartbeat.lock().take() {
            handle.stop();
        }
    }

    pub fn skip_next(&self) -> Option<Track> {
        self.player.skip_next()
    }

    /// The track [`Self::skip_next`] would return next, without advancing the
    /// queue. Lets the platform audio engine pre-load the upcoming item for
    /// gapless playback while the current track is still playing. Honours the
    /// current [`RepeatMode`] so the pre-loaded track always matches what
    /// actually plays at end-of-track. See issue #931.
    pub fn peek_next(&self) -> Option<Track> {
        self.player.peek_next()
    }

    pub fn skip_previous(&self) -> Option<Track> {
        self.player.skip_previous()
    }

    pub fn set_volume(&self, volume: f32) {
        self.player.set_volume(volume);
    }

    /// Toggle queue-wide shuffle on or off. The flag lands on
    /// [`PlayerStatus`] so platform remote-control surfaces (Control Center
    /// `MPChangeShuffleModeCommand` on macOS, MPRIS `Shuffle` on Linux,
    /// SMTC `ShuffleEnabled` on Windows) stay in sync with the app. The
    /// core does not reorder the underlying queue — callers hand over
    /// already-shuffled tracks via [`Self::set_queue`] and use this to
    /// reflect the current mode. Persisted to the local database so the
    /// setting survives app restarts. See issue #34 / #583.
    pub fn set_shuffle(&self, on: bool) {
        self.player.set_shuffle(on);
        let status = self.player.status();
        let _ = self
            .inner
            .lock()
            .db
            .save_shuffle_repeat(on, status.repeat_mode);
    }

    /// Set the queue-wide [`RepeatMode`]. Consumed by the platform audio
    /// engine at end-of-track (replay vs. advance vs. stop) and exposed on
    /// the remote-control surface. Persisted to the local database so the
    /// setting survives app restarts. See issue #34 / #583.
    pub fn set_repeat_mode(&self, mode: RepeatMode) {
        self.player.set_repeat_mode(mode);
        let status = self.player.status();
        let _ = self
            .inner
            .lock()
            .db
            .save_shuffle_repeat(status.shuffle, mode);
    }

    pub fn stop(&self) {
        self.stop_heartbeat();
        self.player.clear();
    }

    pub fn status(&self) -> PlayerStatus {
        self.player.status()
    }

    // ======================================================================
    // Offline downloads (#819).
    //
    // All of these serialize through the same `Inner` mutex as every other
    // FFI, but the long-running one (`download_track`) clones the `Arc`s
    // under the lock and drops the guard before the network stream, exactly
    // like `with_client`. The cheap query methods (`download_state`,
    // `is_track_downloaded`, `download_local_path`, `list_downloads`,
    // `downloads_used_bytes`, `download_stats`) only touch SQLite, so they're
    // safe for the platform layer to call off the main thread and cache.
    // ======================================================================

    /// Enqueue and synchronously download a track's audio for offline
    /// playback. Records a `queued` row first (so a concurrent `download_state`
    /// query reflects the intent immediately), then streams the bytes to disk
    /// and flips the row to `done`.
    ///
    /// Enforces the configured storage budget: evicts least-recently-completed
    /// downloads to make room, or refuses with [`LyrebirdError::Storage`] when
    /// the track can't fit even an empty store. On any failure the row is
    /// marked `failed` with the reason and the error is returned.
    ///
    /// Blocking: this drives the full HTTP transfer on the tokio runtime, so
    /// the platform layer MUST call it off the main thread (e.g. inside a
    /// `Task.detached`).
    ///
    /// Concurrency: parallel transfers are capped (#819 — default 2) via a
    /// shared semaphore, and budget planning + the final size-checked commit
    /// are serialised by a shared lock, so concurrent `download_track` calls
    /// can't collectively overshoot the storage budget.
    pub fn download_track(
        &self,
        track: Track,
    ) -> std::result::Result<DownloadEntry, LyrebirdError> {
        let (client, db, data_dir) = {
            let inner = self.inner.lock();
            (
                inner
                    .client
                    .as_ref()
                    .ok_or(LyrebirdError::NoSession)?
                    .clone(),
                inner.db.clone(),
                inner.data_dir.clone(),
            )
        };
        let now = chrono::Utc::now().timestamp();
        // Record the queued intent up front, off the network path.
        downloads::enqueue(&db, &track, now)?;
        // The concurrency cap + budget lock are shared across all in-flight
        // downloads; clone the handles so `fetch` can hold a permit / take the
        // lock without keeping the `Inner` mutex (already dropped above).
        let permits = self.download_semaphore.clone();
        let budget_lock = self.download_budget_lock.clone();
        self.runtime.block_on(downloads::fetch(
            &db,
            &client,
            &data_dir,
            &track,
            now,
            &permits,
            &budget_lock,
        ))
    }

    /// Cancel / remove a download: deletes the on-disk file and the index row.
    /// Idempotent — removing a track that was never downloaded succeeds.
    ///
    /// Note: this does not abort an in-flight `download_track` mid-stream (that
    /// call owns the transfer synchronously); it removes a completed or queued
    /// entry. The platform layer surfaces it as "Remove Download".
    pub fn delete_download(&self, track_id: String) -> std::result::Result<(), LyrebirdError> {
        let db = self.inner.lock().db.clone();
        downloads::delete(&db, &track_id)
    }

    /// The download state of a single track, or `None` when it has no download
    /// record. Cheap (one indexed SQLite read) and side-effect free.
    pub fn download_state(
        &self,
        track_id: String,
    ) -> std::result::Result<Option<DownloadState>, LyrebirdError> {
        let db = self.inner.lock().db.clone();
        downloads::state_for(&db, &track_id)
    }

    /// `true` when the track is fully downloaded *and* its backing file still
    /// exists on disk. The existence check makes this the safe predicate for
    /// the offline-playback branch — a stale `done` row whose file was evicted
    /// reports `false`, so playback falls back to streaming.
    pub fn is_track_downloaded(&self, track_id: String) -> bool {
        let db = self.inner.lock().db.clone();
        downloads::local_path_for(&db, &track_id)
            .ok()
            .flatten()
            .is_some()
    }

    /// Absolute on-disk path of a track's completed download, or `None` when it
    /// isn't downloaded / not yet done / the file is gone. The platform audio
    /// engine turns this into a `file://` URL for offline playback.
    pub fn download_local_path(&self, track_id: String) -> Option<String> {
        let db = self.inner.lock().db.clone();
        downloads::local_path_for(&db, &track_id).ok().flatten()
    }

    /// Every download record (any state), newest-enqueued first. Drives the
    /// Downloads screen.
    pub fn list_downloads(&self) -> std::result::Result<Vec<DownloadEntry>, LyrebirdError> {
        let db = self.inner.lock().db.clone();
        downloads::list(&db)
    }

    /// Total bytes used by completed downloads.
    pub fn downloads_used_bytes(&self) -> std::result::Result<u64, LyrebirdError> {
        let db = self.inner.lock().db.clone();
        Ok(db.download_used_bytes()?.0)
    }

    /// Aggregate offline-storage stats (used bytes, configured budget, item
    /// count) for the Downloads preferences pane.
    pub fn download_stats(&self) -> std::result::Result<DownloadStats, LyrebirdError> {
        let db = self.inner.lock().db.clone();
        downloads::stats(&db)
    }

    /// Set the storage budget in bytes (`0` = unlimited). Persisted to the
    /// settings table; consulted on the next `download_track`.
    pub fn set_download_budget_bytes(&self, bytes: u64) -> std::result::Result<(), LyrebirdError> {
        let db = self.inner.lock().db.clone();
        db.set_setting(downloads::DOWNLOAD_BUDGET_KEY, &bytes.to_string())
    }

    /// Override the directory offline audio files are written to. Pass an empty
    /// string to clear the override and fall back to `<data_dir>/downloads`.
    /// Existing files are not migrated — this only affects subsequent
    /// downloads (the UI warns accordingly).
    pub fn set_download_dir(&self, dir: String) -> std::result::Result<(), LyrebirdError> {
        let db = self.inner.lock().db.clone();
        if dir.trim().is_empty() {
            db.delete_setting(downloads::DOWNLOAD_DIR_KEY)
        } else {
            db.set_setting(downloads::DOWNLOAD_DIR_KEY, &dir)
        }
    }

    /// The directory offline audio files are written to (the resolved path,
    /// honouring any override). Shown read-only in the Downloads pane.
    pub fn download_dir_path(&self) -> String {
        let (db, data_dir) = {
            let inner = self.inner.lock();
            (inner.db.clone(), inner.data_dir.clone())
        };
        downloads::download_dir(&db, &data_dir)
            .to_string_lossy()
            .to_string()
    }
}

impl LyrebirdCore {
    /// Read the stored ListenBrainz token from the OS keyring, mapping "absent
    /// or blank" to a clean [`LyrebirdError::InvalidInput`] so submit paths
    /// share one guard.
    ///
    /// Deliberately **not** part of the `#[uniffi::export]` block: the raw
    /// token must never cross the FFI boundary. Platform code learns *whether*
    /// a token is set via [`Self::is_scrobble_configured`], never its value.
    fn scrobble_token(&self) -> std::result::Result<String, LyrebirdError> {
        CredentialStore::load_scrobble_token()
            .ok()
            .flatten()
            .filter(|t| !t.trim().is_empty())
            .ok_or_else(|| LyrebirdError::InvalidInput("scrobble token not configured".into()))
    }

    /// Run `f` with a reference to the live HTTP client, releasing the
    /// `Inner` mutex before the closure executes.
    ///
    /// The `Arc` clone keeps the lock window to a handful of instructions
    /// (just long enough to bump the refcount). Crucially, the closure —
    /// which typically calls `self.runtime.block_on(c.some_http_call())`
    /// — runs *without* `Inner` held, so concurrent main-thread FFIs like
    /// `auth_header` or `image_url` don't beach-ball while an HTTP request
    /// is in flight on another thread.
    ///
    /// The closure must not touch `self.inner`; every existing caller
    /// satisfies that by only calling methods on the client or the
    /// runtime.
    fn with_client<T, F>(&self, f: F) -> std::result::Result<T, LyrebirdError>
    where
        F: FnOnce(&JellyfinClient) -> std::result::Result<T, LyrebirdError>,
    {
        let client = self
            .inner
            .lock()
            .client
            .as_ref()
            .ok_or(LyrebirdError::NoSession)?
            .clone();
        f(&client)
    }

    /// Clone the live client handle (if one exists) so background tasks can
    /// call async methods without holding `inner`'s lock across an await.
    fn try_client_arc(&self) -> Option<Arc<JellyfinClient>> {
        self.inner.lock().client.clone()
    }

    /// Wire the HTTP client's 401 interceptor so it can silently pull a
    /// fresh token out of the OS credential store without round-tripping
    /// through the UI.
    ///
    /// The callback only holds an `Arc` to [`Database`] — never to `Inner`
    /// — so it can fetch a refreshed token without touching the `Inner`
    /// mutex. Keeps the refresh path reentrant-safe regardless of which
    /// thread is currently executing an FFI entry point.
    fn install_refresh_callback(client: &JellyfinClient, db: &Arc<Database>) {
        let db = db.clone();
        client.set_refresh_callback(Arc::new(move || storage::refresh_token_from_keyring(&db)));
    }
}

#[cfg(test)]
mod tests;
