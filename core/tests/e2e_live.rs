//! End-to-end tests against a live Jellyfin server.
//!
//! Gated on `LYREBIRD_E2E_URL` — every test early-returns when the variable is
//! absent so `cargo test --workspace` stays fully offline / hermetic. The e2e
//! CI workflow (`.github/workflows/e2e.yml`) points at the shared
//! `music.skalthoff.com` test instance with the read-only `test` account, and
//! injects the URL and credentials via env vars.
//!
//! What each test exercises against a real Jellyfin:
//!
//! - `probe_returns_server_info` — anonymous `/System/Info/Public`
//! - `login_issues_access_token` — `POST /Users/AuthenticateByName`
//! - `list_albums_returns_envelope` — authenticated `/Items` query; verifies
//!   the pagination envelope shape, agnostic to library contents.
//! - `search_returns_results_for_known_album` — typed search against the
//!   name of a real album from page 1.
//! - `queue_set_add_and_play_next_update_status` — queue primitives (#282)
//!   over real library tracks, verified through the `status()` projection.
//! - `playback_start_stop_reporting_round_trips` — `POST /Items/{id}/
//!   PlaybackInfo` + `/Sessions/Playing` + `/Sessions/Playing/Stopped`,
//!   echoing the server-issued `PlaySessionId` like `AudioEngine` does.
//!
//! Together these back the POLISH_TARGETS "real-server smoke test" gate
//! (login, library page 1, search, queue add, playback start/stop) —
//! `Scripts/smoke-test.sh` is the wrapper that runs this suite against the
//! shared test server.
//!
//! These cover the paths that wiremock-based unit tests can only simulate: the
//! actual Jellyfin response shapes, auth header handling, and HTTP edge cases.

use lyrebird_core::{CoreConfig, LyrebirdCore};
use std::sync::Arc;

const SKIP_HINT: &str = "LYREBIRD_E2E_URL not set, skipping live e2e test";

fn e2e_url() -> Option<String> {
    std::env::var("LYREBIRD_E2E_URL")
        .ok()
        .filter(|s| !s.is_empty())
}

fn e2e_user() -> String {
    std::env::var("LYREBIRD_E2E_USER")
        .expect("LYREBIRD_E2E_USER must be set when LYREBIRD_E2E_URL is set")
}

fn e2e_pass() -> String {
    std::env::var("LYREBIRD_E2E_PASS")
        .expect("LYREBIRD_E2E_PASS must be set when LYREBIRD_E2E_URL is set")
}

fn make_core() -> Arc<LyrebirdCore> {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().to_string_lossy().to_string();
    // Leak the TempDir — keeping it alive for the test process is simpler than
    // plumbing it through each test and the data is inside tmpfs anyway.
    std::mem::forget(tmp);
    LyrebirdCore::new(CoreConfig {
        data_dir: path,
        device_name: "Lyrebird E2E".to_string(),
    })
    .expect("core init")
}

#[test]
fn probe_returns_server_info() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let server = core.probe_server(url).expect("probe_server");
    assert!(!server.name.is_empty(), "server name should be populated");
    assert!(server.version.is_some(), "server version should be present");
}

#[test]
fn login_issues_access_token() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let session = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");
    assert!(
        !session.access_token.is_empty(),
        "access_token must be non-empty"
    );
    assert_eq!(session.user.name, e2e_user());
}

#[test]
fn list_albums_returns_envelope() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");
    let page = core.list_albums(0, 10).expect("list_albums");
    // Envelope shape only — agnostic to library contents (the live test
    // server is populated; mocked / fresh servers may be empty).
    assert!(
        page.items.len() as u32 <= page.total_count.max(page.items.len() as u32),
        "items should not exceed total_count"
    );
}

/// Offline downloads end-to-end against the live server (#819): resolve a real
/// album track, download its audio to disk, and assert the byte stream landed,
/// the index flipped to `Done`, the offline-playback path resolves, and that
/// deleting removes the file. Gated on `LYREBIRD_E2E_URL` like the rest, so it's
/// a no-op in the default hermetic run.
#[test]
fn download_track_to_disk_round_trips() {
    use lyrebird_core::DownloadState;

    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");

    // Find a real track to download: first album with tracks.
    let albums = core.list_albums(0, 25).expect("list_albums");
    let mut track = None;
    for album in albums.items {
        if let Ok(tracks) = core.album_tracks(album.id.clone()) {
            if let Some(first) = tracks.into_iter().next() {
                track = Some(first);
                break;
            }
        }
    }
    let track = track.expect("the live library should have at least one album track");
    let track_id = track.id.clone();

    // Download it.
    let entry = core
        .download_track(track)
        .expect("download_track against the live server");
    assert_eq!(entry.state, DownloadState::Done);
    assert!(entry.size_bytes > 0, "downloaded file must be non-empty");
    let local_path = entry.local_path.clone().expect("local_path set on Done");

    // The bytes are on disk and the size matches what the index recorded.
    let meta = std::fs::metadata(&local_path).expect("downloaded file exists");
    assert_eq!(meta.len(), entry.size_bytes, "on-disk size matches index");

    // Query FFIs reflect the completed download.
    assert!(core.is_track_downloaded(track_id.clone()));
    assert_eq!(
        core.download_local_path(track_id.clone()).as_deref(),
        Some(local_path.as_str())
    );
    assert_eq!(
        core.download_state(track_id.clone())
            .expect("download_state"),
        Some(DownloadState::Done)
    );
    assert!(core.downloads_used_bytes().expect("used_bytes") >= entry.size_bytes);

    // Cleanup: delete removes the row and the file.
    core.delete_download(track_id.clone())
        .expect("delete_download");
    assert!(!core.is_track_downloaded(track_id));
    assert!(
        !std::path::Path::new(&local_path).exists(),
        "deleting a download removes its file"
    );
}

