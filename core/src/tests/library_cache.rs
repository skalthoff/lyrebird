use super::*;

use crate::library_cache::{self, sort_key};
use crate::models::{Album, Artist, Track};
use crate::storage::{CacheKind, CacheWrite};
use crate::{LibrarySyncObserver, LibrarySyncSummary};
use std::sync::Arc;
use wiremock::matchers::query_param_is_missing;

// ---------------------------------------------------------------------------
// Database-backed library cache + background revalidation (#431)
// ---------------------------------------------------------------------------

fn make_album(id: &str, name: &str) -> Album {
    Album {
        id: id.into(),
        name: name.into(),
        artist_name: "Artist".into(),
        artist_id: None,
        year: Some(2020),
        track_count: 10,
        runtime_ticks: 0,
        genres: vec![],
        image_tag: None,
        user_data: None,
    }
}

/// RawItem JSON that maps (via `From<RawItem> for Album`) to exactly
/// `make_album(id, name)` — keeps mock pages and seeded cache rows
/// byte-identical after serde, which is what the JSON-equality diff keys on.
fn album_item_json(id: &str, name: &str) -> serde_json::Value {
    json!({
        "Id": id, "Name": name, "Type": "MusicAlbum",
        "AlbumArtist": "Artist", "ProductionYear": 2020,
        "ChildCount": 10, "RunTimeTicks": 0u64, "Genres": []
    })
}

fn artist_item_json(id: &str, name: &str) -> serde_json::Value {
    json!({
        "Id": id, "Name": name, "Type": "MusicArtist",
        "AlbumCount": 2, "SongCount": 5, "Genres": []
    })
}

fn track_item_json(id: &str, name: &str) -> serde_json::Value {
    json!({
        "Id": id, "Name": name, "Type": "Audio",
        "AlbumArtist": "Artist", "RunTimeTicks": 0u64
    })
}

async fn mount_auth(server: &MockServer, server_id: &str, user_id: &str) {
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": server_id, "ServerName": "S",
            "User": { "Id": user_id, "Name": "cache-user", "ServerId": server_id,
                      "PrimaryImageTag": null }
        })))
        .mount(server)
        .await;
}

/// Build a temp-backed core and log it in against the mock server.
/// `LyrebirdCore::login` is a sync FFI that `block_on`s the core's own
/// runtime, so it runs under `spawn_blocking` (same pattern as the
/// session_auth tests).
async fn logged_in_core(tmp_path: String, server_url: String) -> Arc<LyrebirdCore> {
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_url, "cache-user".into(), "pw".into())
            .expect("login");
        core
    })
    .await
    .expect("join login task")
}

/// Test observer: records every callback and signals termination over a
/// channel so tests can await the end of the background sync.
#[derive(Default)]
struct SyncEvents {
    albums_changed: Vec<Album>,
    albums_removed: Vec<String>,
    artists_changed: Vec<Artist>,
    artists_removed: Vec<String>,
    tracks_changed: Vec<Track>,
}

struct SharedSyncRecorder {
    events: std::sync::Mutex<SyncEvents>,
    done: tokio::sync::mpsc::UnboundedSender<std::result::Result<LibrarySyncSummary, String>>,
}

struct RecordingObserver(Arc<SharedSyncRecorder>);

impl LibrarySyncObserver for RecordingObserver {
    fn albums_changed(&self, changed: Vec<Album>, removed_ids: Vec<String>) {
        let mut ev = self.0.events.lock().unwrap();
        ev.albums_changed.extend(changed);
        ev.albums_removed.extend(removed_ids);
    }
    fn artists_changed(&self, changed: Vec<Artist>, removed_ids: Vec<String>) {
        let mut ev = self.0.events.lock().unwrap();
        ev.artists_changed.extend(changed);
        ev.artists_removed.extend(removed_ids);
    }
    fn tracks_changed(&self, changed: Vec<Track>) {
        self.0.events.lock().unwrap().tracks_changed.extend(changed);
    }
    fn sync_completed(&self, summary: LibrarySyncSummary) {
        let _ = self.0.done.send(Ok(summary));
    }
    fn sync_failed(&self, message: String) {
        let _ = self.0.done.send(Err(message));
    }
}

