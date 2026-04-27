//! Jellify core — shared Rust library for the desktop apps.
//!
//! The public surface is the [`JellifyCore`] type, which owns the Jellyfin
//! HTTP client, the local database, and queue/player bookkeeping. Platform
//! UIs consume this either via UniFFI bindings (Swift/C#) or directly (GTK /
//! Rust).
//!
//! Audio output is NOT in the core — it lives on the platform side
//! (AVFoundation on macOS, MediaPlayer on Windows, GStreamer on Linux).
//! The core exposes authenticated stream URLs; the platform decides how to
//! play them and calls back with status updates.

pub mod client;
pub mod enums;
pub mod error;
pub mod models;
pub mod player;
pub mod query;
pub mod storage;

pub use enums::{ImageType, ItemField, ItemKind, ItemSortBy, SortOrder};
pub use error::{JellifyError, Result};
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

/// The main handle a UI holds.
#[derive(uniffi::Object)]
pub struct JellifyCore {
    inner: Arc<Mutex<Inner>>,
    player: Arc<Player>,
    runtime: tokio::runtime::Runtime,
    /// Running heartbeat task, if one was started via [`Self::start_heartbeat`].
    heartbeat: Mutex<Option<HeartbeatHandle>>,
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
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreConfig {
    pub data_dir: String,
    pub device_name: String,
}

#[uniffi::export]
impl JellifyCore {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> std::result::Result<Arc<Self>, JellifyError> {
        let data_dir = if config.data_dir.is_empty() {
            storage::default_data_dir()
        } else {
            PathBuf::from(&config.data_dir)
        };
        let db_path = data_dir.join("jellify.db");
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
            .map_err(|e| JellifyError::Other(format!("tokio runtime: {e}")))?;

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
            })),
            player,
            runtime,
            heartbeat: Mutex::new(None),
        }))
    }

    pub fn device_id(&self) -> String {
        self.inner.lock().device_id.clone()
    }

    pub fn probe_server(&self, url: String) -> std::result::Result<Server, JellifyError> {
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
    ) -> std::result::Result<models::Session, JellifyError> {
        let username = username.trim().to_string();
        let password = password.trim().to_string();
        if username.is_empty() || password.is_empty() {
            return Err(JellifyError::InvalidCredentials);
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
                .map_err(|e| JellifyError::KeyringWrite {
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
    pub fn resume_session(&self) -> std::result::Result<Option<Session>, JellifyError> {
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
                        return Err(JellifyError::InvalidCredentials);
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

    pub fn logout(&self) -> std::result::Result<(), JellifyError> {
        // 1. Invalidate the server session while the token is still valid.
        //    Log but do not abort on any error — an unreachable server must
        //    not prevent local cleanup (#592).
        {
            let inner = self.inner.lock();
            if let Some(ref client) = inner.client {
                if let Err(e) = self.runtime.block_on(client.post_logout_session()) {
                    tracing::warn!("POST /Sessions/Logout failed (continuing): {e}");
                }
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
    pub fn forget_token(&self) -> std::result::Result<(), JellifyError> {
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
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.albums(Paging::new(offset, limit))))
    }

    /// Artists in the user's library, paginated. See [`Self::list_albums`].
    pub fn list_artists(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedArtists, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.artists(Paging::new(offset, limit))))
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
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.albums_by_artist(&artist_id, Paging::new(offset, limit)))
        })
    }

    pub fn album_tracks(&self, album_id: String) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.album_tracks(&album_id)))
    }

    /// Fetch an artist's most-played tracks (by server-tracked `PlayCount`
    /// descending, `SortName` ascending as tiebreaker). Powers the artist
    /// detail "Top Tracks" section — see #229.
    pub fn artist_top_tracks(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.artist_top_tracks(&artist_id, limit))
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
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.instant_mix(&item_id, limit)))
    }

    /// Server-curated suggestions for the Home "You might like" row. More
    /// useful than recency-ordered recent-adds for long-tail discovery.
    pub fn suggestions(&self, limit: u32) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.suggestions(limit)))
    }

    /// Artists similar to `artist_id` — Jellyfin's tag/genre-based
    /// similarity. Powers the artist detail "Fans also like" shelf.
    pub fn similar_artists(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Artist>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_artists(&artist_id, limit)))
    }

    /// Albums similar to `album_id`. Powers the album detail "Similar
    /// albums" shelf.
    pub fn similar_albums(
        &self,
        album_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Album>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_albums(&album_id, limit)))
    }

    /// Generic similar-items fallback — returns typed [`ItemRef`]s so the
    /// UI can dispatch to the right detail screen without re-fetching.
    pub fn similar_items(
        &self,
        item_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<ItemRef>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_items(&item_id, limit)))
    }

    /// Most frequently played tracks for the current user, ordered by the
    /// server's `PlayCount` descending. Powers the Home "Play It Again" /
    /// "On Repeat" row.
    pub fn frequently_played_tracks(
        &self,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.frequently_played_tracks(limit)))
    }

    /// All music genres in the user's library, paginated. Each [`Genre`]
    /// carries `song_count` / `album_count` via `Fields=ItemCounts`, so the
    /// Genres tab can render counts without a second round-trip.
    pub fn genres(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedGenres, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.genres(Paging::new(offset, limit))))
    }

    /// Albums belonging to a genre, paginated. Powers the genre detail
    /// landing view.
    pub fn items_by_genre(
        &self,
        genre_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.items_by_genre(&genre_id, Paging::new(offset, limit)))
        })
    }

    /// Full artist record with biography, backdrop image tags, and
    /// external links (MusicBrainz / Last.fm / Discogs). Feeds the artist
    /// detail header.
    pub fn artist_detail(
        &self,
        artist_id: String,
    ) -> std::result::Result<ArtistDetail, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.artist_detail(&artist_id)))
    }

    /// Fetch lyrics for a track. Returns `None` when the server reports 404
    /// (no lyrics available — common). Handles both synced LRC and plain
    /// text; `LyricLine::time_seconds` is pre-converted out of Jellyfin's
    /// 100-ns tick units.
    pub fn lyrics(&self, track_id: String) -> std::result::Result<Option<Lyrics>, JellifyError> {
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
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
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
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
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
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
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
    ) -> std::result::Result<PaginatedPlaylists, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.user_playlists(&playlist_library_id, Paging::new(offset, limit)))
        })
    }

    /// Public / community playlists visible to the current user — anything
    /// under the Playlists library whose `Path` does NOT contain `/data/`.
    pub fn public_playlists(
        &self,
        playlist_library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedPlaylists, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.public_playlists(&playlist_library_id, Paging::new(offset, limit)))
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
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
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
    ) -> std::result::Result<(), JellifyError> {
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
    ) -> std::result::Result<SearchResults, JellifyError> {
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
    /// round-trips. Prefer [`JellifyCore::search`] for "see all results".
    ///
    /// `offset` maps to Jellyfin's `startIndex`; `total_record_count` on
    /// the returned [`SearchHintResults`] is stable across pages.
    pub fn search_hints(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<SearchHintResults, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.search_hints(&query, Paging::new(offset, limit)))
        })
    }

    /// Mark an item (track, album, artist, playlist) as a favorite for the
    /// current user. Returns the updated [`FavoriteState`] so the UI can
    /// refresh without refetching. Errors with
    /// [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn set_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.set_favorite(&item_id)))
    }

    /// Remove the favorite flag from an item for the current user. Returns the
    /// updated [`FavoriteState`] so the UI can refresh without refetching.
    /// Errors with [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn unset_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, JellifyError> {
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
    ) -> std::result::Result<FavoriteState, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.toggle_favorite(&item_id, favorite)))
    }

    /// Mark an item (track / album / playlist) as played for the current
    /// user. Returns the full updated [`UserItemData`] so the UI can update
    /// `played` + `play_count` + `last_played_at` without refetching. Errors
    /// with [`JellifyError::NotAuthenticated`] if no session is active.
    /// See issue #133.
    pub fn mark_played(
        &self,
        item_id: String,
    ) -> std::result::Result<UserItemData, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.mark_played(&item_id)))
    }

    /// Clear the played flag from an item for the current user. Returns the
    /// updated [`UserItemData`] (with `play_count = 0` and `last_played_at =
    /// None`). Errors with [`JellifyError::NotAuthenticated`] if no session
    /// is active. See issue #133.
    pub fn mark_unplayed(
        &self,
        item_id: String,
    ) -> std::result::Result<UserItemData, JellifyError> {
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
    ) -> std::result::Result<UserItemData, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.set_played(&item_id, played)))
    }

    /// Create a new playlist for the current user. Returns the new
    /// playlist id — callers refetch the full [`Playlist`] via
    /// [`JellifyCore::fetch_item`] if they need the populated record.
    /// `item_ids` may be empty to create an empty playlist. Errors with
    /// [`JellifyError::NotAuthenticated`] if no session is active.
    ///
    /// When `position` is `Some(n)`, the Jellyfin `StartIndex` query param is
    /// set so the server inserts the initial items starting at index `n`.
    pub fn create_playlist(
        &self,
        name: String,
        item_ids: Vec<String>,
        position: Option<u32>,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            let id_refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
            self.runtime
                .block_on(c.create_playlist(&name, &id_refs, position))
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
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            let field_refs: Vec<&str> = fields.iter().map(String::as_str).collect();
            let value = self.runtime.block_on(c.fetch_item(&item_id, &field_refs))?;
            serde_json::to_string(&value).map_err(JellifyError::from)
        })
    }

    pub fn image_url(
        &self,
        item_id: String,
        tag: Option<String>,
        max_width: u32,
    ) -> std::result::Result<String, JellifyError> {
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
    ) -> std::result::Result<String, JellifyError> {
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
    pub fn stream_url(
        &self,
        track_id: String,
        media_source_id: Option<String>,
        play_session_id: Option<String>,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            Ok(c.stream_url(
                &track_id,
                media_source_id.as_deref(),
                play_session_id.as_deref(),
            )?
            .to_string())
        })
    }

    /// The `Authorization` header value to attach to streaming requests.
    /// Cloudflare-fronted Jellyfin servers reject query-key-only auth.
    pub fn auth_header(&self) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| Ok(c.auth_header_value()))
    }

    /// Set the queue to a list of tracks and mark `tracks[start_index]` as
    /// the current track. Returns the track that should start playing now.
    ///
    /// Errors with [`JellifyError::InvalidIndex`] when `start_index` is
    /// out-of-bounds for `tracks`, or `tracks` is empty.
    pub fn set_queue(
        &self,
        tracks: Vec<Track>,
        start_index: u32,
    ) -> std::result::Result<Option<Track>, JellifyError> {
        self.player.set_queue(tracks, start_index)?;
        Ok(self.player.current_in_queue())
    }

    /// Insert `tracks` immediately after the currently-playing entry.
    /// "Play Next" semantics, per #282. Returns the new queue length.
    ///
    /// No-op when either the queue is empty or `tracks` is empty — callers
    /// that want to prime the queue with the new tracks should fall back to
    /// [`Self::set_queue`] when the queue length stays at zero.
    pub fn play_next(&self, tracks: Vec<Track>) -> u32 {
        self.player.insert_next(tracks)
    }

    /// Append `tracks` to the end of the queue. "Add to Queue" semantics,
    /// per #282. Returns the new queue length. No-op when `tracks` is empty.
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

    pub fn mark_track_started(&self, track: Track) {
        self.player.set_current(track.clone());
        let now = chrono::Utc::now().timestamp();
        let _ = self.inner.lock().db.record_play(&track.id, now);
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
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_stopped(info)))
    }

    /// Report that playback of an item has started — backed by
    /// `POST /Sessions/Playing`. Jellyfin surfaces this session as a
    /// "Now Playing on macOS" remote-control target in Jellyfin Web.
    /// Callers send this once per track load.
    pub fn report_playback_started(
        &self,
        info: PlaybackStartInfo,
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_started(info)))
    }

    /// Register this session as a playback target with the server —
    /// backed by `POST /Sessions/Capabilities/Full`. Called once post-auth
    /// (and whenever the device profile changes). Without this, Jellyfin
    /// Web cannot offer "Play on macOS" for this session.
    pub fn post_capabilities(
        &self,
        caps: ClientCapabilities,
    ) -> std::result::Result<(), JellifyError> {
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
    ) -> std::result::Result<PlaybackInfoResponse, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.playback_info(&item_id, opts)))
    }

    // ---------- Library resolution ----------

    /// Every top-level library the current user can browse. Backed by
    /// `GET /UserViews`. Callers typically filter by `collection_type`
    /// (`"music"`, `"playlists"`) to find the library ids they need.
    pub fn user_views(&self) -> std::result::Result<Vec<Library>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.user_views()))
    }

    /// Resolve (and cache) the user's music library id. Every music-scoped
    /// query below the top level (albums, artists, tracks, genres, years)
    /// is parented to this id, so callers typically resolve it once at
    /// sign-in and hand it to subsequent requests.
    pub fn music_library_id(&self) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.music_library_id()))
    }

    /// Resolve (and cache) the user's playlists library id. Used as the
    /// `ParentId` for `user_playlists` / `public_playlists`.
    pub fn playlist_library_id(&self) -> std::result::Result<String, JellifyError> {
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
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.remove_from_playlist(&playlist_id, &entry_ids))
        })
    }

    /// Rename a playlist on the server. Fetches the current item to prefill
    /// the required `POST /Items/{id}` body, then re-POSTs with only `Name`
    /// changed. UI callers should update their local playlist cache on success.
    /// Errors with [`JellifyError::NotAuthenticated`] when no session is active.
    pub fn rename_playlist(
        &self,
        playlist_id: String,
        new_name: String,
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.rename_playlist(&playlist_id, &new_name))
        })
    }

    /// Delete a playlist from the server via `DELETE /Items/{id}`. UI callers
    /// should drop the item from their local cache on success.
    /// Errors with [`JellifyError::NotAuthenticated`] when no session is active.
    pub fn delete_playlist(&self, playlist_id: String) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.delete_playlist(&playlist_id)))
    }

    /// Move a playlist entry to a new position via
    /// `POST /Playlists/{playlistId}/Items/{playlistItemId}/Move/{newIndex}`.
    ///
    /// `playlist_item_id` is the per-entry `PlaylistItemId` on the `Track`
    /// (populated by `playlist_tracks`). `new_index` is zero-based.
    /// Callers should reload playlist tracks after this returns so the UI
    /// reflects the server order.
    /// Errors with [`JellifyError::NotAuthenticated`] when no session is active.
    pub fn reorder_playlist_track(
        &self,
        playlist_id: String,
        playlist_item_id: String,
        new_index: u32,
    ) -> std::result::Result<(), JellifyError> {
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
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.report_playback_progress(info)))
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
    /// reference back to `JellifyCore` for the lifetime of the interval.
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
}

impl JellifyCore {
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
    fn with_client<T, F>(&self, f: F) -> std::result::Result<T, JellifyError>
    where
        F: FnOnce(&JellyfinClient) -> std::result::Result<T, JellifyError>,
    {
        let client = self
            .inner
            .lock()
            .client
            .as_ref()
            .ok_or(JellifyError::NoSession)?
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