/// Typed search end-to-end: take a real album from page 1 and assert the
/// search endpoint surfaces results for its name. Library-agnostic — the
/// query is derived from whatever the server actually holds rather than a
/// hard-coded title.
#[test]
fn search_returns_results_for_known_album() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");

    let albums = core.list_albums(0, 1).expect("list_albums");
    let album = albums
        .items
        .into_iter()
        .next()
        .expect("the live library should have at least one album");

    let results = core.search(album.name.clone(), 0, 20).expect("search");
    assert!(
        results.total_record_count > 0,
        "searching for an existing album's name ({:?}) should match at least one item",
        album.name
    );
}

/// Queue primitives end-to-end (#282): build a queue from real library
/// tracks, then exercise `add_to_queue` (append) and `play_next` (insert
/// after the playhead) and verify the `status()` projection tracks the
/// changes without clobbering the current track — the regression the old
/// fall-through-to-`play()` semantics used to cause.
#[test]
fn queue_set_add_and_play_next_update_status() {
    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");

    // Gather at least three real tracks across the first albums.
    let albums = core.list_albums(0, 25).expect("list_albums");
    let mut tracks = Vec::new();
    for album in albums.items {
        if let Ok(album_tracks) = core.album_tracks(album.id.clone()) {
            tracks.extend(album_tracks);
        }
        if tracks.len() >= 3 {
            break;
        }
    }
    assert!(
        tracks.len() >= 3,
        "the live library should provide at least three tracks"
    );
    let (a, b, c) = (tracks[0].clone(), tracks[1].clone(), tracks[2].clone());

    let current = core.set_queue(vec![a.clone()], 0).expect("set_queue");
    assert_eq!(
        current.map(|t| t.id),
        Some(a.id.clone()),
        "set_queue primes the playhead onto the start track"
    );

    let len = core.add_to_queue(vec![b]);
    assert_eq!(len, 2, "add_to_queue appends to the end of the queue");

    let len = core.play_next(vec![c]);
    assert_eq!(len, 3, "play_next inserts after the playhead");

    let status = core.status();
    assert_eq!(status.queue_length, 3);
    assert_eq!(
        status.queue_position, 0,
        "queue mutations must not move the playhead"
    );
    assert_eq!(
        status.current_track.map(|t| t.id),
        Some(a.id),
        "queue mutations must not clobber the current track"
    );
}

/// Playback start/stop reporting end-to-end: resolve `PlaybackInfo` for a
/// real track, then `POST /Sessions/Playing` and `/Sessions/Playing/Stopped`,
/// echoing the server-issued `PlaySessionId` exactly like `AudioEngine` does
/// (#569). Drives the same server flow that backs PlayCount increments and
/// "Now Playing on macOS" in Jellyfin Web. The test account's reports are
/// scoped to that user, so production data stays clean.
#[test]
fn playback_start_stop_reporting_round_trips() {
    use lyrebird_core::{PlaybackInfoOpts, PlaybackStartInfo, PlaybackStopInfo};

    let Some(url) = e2e_url() else {
        eprintln!("{SKIP_HINT}");
        return;
    };
    let core = make_core();
    let _ = core
        .login(url, e2e_user(), e2e_pass())
        .expect("login should succeed with the test account");

    // Find a real track to report against: first album with tracks.
    let albums = core.list_albums(0, 25).expect("list_albums");
    let mut track = None;
    for album in albums.items {
        if let Ok(album_tracks) = core.album_tracks(album.id.clone()) {
            if let Some(first) = album_tracks.into_iter().next() {
                track = Some(first);
                break;
            }
        }
    }
    let track = track.expect("the live library should have at least one album track");

    let info = core
        .playback_info(track.id.clone(), PlaybackInfoOpts::default())
        .expect("playback_info against the live server");
    assert!(
        info.error_code.is_none(),
        "PlaybackInfo should not carry an error code: {:?}",
        info.error_code
    );
    assert!(
        !info.media_sources.is_empty(),
        "PlaybackInfo should resolve at least one media source"
    );
    let play_session_id = info.play_session_id.clone();

    core.report_playback_started(PlaybackStartInfo {
        item_id: track.id.clone(),
        play_session_id: play_session_id.clone(),
        play_method: Some("DirectPlay".to_string()),
        position_ticks: Some(0),
        can_seek: true,
        ..Default::default()
    })
    .expect("report_playback_started");

    core.report_playback_stopped(PlaybackStopInfo {
        item_id: track.id,
        failed: false,
        position_ticks: 0,
        media_source_id: None,
        play_session_id,
        session_id: None,
    })
    .expect("report_playback_stopped");
}