fn recorder() -> (
    Arc<SharedSyncRecorder>,
    tokio::sync::mpsc::UnboundedReceiver<std::result::Result<LibrarySyncSummary, String>>,
) {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    (
        Arc::new(SharedSyncRecorder {
            events: std::sync::Mutex::new(SyncEvents::default()),
            done: tx,
        }),
        rx,
    )
}

/// Dispose of a test core off the async thread. `LyrebirdCore` owns a tokio
/// runtime, and dropping a runtime inside another runtime's async context
/// panics ("Cannot drop a runtime in a context where blocking is not
/// allowed") — the same reason `logged_in_core` constructs it under
/// `spawn_blocking`.
async fn drop_core(core: Arc<LyrebirdCore>) {
    tokio::task::spawn_blocking(move || drop(core))
        .await
        .expect("join drop task");
}

/// Kick a revalidation and await its terminating callback.
async fn run_revalidation(
    core: &Arc<LyrebirdCore>,
    shared: &Arc<SharedSyncRecorder>,
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<std::result::Result<LibrarySyncSummary, String>>,
) -> std::result::Result<LibrarySyncSummary, String> {
    assert!(
        core.revalidate_library(Box::new(RecordingObserver(Arc::clone(shared)))),
        "revalidate_library must start when a session exists and no sync is in flight"
    );
    tokio::time::timeout(std::time::Duration::from_secs(30), rx.recv())
        .await
        .expect("sync did not terminate within 30s")
        .expect("done channel closed without a terminal callback")
}

// --- sort_key -------------------------------------------------------------

#[test]
fn sort_key_strips_articles_and_casefolds() {
    assert_eq!(sort_key("The Beatles"), "beatles");
    assert_eq!(sort_key("A Moon Shaped Pool"), "moon shaped pool");
    assert_eq!(sort_key("An Awesome Wave"), "awesome wave");
    assert_eq!(sort_key("  Aphex Twin "), "aphex twin");
    // Words that merely *start* with an article string keep their prefix.
    assert_eq!(sort_key("Therapy?"), "therapy?");
    assert_eq!(sort_key("Answer"), "answer");
    // A bare article (nothing after it) is left as-is rather than emptied.
    assert_eq!(sort_key("The"), "the");
    // Multi-byte input doesn't panic and casefolds.
    assert_eq!(sort_key("Ólafur Arnalds"), "ólafur arnalds");
}

// --- storage CRUD ----------------------------------------------------------

#[test]
fn cache_upsert_diffs_by_json_equality() {
    let db = Database::in_memory().unwrap();
    let a1 = CacheWrite {
        id: "a1".into(),
        data: r#"{"name":"one"}"#.into(),
        sort_key: "one".into(),
    };
    let a2 = CacheWrite {
        id: "a2".into(),
        data: r#"{"name":"two"}"#.into(),
        sort_key: "two".into(),
    };

    // First write: both rows are new ⇒ both changed.
    let changed = db
        .cache_upsert(CacheKind::Album, &[a1.clone(), a2.clone()], 100)
        .unwrap();
    assert_eq!(changed, vec!["a1".to_string(), "a2".to_string()]);
    assert_eq!(db.cache_count(CacheKind::Album).unwrap(), 2);

    // Identical re-write: nothing changed, updated_at untouched.
    let changed = db
        .cache_upsert(CacheKind::Album, &[a1.clone(), a2.clone()], 200)
        .unwrap();
    assert!(changed.is_empty());

    // One row mutated ⇒ exactly that id reported.
    let a2_v2 = CacheWrite {
        id: "a2".into(),
        data: r#"{"name":"two (remastered)"}"#.into(),
        sort_key: "two (remastered)".into(),
    };
    let changed = db
        .cache_upsert(CacheKind::Album, &[a1, a2_v2], 300)
        .unwrap();
    assert_eq!(changed, vec!["a2".to_string()]);

    // ids + delete round-trip.
    let mut ids = db.cache_ids(CacheKind::Album).unwrap();
    ids.sort();
    assert_eq!(ids, vec!["a1".to_string(), "a2".to_string()]);
    db.cache_delete_ids(CacheKind::Album, &["a1".to_string()])
        .unwrap();
    assert_eq!(
        db.cache_ids(CacheKind::Album).unwrap(),
        vec!["a2".to_string()]
    );

    // The three tables are independent.
    assert_eq!(db.cache_count(CacheKind::Artist).unwrap(), 0);
    assert_eq!(db.cache_count(CacheKind::Track).unwrap(), 0);
}

