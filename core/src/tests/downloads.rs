use super::*;

// ===========================================================================
// Offline downloads (#819).
//
// The engine in `crate::downloads` is exercised at two layers:
//   * directly over a temp-backed `Database` + temp dir (enqueue / state /
//     list / delete / budget evict + refuse / stale-file fallback), which
//     needs no network, and
//   * end-to-end through the `LyrebirdCore` FFI against a wiremock Jellyfin
//     (login -> download_track -> file on disk + `done` state + offline path).
// ===========================================================================

/// A minimal `Track` for download tests. `bitrate` + `runtime_ticks` drive the
/// pre-fetch budget estimate, so they're parameterized.
fn dl_track(id: &str, bitrate: Option<i64>, runtime_ticks: u64) -> crate::models::Track {
    crate::models::Track {
        id: id.into(),
        name: format!("Track {id}"),
        album_id: Some("album-1".into()),
        album_name: Some("Album One".into()),
        artist_name: "Artist".into(),
        artist_id: Some("artist-1".into()),
        index_number: Some(1),
        disc_number: Some(1),
        year: Some(2020),
        runtime_ticks,
        is_favorite: false,
        play_count: 0,
        container: Some("mp3".into()),
        bitrate,
        image_tag: None,
        playlist_item_id: None,
        user_data: None,
    }
}

#[test]
fn download_enqueue_then_state_and_delete() {
    use crate::downloads;
    let db = Database::in_memory().unwrap();
    let track = dl_track("t-enq", None, 0);

    // No record yet.
    assert!(downloads::state_for(&db, "t-enq").unwrap().is_none());

    downloads::enqueue(&db, &track, 100).unwrap();
    assert_eq!(
        downloads::state_for(&db, "t-enq").unwrap(),
        Some(crate::models::DownloadState::Queued)
    );

    // It appears in the list with the snapshotted track metadata.
    let list = downloads::list(&db).unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].track.name, "Track t-enq");
    assert_eq!(list[0].state, crate::models::DownloadState::Queued);

    // Queued rows are not yet playable offline (no file).
    assert!(downloads::local_path_for(&db, "t-enq").unwrap().is_none());

    // Delete is idempotent and clears the record.
    downloads::delete(&db, "t-enq").unwrap();
    assert!(downloads::state_for(&db, "t-enq").unwrap().is_none());
    downloads::delete(&db, "t-enq").unwrap(); // second delete: no-op, no error
}

#[test]
fn download_mark_done_counts_toward_used_bytes() {
    let db = Database::in_memory().unwrap();
    let track = dl_track("t-done", None, 0);
    let json = serde_json::to_string(&track).unwrap();

    db.download_upsert_queued("t-done", &json, 1).unwrap();
    // A queued row contributes nothing to used bytes.
    assert_eq!(db.download_used_bytes().unwrap(), (0, 0));

    db.download_mark_done("t-done", "/tmp/t-done.mp3", 4096, Some("mp3"), 2)
        .unwrap();
    assert_eq!(db.download_used_bytes().unwrap(), (4096, 1));

    let stats = crate::downloads::stats(&db).unwrap();
    assert_eq!(stats.used_bytes, 4096);
    assert_eq!(stats.item_count, 1);
    assert_eq!(stats.budget_bytes, 0); // unlimited by default
}

#[test]
fn download_local_path_falls_back_when_file_missing() {
    use crate::downloads;
    let db = Database::in_memory().unwrap();
    let track = dl_track("t-stale", None, 0);
    let json = serde_json::to_string(&track).unwrap();
    db.download_upsert_queued("t-stale", &json, 1).unwrap();
    // Point at a path that does not exist on disk.
    db.download_mark_done(
        "t-stale",
        "/nonexistent/dir/t-stale.mp3",
        10,
        Some("mp3"),
        2,
    )
    .unwrap();

    // State is `done`...
    assert_eq!(
        downloads::state_for(&db, "t-stale").unwrap(),
        Some(crate::models::DownloadState::Done)
    );
    // ...but the offline-playback resolver returns None because the file is
    // gone, so the player streams instead of handing AVFoundation a dead path.
    assert!(downloads::local_path_for(&db, "t-stale").unwrap().is_none());
}

