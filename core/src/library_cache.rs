//! Database-backed library cache with background revalidation (#431).
//!
//! The library used to be fetched fresh on every launch — on a slow link the
//! user stared at a spinner until the first page round-tripped. This module
//! implements the cache-first, revalidate-in-background strategy:
//!
//! 1. **Persist-on-fetch** — every page returned by the canonical library
//!    list FFIs (`list_albums` / `list_artists` / `list_tracks`) is written
//!    through to the `album_cache` / `artist_cache` / `track_cache` tables as
//!    JSON rows keyed by id (schema prepared in `001_initial.sql`; display
//!    `sort_key` added in `003_library_cache_sort.sql`).
//! 2. **Cache-first launch** — `LyrebirdCore::list_cached_albums` (and the
//!    artist/track twins) serve the first N rows in display order straight
//!    from SQLite, no network, so the UI can paint immediately.
//! 3. **Background revalidation** — `LyrebirdCore::revalidate_library` spawns
//!    `run_sync` on the core's tokio runtime. It fetches what changed since
//!    the last successful sync (Jellyfin's `MinDateLastSaved` delta filter),
//!    upserts into the cache, diffs by JSON equality, and pushes only the
//!    rows that actually changed through the [`LibrarySyncObserver`] callback
//!    interface. The `Inner` mutex is **never** held across any of this — the
//!    sync task owns its own `Arc<JellyfinClient>` / `Arc<Database>` handles.
//!
//! Per-entity sync strategy (each shaped by a live probe of Jellyfin 10.11):
//!
//! * **Albums** — delta via `MinDateLastSaved` when a checkpoint exists, full
//!   paged walk otherwise. After a delta pass the cached row count is compared
//!   against the server's `TotalRecordCount`; a mismatch means something was
//!   deleted server-side (deltas can only add/update, never remove), which
//!   triggers a full reconcile walk. A degenerate delta (≥ half the library
//!   re-saved, e.g. by a metadata refresh task) folds into the full walk too —
//!   same transfer class, and it reconciles removals for free.
//! * **Artists** — full paged walk, gated on album-phase activity. Verified
//!   live: the `/Artists/AlbumArtists` endpoint silently ignores
//!   `MinDateLastSaved` (a future-dated filter still returns the entire
//!   artist list), so there is no delta to be had, and its `ItemCounts`
//!   projection is expensive server-side (~10s/page cold on a 20k-album
//!   library). Every artist-affecting mutation re-saves album rows
//!   (renames rewrite `AlbumArtist`, deletes remove albums), so the walk
//!   only runs when the album phase saw changes — or when the artist cache
//!   is cold. The walk doubles as exact removal reconciliation. Known gap:
//!   artist `UserData` changes made on *other* clients (e.g. favoriting an
//!   artist elsewhere) don't bump album rows, so cached artist rows pick
//!   those up on the next active sync; favorites surfaces fetch live and
//!   are unaffected.
//! * **Tracks** — delta only, capped at `TRACK_DELTA_MAX_PAGES` pages per
//!   sync. The track cache fills progressively from persist-on-fetch (the
//!   All Tracks tab, album pages the user opens); a proactive 150k-track
//!   mirror walk is deliberately out of scope, as is track removal
//!   reconciliation — stale rows are replaced as soon as the regular fetch
//!   paths touch the same window. The first sync just records the
//!   checkpoint.
//!
//! Diffing is by **JSON equality of the serialized model**, not the
//! `Etag`/`DateLastSaved` projection: it is strictly stronger (it also
//! catches `UserData` changes the server makes without bumping
//! `DateLastSaved`) and needs no extra model fields. The flip side is that
//! both writers must fetch the same field projection — hence
//! `JellyfinClient::albums_query` / `tracks_query` being the shared,
//! canonical builders.
//!
//! Sync checkpoints are stored per user in `settings` under
//! `library_last_sync_albums_{user_id}` / `library_last_sync_tracks_{user_id}`
//! and are wiped together with the cache tables (`clear_library_cache`).
//! Checkpoints are captured *before* a phase fetches and rewound by
//! `CLOCK_SKEW_WINDOW_SECS` so client/server clock drift and mid-sync
//! writes re-fetch harmlessly (the JSON diff suppresses no-op emits) instead
//! of being missed forever.