#[test]
fn cache_list_orders_by_sort_key_and_limits() {
    let db = Database::in_memory().unwrap();
    let albums = [
        make_album("z", "The Zebra"), // sort_key "zebra"
        make_album("m", "Mango"),
        make_album("a", "Apple"),
    ];
    library_cache::persist_albums(&db, &albums).unwrap();

    let listed = library_cache::list_cached_albums(&db, 10).unwrap();
    assert_eq!(
        listed.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
        vec!["Apple", "Mango", "The Zebra"],
        "cached emit must be in display (article-stripped) order"
    );

    let limited = library_cache::list_cached_albums(&db, 2).unwrap();
    assert_eq!(limited.len(), 2);
    assert_eq!(limited[0].name, "Apple");
    assert_eq!(limited[1].name, "Mango");
}

#[test]
fn list_cached_skips_undeserializable_rows() {
    let db = Database::in_memory().unwrap();
    library_cache::persist_albums(&db, &[make_album("good", "Good Album")]).unwrap();
    // Simulate a stale-shape row written by an older build.
    db.cache_upsert(
        CacheKind::Album,
        &[CacheWrite {
            id: "stale".into(),
            data: r#"{"not_an_album": true}"#.into(),
            sort_key: "aaa".into(), // sorts first, so a panic/skip bug would surface
        }],
        1,
    )
    .unwrap();

    let listed = library_cache::list_cached_albums(&db, 10).unwrap();
    assert_eq!(listed.len(), 1, "stale row must be skipped, not fatal");
    assert_eq!(listed[0].id, "good");
}

#[test]
fn clear_user_data_wipes_cache_and_sync_checkpoints() {
    let db = Database::in_memory().unwrap();
    library_cache::persist_albums(&db, &[make_album("a1", "One")]).unwrap();
    db.set_setting("library_last_sync_albums_u1", "2026-01-01T00:00:00Z")
        .unwrap();
    db.set_setting("library_last_sync_tracks_u1", "2026-01-01T00:00:00Z")
        .unwrap();
    db.set_setting("library_cache_user_id", "u1").unwrap();

    db.clear_user_data().unwrap();

    assert_eq!(db.cache_count(CacheKind::Album).unwrap(), 0);
    assert!(db
        .get_setting("library_last_sync_albums_u1")
        .unwrap()
        .is_none());
    assert!(db
        .get_setting("library_last_sync_tracks_u1")
        .unwrap()
        .is_none());
    assert!(db.get_setting("library_cache_user_id").unwrap().is_none());
}

// --- persist-on-fetch + cached reads ----------------------------------------

#[tokio::test]
async fn persist_on_fetch_populates_cache_for_cached_reads() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    mount_auth(&server, "srv-lc-pof", "u-lc-pof").await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-pof/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "The Zebra"), album_item_json("a2", "Apple")],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let core = logged_in_core(tmp.path().to_string_lossy().into_owned(), server.uri()).await;

    // Cached read before any fetch: empty (no network fallback).
    assert!(core.list_cached_albums(100).unwrap().is_empty());

    // The regular paged fetch writes through to the cache.
    let core_for_fetch = Arc::clone(&core);
    let page = tokio::task::spawn_blocking(move || core_for_fetch.list_albums(0, 100))
        .await
        .expect("join")
        .expect("list_albums");
    assert_eq!(page.items.len(), 2);

    // Cached read now serves both rows, in display order, without any
    // further network round-trip.
    let cached = core.list_cached_albums(100).unwrap();
    assert_eq!(
        cached.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(),
        vec!["a2", "a1"],
        "Apple sorts before The Zebra (article stripped)"
    );
    let album_requests = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Users/u-lc-pof/Items")
        .count();
    assert_eq!(album_requests, 1, "cached reads must not hit the server");
    drop_core(core).await;
}