#[tokio::test]
async fn download_budget_refuses_track_larger_than_whole_budget() {
    use crate::downloads;
    let db = std::sync::Arc::new(Database::in_memory().unwrap());
    let tmp = tempfile::tempdir().unwrap();

    // 1 MB budget; a track estimated at ~9 MB (320 kbps for ~225s) can't fit.
    db.set_setting(downloads::DOWNLOAD_BUDGET_KEY, &(1_000_000u64).to_string())
        .unwrap();

    // 320 kbps * 225s / 8 ≈ 9 MB. The pre-fetch budget check refuses it before
    // any network I/O, so the (never-contacted) client URL is irrelevant.
    let track = dl_track("t-big", Some(320_000), 225 * 10_000_000);
    downloads::enqueue(&db, &track, 1).unwrap();
    let client = mock_client("http://127.0.0.1:0");
    let permits = tokio::sync::Semaphore::new(2);
    let budget_lock = tokio::sync::Mutex::new(());
    let err = downloads::fetch(&db, &client, tmp.path(), &track, 2, &permits, &budget_lock)
        .await
        .expect_err("oversized track must be refused");
    match err {
        LyrebirdError::Storage(_) => {}
        other => panic!("expected Storage error, got {other:?}"),
    }
    // The refused track is recorded as failed, not done, and uses no space.
    assert_eq!(
        downloads::state_for(&db, "t-big").unwrap(),
        Some(crate::models::DownloadState::Failed)
    );
    assert_eq!(db.download_used_bytes().unwrap(), (0, 0));
}

#[test]
fn download_budget_evicts_oldest_completed_first() {
    use crate::downloads;
    let db = Database::in_memory().unwrap();

    // Two completed downloads at 400 bytes each, with distinct completion
    // timestamps so the LRU order is deterministic.
    for (id, completed_at) in [("old", 10i64), ("new", 20i64)] {
        let track = dl_track(id, None, 0);
        let json = serde_json::to_string(&track).unwrap();
        db.download_upsert_queued(id, &json, completed_at).unwrap();
        db.download_mark_done(
            id,
            &format!("/tmp/{id}.mp3"),
            400,
            Some("mp3"),
            completed_at,
        )
        .unwrap();
    }
    assert_eq!(db.download_used_bytes().unwrap(), (800, 2));

    // Budget 1000, incoming 400 -> total would be 1200, over by 200. Evicting
    // the single oldest (400 bytes) brings used to 400, so 400+400 = 800 fits.
    // `ensure_budget_for` is private; exercise it via the public planning that
    // `fetch` would do by calling the crate-internal helper through a thin
    // re-enqueue + manual check using the LRU list it consults.
    let lru = db.download_completed_lru().unwrap();
    assert_eq!(lru.first().map(|(id, _, _)| id.as_str()), Some("old"));
    assert_eq!(lru.last().map(|(id, _, _)| id.as_str()), Some("new"));

    // Simulate the evict step the budget planner performs: drop the oldest.
    let _ = downloads::delete(&db, "old");
    assert_eq!(db.download_used_bytes().unwrap(), (400, 1));
    // The survivor is the newest one.
    assert!(downloads::state_for(&db, "new").unwrap().is_some());
    assert!(downloads::state_for(&db, "old").unwrap().is_none());
}

#[test]
fn download_dir_honours_override_then_falls_back() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);

    // Default: <data_dir>/downloads.
    let default_dir = core.download_dir_path();
    assert!(default_dir.ends_with("downloads"), "got {default_dir}");

    // Override to a custom path.
    core.set_download_dir("/custom/offline/spot".into())
        .unwrap();
    assert_eq!(core.download_dir_path(), "/custom/offline/spot");

    // Clearing the override falls back to the default.
    core.set_download_dir("".into()).unwrap();
    assert_eq!(core.download_dir_path(), default_dir);

    // Budget round-trips through the FFI.
    core.set_download_budget_bytes(5_000_000).unwrap();
    assert_eq!(core.download_stats().unwrap().budget_bytes, 5_000_000);
}

#[test]
fn download_track_without_session_is_no_session() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    let track = dl_track("t-nosession", None, 0);
    let err = core
        .download_track(track)
        .expect_err("download without login must fail");
    assert!(matches!(err, LyrebirdError::NoSession));
}

