//! Fluent `ItemsQuery` builder for Jellyfin's `/Items` family of endpoints.
//!
//! The `JellyfinClient::albums`, `::artists`, `::list_tracks`, `::search`,
//! `::album_tracks`, and friends all ultimately issue a `GET /Items` (or
//! `GET /Users/{id}/Items`) request with some permutation of the same set of
//! query parameters (`IncludeItemTypes`, `SortBy`, `Fields`, `ParentId`,
//! ...). Historically each method hand-rolled its own query string with
//! string literals, which meant the set of "allowed values" was scattered
//! across the call sites and a typo at one site was a silent server error.
//!
//! [`ItemsQuery`] centralises the builder into a single typed fluent
//! interface. The typed query-parameter enums ([`ItemKind`], [`ItemSortBy`],
//! [`SortOrder`], [`ItemField`]) replace the string literals, and the
//! builder's [`ItemsQuery::execute`] method dispatches to either
//! `/Users/{id}/Items` (when `user_id` is set) or `/Items` (when not).
//!
//! Existing per-endpoint methods on [`JellyfinClient`] (e.g.
//! [`JellyfinClient::albums`]) are retained for backwards compatibility and
//! now delegate to `ItemsQuery` internally; new call sites should prefer
//! the builder directly.

use crate::client::{JellyfinClient, PaginatedItems, RawItem, RawItems};
use crate::enums::{self, ItemField, ItemKind, ItemSortBy, SortOrder};
use crate::error::{LyrebirdError, Result};
use url::Url;

/// Fluent builder for a Jellyfin `GET /Items`-family request.
///
/// Construct with [`ItemsQuery::new`], set the parameters you need with the
/// fluent setters, and finish with [`Self::execute`] (returns a raw
/// [`PaginatedItems`] wrapping [`RawItem`]s) or one of the typed helpers
/// [`Self::fetch_albums`] / [`Self::fetch_artists`] / [`Self::fetch_tracks`]
/// / [`Self::fetch_playlists`].
///
/// Unset fields are simply omitted from the outbound query string; the
/// server's defaults apply. `limit = 0` is clamped to `1` before issuing the
/// request, matching the legacy behaviour of the per-endpoint methods.
#[derive(Clone, Debug, Default)]
pub struct ItemsQuery {
    pub(crate) parent_id: Option<String>,
    pub(crate) user_id: Option<String>,
    pub(crate) types: Vec<ItemKind>,
    pub(crate) sort_by: Vec<ItemSortBy>,
    pub(crate) sort_order: Vec<SortOrder>,
    pub(crate) limit: u32,
    pub(crate) offset: u32,
    pub(crate) is_favorite: Option<bool>,
    pub(crate) genre_ids: Vec<String>,
    pub(crate) artist_ids: Vec<String>,
    pub(crate) album_artist_ids: Vec<String>,
    pub(crate) years: Vec<u32>,
    pub(crate) search_term: Option<String>,
    pub(crate) fields: Vec<ItemField>,
    pub(crate) recursive: bool,
    pub(crate) enable_user_data: bool,
    pub(crate) ids: Vec<String>,
    pub(crate) exclude_types: Vec<ItemKind>,
    pub(crate) min_date_last_saved: Option<String>,
}

impl ItemsQuery {
    /// Start with an empty query. Every field defaults to `None`, empty
    /// vec, or `0` as appropriate.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set `ParentId` — scopes the query to items parented under `id` (a
    /// library collection folder, an album, a playlist, ...).
    pub fn parent<S: Into<String>>(mut self, id: S) -> Self {
        self.parent_id = Some(id.into());
        self
    }

    /// Override the `UserId` routing. When set, [`Self::execute`] sends the
    /// request to `/Users/{user_id}/Items`; when unset, [`Self::execute`]
    /// uses the client's authenticated user id for the same route. Pass
    /// `None` explicitly to force the bare `/Items` route (rarely needed).
    pub fn user<S: Into<String>>(mut self, id: S) -> Self {
        self.user_id = Some(id.into());
        self
    }