use crate::client::JellyfinClient;
use crate::error::{LyrebirdError, Result};
use crate::models::{Album, Artist, PaginatedAlbums, PaginatedTracks, Paging, Track};
use crate::storage::{CacheKind, CacheWrite, Database};
use futures::StreamExt;
use std::collections::HashSet;
use std::sync::Arc;

/// Page size for revalidation walks. 500 keeps a 5k-album library at ten
/// round-trips while staying well under Jellyfin's response-size comfort
/// zone (a 500-album page with the canonical projection measures ~800 KB).
const SYNC_PAGE_SIZE: u32 = 500;

/// How many full-walk page fetches run concurrently. The walk is
/// latency-bound, not bandwidth-bound, so a small fan-out cuts wall time
/// roughly linearly without hammering the server.
const FULL_WALK_CONCURRENCY: usize = 3;

/// Upper bound on pages a single track delta pass will walk (40 × 500 =
/// 20k tracks). Bounds per-sync work when a server-side metadata refresh
/// re-saves an enormous track set; the checkpoint still advances, and the
/// un-walked tail self-heals through persist-on-fetch.
const TRACK_DELTA_MAX_PAGES: u32 = 40;

/// Rewind applied to sync checkpoints to tolerate client/server clock skew.
/// Re-fetching a five-minute overlap is cheap (and diff-suppressed); missing
/// a change because the server clock runs behind ours is not.
const CLOCK_SKEW_WINDOW_SECS: i64 = 300;

/// A delta pass that would re-fetch at least `1/DEGENERATE_DELTA_DIVISOR` of
/// the library folds into a full walk instead — same transfer class, plus
/// free removal reconciliation.
const DEGENERATE_DELTA_DIVISOR: u64 = 2;

/// Observer over a running library revalidation. Implemented by the UI layer
/// (a Swift class via the UniFFI callback interface) and driven from the
/// sync task's runtime thread — implementations must marshal to their own
/// main thread.
///
/// `*_changed` callbacks carry only rows whose cached JSON actually changed
/// (new or updated), batched per fetched page; `removed_ids` arrives in a
/// trailing batch once a reconcile walk has computed the removed set. Tracks
/// have no removal reconciliation (see module docs). Exactly one of
/// [`Self::sync_completed`] / [`Self::sync_failed`] terminates every sync.
#[uniffi::export(callback_interface)]
pub trait LibrarySyncObserver: Send + Sync {
    fn albums_changed(&self, changed: Vec<Album>, removed_ids: Vec<String>);
    fn artists_changed(&self, changed: Vec<Artist>, removed_ids: Vec<String>);
    fn tracks_changed(&self, changed: Vec<Track>);
    fn sync_completed(&self, summary: LibrarySyncSummary);
    fn sync_failed(&self, message: String);
}

/// End-of-sync roll-up handed to [`LibrarySyncObserver::sync_completed`].
/// `*_total` fields are the server's authoritative `TotalRecordCount` per
/// entity (0 when that phase failed), so the UI can refresh its pagination
/// totals without an extra count query. `phase_errors` carries per-entity
/// failures when *some* phases succeeded — an all-phases failure surfaces
/// through [`LibrarySyncObserver::sync_failed`] instead.
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct LibrarySyncSummary {
    pub albums_changed: u32,
    pub albums_removed: u32,
    pub album_total: u32,
    pub artists_changed: u32,
    pub artists_removed: u32,
    pub artist_total: u32,
    pub tracks_changed: u32,
    pub track_total: u32,
    /// `true` when the album phase ran a full walk (first sync, removal
    /// reconcile, or degenerate delta) rather than a pure delta pass.
    pub did_full_album_sync: bool,
    /// `true` when the artist walk ran this sync. It is skipped — and
    /// `artist_total` left 0 — on quiet days: the walk has no delta filter
    /// and is expensive server-side, so it only runs when the album phase
    /// saw activity (or the artist cache is cold). See module docs.
    pub did_artist_walk: bool,
    /// `true` when the track delta hit `TRACK_DELTA_MAX_PAGES` and stopped
    /// early; the checkpoint advanced anyway (see module docs).
    pub track_delta_truncated: bool,
    pub phase_errors: Vec<String>,
}