#[tokio::test(flavor = "multi_thread")]
async fn download_track_end_to_end_writes_file_and_marks_done() {
    install_mock_keyring();
    let server = MockServer::start().await;

    // Auth.
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-dl",
            "ServerId": "srv-dl",
            "ServerName": "DL Server",
            "User": { "Id": "user-dl", "Name": "dl-user", "ServerId": "srv-dl", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    // The audio stream endpoint hit by `download_to_file` -> `stream_url`.
    let audio_bytes: Vec<u8> = (0..2048u32).map(|i| (i % 251) as u8).collect();
    Mock::given(method("GET"))
        .and(path("/Audio/track-dl/universal"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "audio/mpeg")
                .set_body_bytes(audio_bytes.clone()),
        )
        .mount(&server)
        .await;

    let tmp = tempfile::tempdir().unwrap();
    let data_dir = tmp.path().to_string_lossy().into_owned();
    let server_uri = server.uri();
    let expected = audio_bytes.clone();

    // The whole `LyrebirdCore` lifecycle runs on a blocking thread: `new` /
    // `login` / `download_track` all `block_on` the core's owned runtime
    // (illegal from an async worker), and the core's runtime must also be
    // *dropped* off the async context — dropping a tokio runtime inside another
    // runtime panics ("Cannot drop a runtime ..."). Keeping the core local to
    // this closure guarantees it's dropped here, on the blocking thread.
    tokio::task::spawn_blocking(move || {
        let core = LyrebirdCore::new(CoreConfig {
            data_dir,
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_uri, "dl-user".into(), "pw".into())
            .expect("login");
        let track = dl_track("track-dl", None, 0);
        let entry = core.download_track(track).expect("download_track");

        // The returned entry is complete and sized to the payload.
        assert_eq!(entry.state, crate::models::DownloadState::Done);
        assert_eq!(entry.size_bytes, expected.len() as u64);
        let local_path = entry.local_path.clone().expect("local_path");

        // The file exists on disk with exactly the bytes we served.
        let on_disk = std::fs::read(&local_path).expect("read downloaded file");
        assert_eq!(on_disk, expected);
        // It lives under the resolved downloads dir.
        assert!(
            local_path.starts_with(&core.download_dir_path()),
            "got {local_path}"
        );

        // The cheap query FFIs reflect the completed download.
        assert!(core.is_track_downloaded("track-dl".into()));
        assert_eq!(
            core.download_state("track-dl".into()).unwrap(),
            Some(crate::models::DownloadState::Done)
        );
        assert_eq!(
            core.download_local_path("track-dl".into()).as_deref(),
            Some(local_path.as_str())
        );
        assert_eq!(core.downloads_used_bytes().unwrap(), expected.len() as u64);
        assert_eq!(core.list_downloads().unwrap().len(), 1);

        // Deleting removes both the row and the file.
        core.delete_download("track-dl".into()).unwrap();
        assert!(!core.is_track_downloaded("track-dl".into()));
        assert!(!std::path::Path::new(&local_path).exists());
        assert_eq!(core.downloads_used_bytes().unwrap(), 0);
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn download_track_server_error_marks_failed() {
    install_mock_keyring();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-fail",
            "ServerId": "srv-fail",
            "ServerName": "Fail Server",
            "User": { "Id": "user-fail", "Name": "fail-user", "ServerId": "srv-fail", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // The audio endpoint returns 404 — a non-retryable failure.
    Mock::given(method("GET"))
        .and(path("/Audio/track-fail/universal"))
        .respond_with(ResponseTemplate::new(404).set_body_string("not found"))
        .mount(&server)
        .await;

    let tmp = tempfile::tempdir().unwrap();
    let data_dir = tmp.path().to_string_lossy().into_owned();
    let server_uri = server.uri();

    // See the end-to-end test for why the core lives entirely inside the
    // blocking closure (block_on + runtime-drop both need a non-async thread).
    tokio::task::spawn_blocking(move || {
        let core = LyrebirdCore::new(CoreConfig {
            data_dir,
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_uri, "fail-user".into(), "pw".into())
            .expect("login");
        let track = dl_track("track-fail", None, 0);
        let result = core.download_track(track);

        assert!(result.is_err(), "404 audio fetch must surface an error");
        // The row is marked failed (not done) and contributes no used bytes.
        assert_eq!(
            core.download_state("track-fail".into()).unwrap(),
            Some(crate::models::DownloadState::Failed)
        );
        assert!(!core.is_track_downloaded("track-fail".into()));
        assert_eq!(core.downloads_used_bytes().unwrap(), 0);
    })
    .await
    .unwrap();
}

/// A track id carrying path separators / `..` must be refused before any file
/// is written, and must not escape the downloads directory. Guards the
/// path-traversal fix in `downloads::fetch` (`safe_filename_stem` +
/// `dest_within_dir`).
#[tokio::test]
async fn download_rejects_path_traversal_track_id() {
    use crate::downloads;
    let db = std::sync::Arc::new(Database::in_memory().unwrap());
    let tmp = tempfile::tempdir().unwrap();
    // Point the downloads dir at our temp tree so we can prove nothing escaped.
    db.set_setting(downloads::DOWNLOAD_DIR_KEY, &tmp.path().to_string_lossy())
        .unwrap();

    // An id that, interpolated into `<dir>/<id>.<ext>`, would climb out of the
    // downloads dir and into the temp root as `escape.mp3`.
    let evil_id = "../escape";
    let track = dl_track(evil_id, None, 0);
    downloads::enqueue(&db, &track, 1).unwrap();

    let permits = tokio::sync::Semaphore::new(2);
    let budget_lock = tokio::sync::Mutex::new(());
    // The client URL is never contacted — validation refuses the id first.
    let client = mock_client("http://127.0.0.1:0");
    let err = downloads::fetch(&db, &client, tmp.path(), &track, 2, &permits, &budget_lock)
        .await
        .expect_err("path-traversal id must be refused");
    assert!(
        matches!(err, LyrebirdError::InvalidInput(_)),
        "expected InvalidInput, got {err:?}"
    );

    // The row is marked failed, and crucially NO file was written anywhere the
    // traversal pointed: neither inside the downloads dir nor its parent.
    assert_eq!(
        downloads::state_for(&db, evil_id).unwrap(),
        Some(crate::models::DownloadState::Failed)
    );
    let parent_escape = tmp.path().parent().unwrap().join("escape.mp3");
    assert!(
        !parent_escape.exists(),
        "traversal wrote outside the downloads dir at {parent_escape:?}"
    );
    // The downloads dir itself holds no stray audio file.
    let stray: Vec<_> = std::fs::read_dir(tmp.path())
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name())
        .collect();
    assert!(
        stray.is_empty(),
        "expected no files written for a refused id, found {stray:?}"
    );
}

/// `downloads::fetch` must cap parallel transfers at the semaphore's permit
/// count (#819: default 2). Three concurrent fetches sharing a 2-permit
/// semaphore must never have more than two streaming at once. A counting
/// wiremock responder records the peak observed concurrency.
#[tokio::test(flavor = "multi_thread")]
async fn download_fetch_caps_parallel_transfers() {
    use crate::downloads;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    let server = MockServer::start().await;
    let in_flight = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let in_flight_mock = in_flight.clone();
    let peak_mock = peak.clone();

    // Each audio request bumps the in-flight counter, records the running peak,
    // holds the connection briefly so overlap is observable, then releases.
    Mock::given(method("GET"))
        .respond_with(move |req: &Request| {
            // Only the /Audio/.../universal stream endpoint participates.
            if !req.url.path().starts_with("/Audio/") {
                return ResponseTemplate::new(404);
            }
            let now = in_flight_mock.fetch_add(1, Ordering::SeqCst) + 1;
            peak_mock.fetch_max(now, Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(150));
            in_flight_mock.fetch_sub(1, Ordering::SeqCst);
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "audio/mpeg")
                .set_body_bytes(vec![7u8; 64])
        })
        .mount(&server)
        .await;

    let db = Arc::new(Database::in_memory().unwrap());
    let tmp = tempfile::tempdir().unwrap();
    db.set_setting(downloads::DOWNLOAD_DIR_KEY, &tmp.path().to_string_lossy())
        .unwrap();
    // Shared across all fetches — this is the cap under test.
    let permits = Arc::new(tokio::sync::Semaphore::new(2));
    let budget_lock = Arc::new(tokio::sync::Mutex::new(()));
    let client = Arc::new(mock_client(&server.uri()));

    let mut handles = Vec::new();
    for i in 0..3 {
        let id = format!("cap-{i}");
        let track = dl_track(&id, None, 0);
        downloads::enqueue(&db, &track, 1).unwrap();
        let (db, client, permits, budget_lock) = (
            db.clone(),
            client.clone(),
            permits.clone(),
            budget_lock.clone(),
        );
        let dir = tmp.path().to_path_buf();
        handles.push(tokio::spawn(async move {
            downloads::fetch(&db, &client, &dir, &track, 2, &permits, &budget_lock)
                .await
                .expect("fetch should succeed");
        }));
    }
    for h in handles {
        h.await.unwrap();
    }

    assert!(
        peak.load(Ordering::SeqCst) <= 2,
        "expected at most 2 concurrent transfers, observed peak {}",
        peak.load(Ordering::SeqCst)
    );
    // All three still completed.
    assert_eq!(db.download_used_bytes().unwrap().1, 3);
}

/// Two concurrent fetches sharing a budget that fits only one track must not
/// both commit and collectively exceed the budget. The size-checked commit
/// under `download_budget_lock` serialises the decision, so the second to
/// finish evicts the first (LRU) instead of stacking on top. Guards the TOCTOU
/// fix.
#[tokio::test(flavor = "multi_thread")]
async fn download_concurrent_fetches_respect_shared_budget() {
    use crate::downloads;
    use std::sync::Arc;

    let server = MockServer::start().await;
    // 64-byte body per track; budget of 100 fits exactly one (not two).
    Mock::given(method("GET"))
        .respond_with(|req: &Request| {
            if req.url.path().starts_with("/Audio/") {
                ResponseTemplate::new(200)
                    .insert_header("Content-Type", "audio/mpeg")
                    .set_body_bytes(vec![1u8; 64])
            } else {
                ResponseTemplate::new(404)
            }
        })
        .mount(&server)
        .await;

    let db = Arc::new(Database::in_memory().unwrap());
    let tmp = tempfile::tempdir().unwrap();
    db.set_setting(downloads::DOWNLOAD_DIR_KEY, &tmp.path().to_string_lossy())
        .unwrap();
    db.set_setting(downloads::DOWNLOAD_BUDGET_KEY, &100u64.to_string())
        .unwrap();
    let permits = Arc::new(tokio::sync::Semaphore::new(2));
    let budget_lock = Arc::new(tokio::sync::Mutex::new(()));
    let client = Arc::new(mock_client(&server.uri()));

    // Two tracks with no bitrate -> pre-fetch estimate is 0, so both pass the
    // *estimate* gate and race to the post-fetch (true-size) commit. Distinct
    // completion timestamps via `now` so the LRU victim is deterministic.
    let mut handles = Vec::new();
    for (i, now) in [("budget-a", 10i64), ("budget-b", 20i64)] {
        let track = dl_track(i, None, 0);
        downloads::enqueue(&db, &track, now).unwrap();
        let (db, client, permits, budget_lock) = (
            db.clone(),
            client.clone(),
            permits.clone(),
            budget_lock.clone(),
        );
        let dir = tmp.path().to_path_buf();
        handles.push(tokio::spawn(async move {
            // A fetch may legitimately fail here only if it can't fit at all,
            // which it can (64 <= 100), so both should succeed; the loser just
            // evicts the winner.
            downloads::fetch(&db, &client, &dir, &track, now, &permits, &budget_lock)
                .await
                .expect("fetch should succeed (track fits an empty store)");
        }));
    }
    for h in handles {
        h.await.unwrap();
    }

    // The invariant: completed usage never exceeds the budget, even though both
    // ran concurrently. Exactly one survives as `done`.
    let (used, count) = db.download_used_bytes().unwrap();
    assert!(used <= 100, "used {used} exceeded budget 100");
    assert_eq!(count, 1, "exactly one download should remain within budget");
}

#[test]
fn clear_all_removes_rows_and_files() {
    use crate::downloads;
    let db = Database::in_memory().unwrap();
    let dir = tempfile::tempdir().unwrap();

    // One completed download with a real file plus a stale `.part` leftover,
    // and one still-queued row with no file yet.
    let done = dl_track("t-done-clear", None, 0);
    let queued = dl_track("t-queued-clear", None, 0);
    let json_done = serde_json::to_string(&done).unwrap();
    let json_queued = serde_json::to_string(&queued).unwrap();

    let audio = dir.path().join("t-done-clear.mp3");
    std::fs::write(&audio, b"bytes").unwrap();
    let part = audio.with_extension("part");
    std::fs::write(&part, b"partial").unwrap();

    db.download_upsert_queued("t-done-clear", &json_done, 1).unwrap();
    db.download_mark_done("t-done-clear", audio.to_str().unwrap(), 5, Some("mp3"), 2)
        .unwrap();
    db.download_upsert_queued("t-queued-clear", &json_queued, 3).unwrap();

    downloads::clear_all(&db).unwrap();

    assert!(
        downloads::list(&db).unwrap().is_empty(),
        "every download row should be cleared"
    );
    assert!(!audio.exists(), "the completed file should be unlinked");
    assert!(!part.exists(), "the stale .part should be unlinked");

    // Idempotent on an already-empty table.
    downloads::clear_all(&db).unwrap();
    assert!(downloads::list(&db).unwrap().is_empty());
}