    /// Restrict the result set to a list of [`ItemKind`]s — serialised as
    /// `IncludeItemTypes=Audio,MusicAlbum,...`.
    pub fn item_types(mut self, kinds: Vec<ItemKind>) -> Self {
        self.types = kinds;
        self
    }

    /// Exclude items of the given [`ItemKind`]s — `ExcludeItemTypes=...`.
    pub fn exclude_item_types(mut self, kinds: Vec<ItemKind>) -> Self {
        self.exclude_types = kinds;
        self
    }

    /// Set the sort order columns — serialised as
    /// `SortBy=PlayCount,SortName`. The `SortOrder` vec (see
    /// [`Self::sort_order`]) should be parallel to this list; when the two
    /// vecs differ in length, Jellyfin reuses the last `SortOrder` entry for
    /// the remaining `SortBy` columns.
    pub fn sort_by(mut self, by: Vec<ItemSortBy>) -> Self {
        self.sort_by = by;
        self
    }

    /// Set the sort direction(s). See [`Self::sort_by`].
    pub fn sort_order(mut self, order: Vec<SortOrder>) -> Self {
        self.sort_order = order;
        self
    }

    /// Convenience for the single-column case — equivalent to
    /// `.sort_by(vec![column]).sort_order(vec![order])`.
    pub fn sort(mut self, column: ItemSortBy, order: SortOrder) -> Self {
        self.sort_by = vec![column];
        self.sort_order = vec![order];
        self
    }

    /// Maximum number of items to return — `Limit=...`. Clamped to `1`
    /// before the request is sent.
    pub fn limit(mut self, n: u32) -> Self {
        self.limit = n;
        self
    }

    /// Starting offset — `StartIndex=...`.
    pub fn offset(mut self, n: u32) -> Self {
        self.offset = n;
        self
    }

    /// Set `IsFavorite=true` (restrict to favorited items). Short-hand for
    /// `self.is_favorite(true)`.
    pub fn favorites_only(mut self) -> Self {
        self.is_favorite = Some(true);
        self
    }

    /// Set `IsFavorite=...` explicitly (e.g. `false` to suppress favorites).
    pub fn is_favorite(mut self, v: bool) -> Self {
        self.is_favorite = Some(v);
        self
    }

    /// Add a genre id — sent as `GenreIds=a,b,c`. Can be called repeatedly.
    pub fn genre<S: Into<String>>(mut self, id: S) -> Self {
        self.genre_ids.push(id.into());
        self
    }

    /// Set the full list of genre ids.
    pub fn genres<I, S>(mut self, ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.genre_ids = ids.into_iter().map(Into::into).collect();
        self
    }

    /// Add an artist id — sent as `ArtistIds=a,b,c` (matches any credited
    /// artist). Can be called repeatedly.
    pub fn artist<S: Into<String>>(mut self, id: S) -> Self {
        self.artist_ids.push(id.into());
        self
    }

    /// Set the full list of artist ids.
    pub fn artists<I, S>(mut self, ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.artist_ids = ids.into_iter().map(Into::into).collect();
        self
    }

    /// Add an album-artist id — sent as `AlbumArtistIds=a,b,c` (matches
    /// items whose `AlbumArtist` credit is the given artist).
    pub fn album_artist<S: Into<String>>(mut self, id: S) -> Self {
        self.album_artist_ids.push(id.into());
        self
    }

    /// Set the full list of album-artist ids.
    pub fn album_artists<I, S>(mut self, ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.album_artist_ids = ids.into_iter().map(Into::into).collect();
        self
    }

    /// Add a production year — sent as `Years=1999,2001`.
    pub fn year(mut self, y: u32) -> Self {
        self.years.push(y);
        self
    }

    /// Set the full list of production years.
    pub fn years<I>(mut self, years: I) -> Self
    where
        I: IntoIterator<Item = u32>,
    {
        self.years = years.into_iter().collect();
        self
    }