/// Everything a sync task needs, cloned out of `Inner` *before* the task is
/// spawned so the FFI mutex is never held across network or DB I/O.
pub(crate) struct SyncContext {
    pub client: Arc<JellyfinClient>,
    pub db: Arc<Database>,
    /// The user the sync was started for. Compared against the live
    /// `last_user_id` setting before every cache write so a logout or
    /// account switch mid-sync aborts instead of repopulating the
    /// just-cleared tables with the previous user's rows.
    pub user_id: String,
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

/// Display-order key: casefolded, with a leading English article stripped —
/// an approximation of Jellyfin's `SortName` collation that is computable
/// locally. Cached emits ordered by this key line up closely (not always
/// perfectly) with the server's `SortName` ordering; the background
/// revalidation replaces visible rows with authoritative data anyway.
pub(crate) fn sort_key(name: &str) -> String {
    let lower = name.trim().to_lowercase();
    for article in ["the ", "an ", "a "] {
        if lower.len() > article.len() && lower.starts_with(article) {
            // Slicing at the article length is safe: `lower` starts with the
            // all-ASCII article, so the boundary is a char boundary.
            return lower[article.len()..].trim_start().to_string();
        }
    }
    lower
}

fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Checkpoint to persist after a successful phase: *now* minus the skew
/// window, formatted as the ISO-8601 UTC instant Jellyfin's
/// `MinDateLastSaved` expects. Captured before the phase fetches so changes
/// landing mid-sync are re-fetched next time rather than missed.
fn checkpoint_timestamp() -> String {
    (chrono::Utc::now() - chrono::Duration::seconds(CLOCK_SKEW_WINDOW_SECS))
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn album_writes(items: &[Album]) -> Vec<CacheWrite> {
    items
        .iter()
        .filter_map(|a| {
            serde_json::to_string(a).ok().map(|data| CacheWrite {
                id: a.id.clone(),
                data,
                sort_key: sort_key(&a.name),
            })
        })
        .collect()
}

fn artist_writes(items: &[Artist]) -> Vec<CacheWrite> {
    items
        .iter()
        .filter_map(|a| {
            serde_json::to_string(a).ok().map(|data| CacheWrite {
                id: a.id.clone(),
                data,
                sort_key: sort_key(&a.name),
            })
        })
        .collect()
}

fn track_writes(items: &[Track]) -> Vec<CacheWrite> {
    items
        .iter()
        .filter_map(|t| {
            serde_json::to_string(t).ok().map(|data| CacheWrite {
                id: t.id.clone(),
                data,
                sort_key: sort_key(&t.name),
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Persist-on-fetch + cached reads (the synchronous, network-free surface)
// ---------------------------------------------------------------------------

/// Write a fetched album page through to the cache. Returns the ids whose
/// cached JSON changed. Callers on the fetch path treat errors as
/// best-effort (log and continue) — the cache is an optimization, never a
/// reason to fail the fetch that produced the data.
pub(crate) fn persist_albums(db: &Database, items: &[Album]) -> Result<Vec<String>> {
    db.cache_upsert(CacheKind::Album, &album_writes(items), now_unix())
}

/// Artist twin of [`persist_albums`].
pub(crate) fn persist_artists(db: &Database, items: &[Artist]) -> Result<Vec<String>> {
    db.cache_upsert(CacheKind::Artist, &artist_writes(items), now_unix())
}

/// Track twin of [`persist_albums`].
pub(crate) fn persist_tracks(db: &Database, items: &[Track]) -> Result<Vec<String>> {
    db.cache_upsert(CacheKind::Track, &track_writes(items), now_unix())
}

/// First `limit` cached albums in display order. Rows that no longer
/// deserialize (stale shapes written by an older build) are skipped — they
/// get overwritten by the next fetch or sync that touches them.
pub(crate) fn list_cached_albums(db: &Database, limit: u32) -> Result<Vec<Album>> {
    Ok(db
        .cache_list(CacheKind::Album, limit)?
        .iter()
        .filter_map(|json| match serde_json::from_str(json) {
            Ok(album) => Some(album),
            Err(e) => {
                tracing::debug!("skipping undeserializable album_cache row: {e}");
                None
            }
        })
        .collect())
}

/// Artist twin of [`list_cached_albums`].
pub(crate) fn list_cached_artists(db: &Database, limit: u32) -> Result<Vec<Artist>> {
    Ok(db
        .cache_list(CacheKind::Artist, limit)?
        .iter()
        .filter_map(|json| match serde_json::from_str(json) {
            Ok(artist) => Some(artist),
            Err(e) => {
                tracing::debug!("skipping undeserializable artist_cache row: {e}");
                None
            }
        })
        .collect())
}

/// Track twin of [`list_cached_albums`].
pub(crate) fn list_cached_tracks(db: &Database, limit: u32) -> Result<Vec<Track>> {
    Ok(db
        .cache_list(CacheKind::Track, limit)?
        .iter()
        .filter_map(|json| match serde_json::from_str(json) {
            Ok(track) => Some(track),
            Err(e) => {
                tracing::debug!("skipping undeserializable track_cache row: {e}");
                None
            }
        })
        .collect())
}

// ---------------------------------------------------------------------------
// Background revalidation
// ---------------------------------------------------------------------------

/// Abort guard: the user the sync started for must still be the signed-in
/// user. See [`SyncContext::user_id`].
fn ensure_user_unchanged(ctx: &SyncContext) -> Result<()> {
    match ctx.db.get_setting("last_user_id")? {
        Some(current) if current == ctx.user_id => Ok(()),
        _ => Err(LyrebirdError::Other(
            "session changed during library sync; aborting".into(),
        )),
    }
}

/// Run one full revalidation pass. Phases run sequentially (albums →
/// artists → tracks) with independent error handling, so one flaky endpoint
/// doesn't sink the others; per-entity checkpoints only advance when their
/// phase succeeds. Terminates with exactly one `sync_completed` /
/// `sync_failed` callback.
pub(crate) async fn run_sync(ctx: &SyncContext, observer: &dyn LibrarySyncObserver) {
    let mut summary = LibrarySyncSummary::default();
    let mut errors: Vec<String> = Vec::new();
    let mut albums_active = true;

    match sync_albums(ctx, observer).await {
        Ok(stats) => {
            albums_active = stats.changed > 0 || stats.removed > 0 || stats.did_full;
            summary.albums_changed = stats.changed;
            summary.albums_removed = stats.removed;
            summary.album_total = stats.total;
            summary.did_full_album_sync = stats.did_full;
        }
        Err(e) => errors.push(format!("albums: {e}")),
    }

    // A user switch fails every later phase at its first write anyway —
    // short-circuit instead of burning their fetches.
    if ensure_user_unchanged(ctx).is_err() {
        observer.sync_failed("session changed during library sync; aborting".into());
        return;
    }

    // The artist walk re-fetches the whole artist list (no delta available —
    // see module docs) and Jellyfin computes `ItemCounts` per artist on it,
    // which measured ~10s/page cold on a 20k-album live library. Gate it on
    // album-phase activity: every artist-affecting mutation Jellyfin
    // supports (add/remove/rename — renames rewrite the albums'
    // `AlbumArtist`) re-saves album rows, so a quiet album delta implies a
    // quiet artist list. A cold artist cache walks unconditionally.
    let artist_cache_empty = ctx
        .db
        .cache_count(CacheKind::Artist)
        .map(|n| n == 0)
        .unwrap_or(true);
    if albums_active || artist_cache_empty {
        match sync_artists(ctx, observer).await {
            Ok(stats) => {
                summary.did_artist_walk = true;
                summary.artists_changed = stats.changed;
                summary.artists_removed = stats.removed;
                summary.artist_total = stats.total;
            }
            Err(e) => errors.push(format!("artists: {e}")),
        }
    }

    if ensure_user_unchanged(ctx).is_err() {
        observer.sync_failed("session changed during library sync; aborting".into());
        return;
    }

    match sync_tracks(ctx, observer).await {
        Ok(stats) => {
            summary.tracks_changed = stats.changed;
            summary.track_total = stats.total;
            summary.track_delta_truncated = stats.truncated;
        }
        Err(e) => errors.push(format!("tracks: {e}")),
    }

    if errors.len() == 3 {
        tracing::warn!("library sync failed on all phases: {}", errors.join("; "));
        observer.sync_failed(errors.join("; "));
        return;
    }
    if !errors.is_empty() {
        tracing::warn!("library sync partial failure: {}", errors.join("; "));
    }
    summary.phase_errors = errors;
    observer.sync_completed(summary);
}

#[derive(Default)]
struct PhaseStats {
    changed: u32,
    removed: u32,
    total: u32,
    did_full: bool,
}

#[derive(Default)]
struct TrackPhaseStats {
    changed: u32,
    total: u32,
    truncated: bool,
}

async fn fetch_albums_page(
    client: &JellyfinClient,
    offset: u32,
    limit: u32,
    since: Option<&str>,
) -> Result<PaginatedAlbums> {
    let mut q = JellyfinClient::albums_query(Paging::new(offset, limit));
    if let Some(ts) = since {
        q = q.min_date_last_saved(ts);
    }
    q.fetch_albums(client).await
}

async fn fetch_tracks_page(
    client: &JellyfinClient,
    offset: u32,
    limit: u32,
    since: Option<&str>,
) -> Result<PaginatedTracks> {
    let mut q = JellyfinClient::tracks_query(None, Paging::new(offset, limit));
    if let Some(ts) = since {
        q = q.min_date_last_saved(ts);
    }
    q.fetch_tracks(client).await
}

/// Persist one fetched album page, emit the changed subset, and record the
/// ids seen (for the reconcile walk's removed-set computation).
fn process_album_page(
    ctx: &SyncContext,
    observer: &dyn LibrarySyncObserver,
    items: &[Album],
    stats: &mut PhaseStats,
    seen: &mut HashSet<String>,
) -> Result<()> {
    ensure_user_unchanged(ctx)?;
    seen.extend(items.iter().map(|a| a.id.clone()));
    let changed_ids = persist_albums(&ctx.db, items)?;
    if !changed_ids.is_empty() {
        let changed_set: HashSet<&str> = changed_ids.iter().map(String::as_str).collect();
        let changed: Vec<Album> = items
            .iter()
            .filter(|a| changed_set.contains(a.id.as_str()))
            .cloned()
            .collect();
        stats.changed += changed.len() as u32;
        observer.albums_changed(changed, Vec::new());
    }
    Ok(())
}

/// Full album walk: page through the entire library (first page sequential
/// to learn the total, remaining pages with a small concurrent fan-out),
/// persist + emit changes, then delete-and-emit every previously cached id
/// the walk did not see.
///
/// Pagination-shift caveat: items added or removed mid-walk can shift the
/// offset windows, so the walk can rarely miss a row (caught by the next
/// delta) or drop a live cache row (repopulated by persist-on-fetch the next
/// time any fetch touches it). Both are self-healing; neither corrupts.
async fn full_album_walk(
    ctx: &SyncContext,
    observer: &dyn LibrarySyncObserver,
    stats: &mut PhaseStats,
) -> Result<()> {
    let prior_ids: HashSet<String> = ctx.db.cache_ids(CacheKind::Album)?.into_iter().collect();
    let mut seen: HashSet<String> = HashSet::new();

    let first = fetch_albums_page(&ctx.client, 0, SYNC_PAGE_SIZE, None).await?;
    let total = first.total_count;
    process_album_page(ctx, observer, &first.items, stats, &mut seen)?;

    let pages = total.div_ceil(SYNC_PAGE_SIZE);
    let mut page_stream =
        futures::stream::iter(
            (1..pages).map(|page| {
                let client = Arc::clone(&ctx.client);
                async move {
                    fetch_albums_page(&client, page * SYNC_PAGE_SIZE, SYNC_PAGE_SIZE, None).await
                }
            }),
        )
        .buffer_unordered(FULL_WALK_CONCURRENCY);
    while let Some(page) = page_stream.next().await {
        process_album_page(ctx, observer, &page?.items, stats, &mut seen)?;
    }
    drop(page_stream);

    let removed: Vec<String> = prior_ids.difference(&seen).cloned().collect();
    if !removed.is_empty() {
        ensure_user_unchanged(ctx)?;
        ctx.db.cache_delete_ids(CacheKind::Album, &removed)?;
        stats.removed = removed.len() as u32;
        observer.albums_changed(Vec::new(), removed);
    }
    stats.total = total;
    stats.did_full = true;
    Ok(())
}

async fn sync_albums(ctx: &SyncContext, observer: &dyn LibrarySyncObserver) -> Result<PhaseStats> {
    let key = format!("library_last_sync_albums_{}", ctx.user_id);
    let checkpoint = checkpoint_timestamp();
    let mut stats = PhaseStats::default();

    match ctx.db.get_setting(&key)? {
        None => full_album_walk(ctx, observer, &mut stats).await?,
        Some(since) => {
            // The probe page doubles as the first delta page: its
            // `total_count` is the size of the changed set.
            let first = fetch_albums_page(&ctx.client, 0, SYNC_PAGE_SIZE, Some(&since)).await?;
            let delta_total = first.total_count;
            let server_total = fetch_albums_page(&ctx.client, 0, 1, None)
                .await?
                .total_count;

            // delta_total >= server_total / DIVISOR, in overflow-safe form.
            let degenerate =
                u64::from(delta_total) * DEGENERATE_DELTA_DIVISOR >= u64::from(server_total.max(1));
            if degenerate && delta_total > 0 {
                full_album_walk(ctx, observer, &mut stats).await?;
            } else {
                let mut seen = HashSet::new();
                let mut offset = first.items.len() as u32;
                process_album_page(ctx, observer, &first.items, &mut stats, &mut seen)?;
                while offset < delta_total {
                    let page = fetch_albums_page(&ctx.client, offset, SYNC_PAGE_SIZE, Some(&since))
                        .await?;
                    if page.items.is_empty() {
                        break;
                    }
                    offset += page.items.len() as u32;
                    process_album_page(ctx, observer, &page.items, &mut stats, &mut seen)?;
                }
                stats.total = server_total;
                // Deltas only ever add or update rows; a count mismatch
                // therefore means server-side deletions → reconcile.
                if ctx.db.cache_count(CacheKind::Album)? != server_total {
                    full_album_walk(ctx, observer, &mut stats).await?;
                }
            }
        }
    }

    ensure_user_unchanged(ctx)?;
    ctx.db.set_setting(&key, &checkpoint)?;
    Ok(stats)
}

/// Artists: full walk — `/Artists/AlbumArtists` ignores `MinDateLastSaved`
/// (verified live against Jellyfin 10.11), so a delta is not available.
/// Gated by `run_sync` on album-phase activity (see module docs) because the
/// endpoint's `ItemCounts` projection is expensive server-side. The walk
/// gives exact removal reconciliation as a side effect.
async fn sync_artists(ctx: &SyncContext, observer: &dyn LibrarySyncObserver) -> Result<PhaseStats> {
    let mut stats = PhaseStats::default();
    let prior_ids: HashSet<String> = ctx.db.cache_ids(CacheKind::Artist)?.into_iter().collect();
    let mut seen: HashSet<String> = HashSet::new();
    let mut offset = 0u32;
    let mut total;
    loop {
        let page = ctx
            .client
            .artists(Paging::new(offset, SYNC_PAGE_SIZE))
            .await?;
        total = page.total_count;
        if page.items.is_empty() {
            break;
        }
        ensure_user_unchanged(ctx)?;
        seen.extend(page.items.iter().map(|a| a.id.clone()));
        let changed_ids = persist_artists(&ctx.db, &page.items)?;
        if !changed_ids.is_empty() {
            let changed_set: HashSet<&str> = changed_ids.iter().map(String::as_str).collect();
            let changed: Vec<Artist> = page
                .items
                .iter()
                .filter(|a| changed_set.contains(a.id.as_str()))
                .cloned()
                .collect();
            stats.changed += changed.len() as u32;
            observer.artists_changed(changed, Vec::new());
        }
        offset += page.items.len() as u32;
        if offset >= total {
            break;
        }
    }

    let removed: Vec<String> = prior_ids.difference(&seen).cloned().collect();
    if !removed.is_empty() {
        ensure_user_unchanged(ctx)?;
        ctx.db.cache_delete_ids(CacheKind::Artist, &removed)?;
        stats.removed = removed.len() as u32;
        observer.artists_changed(Vec::new(), removed);
    }
    stats.total = total;
    Ok(stats)
}

/// Tracks: capped delta pass (see module docs). The first sync records the
/// checkpoint without walking — the track cache fills via persist-on-fetch.
async fn sync_tracks(
    ctx: &SyncContext,
    observer: &dyn LibrarySyncObserver,
) -> Result<TrackPhaseStats> {
    let key = format!("library_last_sync_tracks_{}", ctx.user_id);
    let checkpoint = checkpoint_timestamp();
    let total = fetch_tracks_page(&ctx.client, 0, 1, None)
        .await?
        .total_count;
    let mut stats = TrackPhaseStats {
        total,
        ..Default::default()
    };

    if let Some(since) = ctx.db.get_setting(&key)? {
        let mut offset = 0u32;
        let mut pages = 0u32;
        loop {
            let page = fetch_tracks_page(&ctx.client, offset, SYNC_PAGE_SIZE, Some(&since)).await?;
            if page.items.is_empty() {
                break;
            }
            ensure_user_unchanged(ctx)?;
            let changed_ids = persist_tracks(&ctx.db, &page.items)?;
            if !changed_ids.is_empty() {
                let changed_set: HashSet<&str> = changed_ids.iter().map(String::as_str).collect();
                let changed: Vec<Track> = page
                    .items
                    .iter()
                    .filter(|t| changed_set.contains(t.id.as_str()))
                    .cloned()
                    .collect();
                stats.changed += changed.len() as u32;
                observer.tracks_changed(changed);
            }
            offset += page.items.len() as u32;
            pages += 1;
            if offset >= page.total_count {
                break;
            }
            if pages >= TRACK_DELTA_MAX_PAGES {
                tracing::warn!(
                    "track delta truncated at {TRACK_DELTA_MAX_PAGES} pages \
                     ({offset} of {} changed tracks); remainder heals via persist-on-fetch",
                    page.total_count
                );
                stats.truncated = true;
                break;
            }
        }
    }

    ensure_user_unchanged(ctx)?;
    ctx.db.set_setting(&key, &checkpoint)?;
    Ok(stats)
}