#[tokio::test]
async fn login_as_different_user_wipes_library_cache() {
    let tmp = tempfile::tempdir().unwrap();
    let server_a = MockServer::start().await;
    mount_auth(&server_a, "srv-lc-switch-a", "u-lc-switch-a").await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-switch-a/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Owned By A")],
            "TotalRecordCount": 1
        })))
        .mount(&server_a)
        .await;
    let server_b = MockServer::start().await;
    mount_auth(&server_b, "srv-lc-switch-b", "u-lc-switch-b").await;

    let core = logged_in_core(tmp.path().to_string_lossy().into_owned(), server_a.uri()).await;
    let core_for_fetch = Arc::clone(&core);
    tokio::task::spawn_blocking(move || core_for_fetch.list_albums(0, 100))
        .await
        .expect("join")
        .expect("list_albums");
    assert_eq!(core.list_cached_albums(100).unwrap().len(), 1);

    // Re-login as the SAME user: the warm cache must survive.
    let core_for_relogin = Arc::clone(&core);
    let url_a = server_a.uri();
    tokio::task::spawn_blocking(move || {
        core_for_relogin
            .login(url_a, "cache-user".into(), "pw".into())
            .expect("re-login as same user")
    })
    .await
    .expect("join");
    assert_eq!(
        core.list_cached_albums(100).unwrap().len(),
        1,
        "same-user re-login must keep the cache warm"
    );

    // Login as a DIFFERENT user: the cache must be wiped so user B never
    // sees user A's library.
    let core_for_switch = Arc::clone(&core);
    let url_b = server_b.uri();
    tokio::task::spawn_blocking(move || {
        core_for_switch
            .login(url_b, "cache-user".into(), "pw".into())
            .expect("login as user B")
    })
    .await
    .expect("join");
    assert!(
        core.list_cached_albums(100).unwrap().is_empty(),
        "user switch must wipe the library cache"
    );
    drop_core(core).await;
}

// --- background revalidation -------------------------------------------------

#[test]
fn revalidate_library_requires_session() {
    // Plain #[test] (not #[tokio::test]) so the core — which owns its own
    // tokio runtime — can be dropped on this thread without panicking.
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    let (shared, mut rx) = recorder();
    assert!(
        !core.revalidate_library(Box::new(RecordingObserver(Arc::clone(&shared)))),
        "no session ⇒ no sync"
    );
    assert!(
        rx.try_recv().is_err(),
        "observer must not be invoked when the sync never starts"
    );
}

#[tokio::test]
async fn revalidation_first_sync_full_walks_albums_and_artists() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    mount_auth(&server, "srv-lc-full", "u-lc-full").await;
    // Albums: the full walk must NOT carry MinDateLastSaved on first sync.
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-full/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Album One"), album_item_json("a2", "Album Two")],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [artist_item_json("r1", "Artist One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // Tracks: first sync only probes the total (no delta walk, no mirror walk).
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-full/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [track_item_json("t1", "Track One")],
            "TotalRecordCount": 42
        })))
        .mount(&server)
        .await;

    let core = logged_in_core(tmp.path().to_string_lossy().into_owned(), server.uri()).await;
    let (shared, mut rx) = recorder();
    let summary = run_revalidation(&core, &shared, &mut rx)
        .await
        .expect("sync_completed");

    assert!(summary.did_full_album_sync);
    assert_eq!(summary.albums_changed, 2);
    assert_eq!(summary.albums_removed, 0);
    assert_eq!(summary.album_total, 2);
    assert!(summary.did_artist_walk, "first sync must walk artists");
    assert_eq!(summary.artists_changed, 1);
    assert_eq!(summary.artist_total, 1);
    assert_eq!(
        summary.tracks_changed, 0,
        "first sync records a checkpoint, no track walk"
    );
    assert_eq!(summary.track_total, 42);
    assert!(!summary.track_delta_truncated);
    assert!(summary.phase_errors.is_empty());

    // Scoped (not `drop(ev)`): clippy's await_holding_lock tracks lexical
    // regions, so the guard must end in a block before the next await.
    {
        let ev = shared.events.lock().unwrap();
        assert_eq!(ev.albums_changed.len(), 2);
        assert!(ev.albums_removed.is_empty());
        assert_eq!(ev.artists_changed.len(), 1);
        assert!(ev.tracks_changed.is_empty());
    }

    // Cache is now populated and checkpoints recorded.
    assert_eq!(core.list_cached_albums(10).unwrap().len(), 2);
    assert_eq!(core.list_cached_artists(10).unwrap().len(), 1);
    assert!(core.list_cached_tracks(10).unwrap().is_empty());
    {
        let inner = core.inner.lock();
        assert!(inner
            .db
            .get_setting("library_last_sync_albums_u-lc-full")
            .unwrap()
            .is_some());
        assert!(inner
            .db
            .get_setting("library_last_sync_tracks_u-lc-full")
            .unwrap()
            .is_some());
    }
    drop_core(core).await;
}