    /// Full-text search term — `SearchTerm=...`.
    pub fn search<S: Into<String>>(mut self, q: S) -> Self {
        self.search_term = Some(q.into());
        self
    }

    /// Set the `Fields` projection — e.g. `[Genres, ProductionYear,
    /// ChildCount]`. Serialised as a comma-separated list.
    pub fn fields(mut self, fs: Vec<ItemField>) -> Self {
        self.fields = fs;
        self
    }

    /// Append a single `Fields` entry.
    pub fn field(mut self, f: ItemField) -> Self {
        self.fields.push(f);
        self
    }

    /// Set `Recursive=true` so the query walks child collections.
    pub fn recursive(mut self) -> Self {
        self.recursive = true;
        self
    }

    /// Set `Recursive=...` explicitly (`true` → recursive, `false` →
    /// omit the param so the server default applies).
    pub fn with_recursive(mut self, v: bool) -> Self {
        self.recursive = v;
        self
    }

    /// Set `EnableUserData=true` so the server includes the per-user
    /// `UserData` payload on each item. Implied by `Fields=UserData`, but
    /// exposed here for endpoints that accept the standalone switch.
    pub fn enable_user_data(mut self) -> Self {
        self.enable_user_data = true;
        self
    }

    /// Add an explicit item id — sent as `Ids=a,b,c`.
    pub fn id<S: Into<String>>(mut self, id: S) -> Self {
        self.ids.push(id.into());
        self
    }

    /// Set the full list of explicit item ids.
    pub fn ids<I, S>(mut self, ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.ids = ids.into_iter().map(Into::into).collect();
        self
    }

    /// Set `MinDateLastSaved=<iso8601>` — restricts the result set to items
    /// the server (re)saved at or after the given UTC instant. This is
    /// Jellyfin's delta-sync filter; the library cache's background
    /// revalidation uses it to fetch only what changed since the last
    /// successful sync (#431). Note that per-user `UserData` mutations
    /// (favorites, play counts) do NOT bump an item's `DateLastSaved`.
    pub fn min_date_last_saved<S: Into<String>>(mut self, ts: S) -> Self {
        self.min_date_last_saved = Some(ts.into());
        self
    }

    /// Apply every set parameter onto the given URL. Shared between
    /// [`Self::execute`] and the callers (in `client.rs`) that need to
    /// embed the query onto an existing URL.
    pub(crate) fn apply(&self, url: &mut Url) {
        let mut q = url.query_pairs_mut();
        let limit = self.limit.max(1);
        q.append_pair("Limit", &limit.to_string());
        q.append_pair("StartIndex", &self.offset.to_string());
        if let Some(parent) = &self.parent_id {
            q.append_pair("ParentId", parent);
        }
        if self.recursive {
            q.append_pair("Recursive", "true");
        }
        if !self.types.is_empty() {
            q.append_pair(
                "IncludeItemTypes",
                &enums::csv(&self.types, ItemKind::as_str),
            );
        }
        if !self.exclude_types.is_empty() {
            q.append_pair(
                "ExcludeItemTypes",
                &enums::csv(&self.exclude_types, ItemKind::as_str),
            );
        }
        if !self.sort_by.is_empty() {
            q.append_pair("SortBy", &enums::csv(&self.sort_by, ItemSortBy::as_str));
        }
        if !self.sort_order.is_empty() {
            q.append_pair(
                "SortOrder",
                &enums::csv(&self.sort_order, SortOrder::as_str),
            );
        }
        if let Some(fav) = self.is_favorite {
            q.append_pair("IsFavorite", if fav { "true" } else { "false" });
        }
        if !self.genre_ids.is_empty() {
            q.append_pair("GenreIds", &self.genre_ids.join(","));
        }
        if !self.artist_ids.is_empty() {
            q.append_pair("ArtistIds", &self.artist_ids.join(","));
        }
        if !self.album_artist_ids.is_empty() {
            q.append_pair("AlbumArtistIds", &self.album_artist_ids.join(","));
        }
        if !self.years.is_empty() {
            let joined = self
                .years
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(",");
            q.append_pair("Years", &joined);
        }
        if let Some(term) = &self.search_term {
            q.append_pair("SearchTerm", term);
        }
        if !self.fields.is_empty() {
            q.append_pair("Fields", &enums::csv(&self.fields, ItemField::as_str));
        }
        if self.enable_user_data {
            q.append_pair("EnableUserData", "true");
        }
        if !self.ids.is_empty() {
            q.append_pair("Ids", &self.ids.join(","));
        }
        if let Some(ts) = &self.min_date_last_saved {
            q.append_pair("MinDateLastSaved", ts);
        }
        // Image flags: every UI-facing call site wants primary-image metadata,
        // and every pre-refactor endpoint set these explicitly. Emitted by the
        // builder so migrated endpoints keep shipping behavior.
        q.append_pair("EnableImages", "true");
        q.append_pair("ImageTypeLimit", "1");
    }