#[tokio::test]
async fn revalidation_delta_emits_only_changes_and_reconciles_removals() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    mount_auth(&server, "srv-lc-delta", "u-lc-delta").await;
    // --- stage 1: first sync (full walk) seeds the cache with a1, a2, a3 ---
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                album_item_json("a1", "Album One"),
                album_item_json("a2", "Album Two"),
                album_item_json("a3", "Album Three")
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [artist_item_json("r1", "Artist One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 5
        })))
        .mount(&server)
        .await;

    let core = logged_in_core(tmp.path().to_string_lossy().into_owned(), server.uri()).await;
    let (shared1, mut rx1) = recorder();
    run_revalidation(&core, &shared1, &mut rx1)
        .await
        .expect("stage-1 sync_completed");
    assert_eq!(core.list_cached_albums(10).unwrap().len(), 3);

    // --- stage 2: a1 renamed server-side, a3 deleted server-side ---
    server.reset().await;
    // Delta query (MinDateLastSaved present): only the renamed a1 comes back.
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(|req: &Request| req.url.query_pairs().any(|(k, _)| k == "MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Album One (Remastered)")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // Unfiltered album queries: the Limit=1 total probe and the reconcile
    // walk (Limit=500). Total of 2 ≠ 3 cached rows triggers the reconcile.
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .and(query_param("Limit", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Album One (Remastered)")],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .and(query_param("Limit", "500"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                album_item_json("a1", "Album One (Remastered)"),
                album_item_json("a2", "Album Two")
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;
    // Artists: unchanged page — must produce zero artist emissions.
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [artist_item_json("r1", "Artist One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // Tracks: probe total, then a delta page carrying one new track.
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 5
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-delta/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(|req: &Request| req.url.query_pairs().any(|(k, _)| k == "MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [track_item_json("t-new", "Fresh Track")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let (shared2, mut rx2) = recorder();
    let summary = run_revalidation(&core, &shared2, &mut rx2)
        .await
        .expect("stage-2 sync_completed");

    assert_eq!(
        summary.albums_changed, 1,
        "only the renamed album counts as changed (the reconcile walk must \
         not re-emit rows the delta already updated, nor unchanged rows)"
    );
    assert_eq!(summary.albums_removed, 1);
    assert_eq!(summary.album_total, 2);
    assert!(
        summary.did_full_album_sync,
        "count mismatch (3 cached vs 2 on server) must trigger the reconcile walk"
    );
    assert!(
        summary.did_artist_walk,
        "album activity must trigger the artist walk"
    );
    assert_eq!(summary.artists_changed, 0);
    assert_eq!(summary.artists_removed, 0);
    assert_eq!(summary.tracks_changed, 1);
    assert_eq!(summary.track_total, 5);
    assert!(summary.phase_errors.is_empty());

    // Scoped (not `drop(ev)`): clippy's await_holding_lock tracks lexical
    // regions, so the guard must end in a block before the next await.
    {
        let ev = shared2.events.lock().unwrap();
        assert_eq!(
            ev.albums_changed
                .iter()
                .map(|a| a.id.as_str())
                .collect::<Vec<_>>(),
            vec!["a1"]
        );
        assert_eq!(ev.albums_changed[0].name, "Album One (Remastered)");
        assert_eq!(ev.albums_removed, vec!["a3".to_string()]);
        assert!(ev.artists_changed.is_empty());
        assert_eq!(
            ev.tracks_changed
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>(),
            vec!["t-new"]
        );
    }

    // Cache reflects the reconcile: a3 gone, a1 renamed, new track present.
    let cached = core.list_cached_albums(10).unwrap();
    assert_eq!(cached.len(), 2);
    assert!(cached.iter().any(|a| a.name == "Album One (Remastered)"));
    assert!(!cached.iter().any(|a| a.id == "a3"));
    assert_eq!(core.list_cached_tracks(10).unwrap().len(), 1);
    drop_core(core).await;
}

#[tokio::test]
async fn revalidation_noop_delta_is_two_cheap_album_requests() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    mount_auth(&server, "srv-lc-noop", "u-lc-noop").await;
    // Stage 1: seed one album + one artist + checkpoints via a first full
    // sync (the artist row matters: a populated artist cache is what makes
    // the stage-2 walk-skip meaningful).
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-noop/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Album One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [artist_item_json("r1", "Artist One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-noop/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let core = logged_in_core(tmp.path().to_string_lossy().into_owned(), server.uri()).await;
    let (shared1, mut rx1) = recorder();
    run_revalidation(&core, &shared1, &mut rx1)
        .await
        .expect("stage-1 sync_completed");

    // Stage 2: nothing changed on the server.
    server.reset().await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-noop/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(|req: &Request| req.url.query_pairs().any(|(k, _)| k == "MinDateLastSaved"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-noop/Items"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param_is_missing("MinDateLastSaved"))
        .and(query_param("Limit", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [album_item_json("a1", "Album One")],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // Deliberately NO /Artists/AlbumArtists mock in stage 2: a quiet album
    // delta must skip the (expensive, delta-less) artist walk entirely. If
    // the gate regresses, the walk 404s and surfaces in phase_errors.
    Mock::given(method("GET"))
        .and(path("/Users/u-lc-noop/Items"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let (shared2, mut rx2) = recorder();
    let summary = run_revalidation(&core, &shared2, &mut rx2)
        .await
        .expect("stage-2 sync_completed");

    assert_eq!(summary.albums_changed, 0);
    assert_eq!(summary.albums_removed, 0);
    assert!(
        !summary.did_full_album_sync,
        "matching counts must skip the reconcile walk"
    );
    assert!(
        !summary.did_artist_walk,
        "a quiet album delta must skip the artist walk"
    );
    assert_eq!(summary.artists_changed, 0);
    assert_eq!(summary.tracks_changed, 0);
    assert!(summary.phase_errors.is_empty());
    // Scoped (not `drop(ev)`): clippy's await_holding_lock tracks lexical
    // regions, so the guard must end in a block before the next await.
    {
        let ev = shared2.events.lock().unwrap();
        assert!(ev.albums_changed.is_empty());
        assert!(ev.albums_removed.is_empty());
    }

    // The album phase of a no-op day is exactly two requests: the empty
    // delta page and the Limit=1 total probe — the "≤1% of full payload"
    // acceptance shape from #431.
    let album_requests = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| {
            r.method.as_str() == "GET"
                && r.url.path() == "/Users/u-lc-noop/Items"
                && r.url
                    .query_pairs()
                    .any(|(k, v)| k == "IncludeItemTypes" && v == "MusicAlbum")
        })
        .count();
    assert_eq!(album_requests, 2);
    let artist_requests = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/Artists/AlbumArtists")
        .count();
    assert_eq!(
        artist_requests, 0,
        "skipped artist walk must issue no requests"
    );
    // Cache untouched.
    assert_eq!(core.list_cached_albums(10).unwrap().len(), 1);
    assert_eq!(core.list_cached_artists(10).unwrap().len(), 1);
    drop_core(core).await;
}