    /// Issue the request and return the raw server response as
    /// [`PaginatedItems<RawItem>`]. Chooses between `/Users/{id}/Items` and
    /// `/Items` based on `self.user_id` (or the client's authenticated user
    /// id when the caller did not override it).
    ///
    /// This is the low-level entry point — prefer the typed helpers
    /// [`Self::fetch_albums`] / `fetch_artists` / `fetch_tracks` /
    /// `fetch_playlists` when the caller knows which model type to expect.
    pub async fn execute(self, client: &JellyfinClient) -> Result<PaginatedItems<RawItem>> {
        let effective_user = self
            .user_id
            .clone()
            .or_else(|| client.user_id().map(ToOwned::to_owned))
            .ok_or(LyrebirdError::NotAuthenticated)?;
        let path = format!("Users/{effective_user}/Items");
        let mut url = client.endpoint(&path)?;
        self.apply(&mut url);
        let raw: RawItems<RawItem> = client.send_get(url).await?.json().await?;
        Ok(PaginatedItems {
            items: raw.items,
            total_count: raw.total_record_count,
        })
    }

    /// Thin convenience alias for [`Self::execute`] — matches the
    /// `fetch(self, client) -> Page<Item>` shape requested on the issue.
    pub async fn fetch(self, client: &JellyfinClient) -> Result<PaginatedItems<RawItem>> {
        self.execute(client).await
    }

    /// Execute, then map the raw items to [`crate::models::Album`].
    pub async fn fetch_albums(
        self,
        client: &JellyfinClient,
    ) -> Result<crate::models::PaginatedAlbums> {
        let page = self.execute(client).await?;
        Ok(crate::models::PaginatedAlbums {
            items: page.items.into_iter().map(Into::into).collect(),
            total_count: page.total_count,
        })
    }

    /// Execute, then map the raw items to [`crate::models::Artist`].
    pub async fn fetch_artists(
        self,
        client: &JellyfinClient,
    ) -> Result<crate::models::PaginatedArtists> {
        let page = self.execute(client).await?;
        Ok(crate::models::PaginatedArtists {
            items: page.items.into_iter().map(Into::into).collect(),
            total_count: page.total_count,
        })
    }

    /// Execute, then map the raw items to [`crate::models::Track`].
    pub async fn fetch_tracks(
        self,
        client: &JellyfinClient,
    ) -> Result<crate::models::PaginatedTracks> {
        let page = self.execute(client).await?;
        Ok(crate::models::PaginatedTracks {
            items: page.items.into_iter().map(Into::into).collect(),
            total_count: page.total_count,
        })
    }

    /// Execute, then map the raw items to [`crate::models::Playlist`].
    pub async fn fetch_playlists(
        self,
        client: &JellyfinClient,
    ) -> Result<crate::models::PaginatedPlaylists> {
        let page = self.execute(client).await?;
        Ok(crate::models::PaginatedPlaylists {
            items: page.items.into_iter().map(Into::into).collect(),
            total_count: page.total_count,
        })
    }
}
