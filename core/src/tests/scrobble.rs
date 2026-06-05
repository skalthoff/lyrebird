use super::*;

// ---------------------------------------------------------------------------
// Scrobbling — ListenBrainz (#46)
// ---------------------------------------------------------------------------

/// Minimal `Track` builder for the scrobble tests. Mirrors the helper used by
/// the player tests above but lives here so the scrobble block is
/// self-contained when it lands on a fresh rebase.
fn scrobble_track(id: &str, name: &str, artist: &str, album: Option<&str>) -> crate::models::Track {
    crate::models::Track {
        id: id.into(),
        name: name.into(),
        album_id: None,
        album_name: album.map(|a| a.into()),
        artist_name: artist.into(),
        artist_id: None,
        index_number: None,
        disc_number: None,
        year: None,
        runtime_ticks: 1_800_000_000,
        is_favorite: false,
        play_count: 0,
        container: None,
        bitrate: None,
        image_tag: None,
        playlist_item_id: None,
        user_data: None,
    }
}

#[test]
fn scrobble_threshold_not_reached_before_half_or_four_min() {
    // 3-minute track (180s). Half is 90s. At 89s neither rule is satisfied.
    assert!(!crate::scrobble::scrobble_threshold_reached(89.0, 180.0));
    // Just started.
    assert!(!crate::scrobble::scrobble_threshold_reached(1.0, 180.0));
    // Position zero never trips, even with a long runtime.
    assert!(!crate::scrobble::scrobble_threshold_reached(0.0, 6000.0));
    // Negative position (defensive) never trips.
    assert!(!crate::scrobble::scrobble_threshold_reached(-5.0, 180.0));
}

#[test]
fn scrobble_threshold_reached_at_half_track() {
    // 3-minute track: crosses at exactly half (90s).
    assert!(crate::scrobble::scrobble_threshold_reached(90.0, 180.0));
    assert!(crate::scrobble::scrobble_threshold_reached(120.0, 180.0));
}

#[test]
fn scrobble_threshold_reached_at_four_minutes_for_long_track() {
    // 20-minute track (1200s). Half (600s) is way past four minutes, so the
    // four-minute cap is what fires first — at 240s, not 600s.
    assert!(!crate::scrobble::scrobble_threshold_reached(239.0, 1200.0));
    assert!(crate::scrobble::scrobble_threshold_reached(240.0, 1200.0));
    assert!(crate::scrobble::scrobble_threshold_reached(241.0, 1200.0));
    // 300s is past the four-minute cap, so it DOES trip even though it's
    // well below the 600s half-track mark.
    assert!(crate::scrobble::scrobble_threshold_reached(300.0, 1200.0));
}

#[test]
fn scrobble_threshold_unknown_runtime_uses_four_minute_rule() {
    // runtime 0 == unknown duration. Defers entirely to the four-minute rule.
    assert!(!crate::scrobble::scrobble_threshold_reached(120.0, 0.0));
    assert!(crate::scrobble::scrobble_threshold_reached(240.0, 0.0));
}

#[test]
fn scrobble_threshold_short_track_never_scrobbles() {
    // A 20-second sting: under the 30s minimum, never eligible even at its end.
    assert!(!crate::scrobble::scrobble_threshold_reached(20.0, 20.0));
    assert!(!crate::scrobble::scrobble_threshold_reached(19.0, 20.0));
}

#[test]
fn scrobble_playing_now_payload_shape() {
    let track = scrobble_track("item-1", "Yona", "Saloli", Some("The Deep End"));
    let payload = crate::scrobble::playing_now_payload(&track);

    assert_eq!(payload["listen_type"], "playing_now");
    let listen = &payload["payload"][0];
    // playing_now must NOT carry a timestamp — ListenBrainz rejects it.
    assert!(listen.get("listened_at").is_none());
    let md = &listen["track_metadata"];
    assert_eq!(md["artist_name"], "Saloli");
    assert_eq!(md["track_name"], "Yona");
    assert_eq!(md["release_name"], "The Deep End");
    assert_eq!(md["additional_info"]["jellyfin_item_id"], "item-1");
    assert_eq!(md["additional_info"]["music_service_name"], "Jellyfin");
    // Client identity is stamped so the listen is attributable.
    assert!(md["additional_info"]["submission_client"]
        .as_str()
        .unwrap()
        .contains("Lyrebird"));
}

#[test]
fn scrobble_single_listen_payload_shape() {
    let track = scrobble_track("item-2", "Tides", "Saloli", None);
    let payload = crate::scrobble::single_listen_payload(&track, 1_700_000_000);

    assert_eq!(payload["listen_type"], "single");
    let listen = &payload["payload"][0];
    assert_eq!(listen["listened_at"], 1_700_000_000i64);
    let md = &listen["track_metadata"];
    assert_eq!(md["artist_name"], "Saloli");
    assert_eq!(md["track_name"], "Tides");
    // No album -> release_name omitted entirely (not null).
    assert!(md.get("release_name").is_none());
}

#[test]
fn scrobble_empty_token_is_rejected() {
    assert!(crate::scrobble::Scrobbler::new("").is_err());
    assert!(crate::scrobble::Scrobbler::new("   ").is_err());
    assert!(crate::scrobble::Scrobbler::new("lb-token").is_ok());
}

#[tokio::test]
async fn scrobble_submit_single_posts_to_listenbrainz() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/submit-listens"))
        .and(wiremock::matchers::header(
            "Authorization",
            "Token lb-secret-token",
        ))
        .and(wiremock::matchers::body_json(json!({
            "listen_type": "single",
            "payload": [{
                "listened_at": 1_700_000_000i64,
                "track_metadata": {
                    "artist_name": "Saloli",
                    "track_name": "Yona",
                    "release_name": "The Deep End",
                    "additional_info": {
                        "media_player": "Lyrebird Desktop",
                        "submission_client": "Lyrebird Desktop",
                        "submission_client_version": env!("CARGO_PKG_VERSION"),
                        "music_service_name": "Jellyfin",
                        "jellyfin_item_id": "item-1",
                    }
                }
            }]
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "status": "ok" })))
        .expect(1)
        .mount(&server)
        .await;

    let track = scrobble_track("item-1", "Yona", "Saloli", Some("The Deep End"));
    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "lb-secret-token").unwrap();
    scrobbler
        .submit_listen(&track, 1_700_000_000)
        .await
        .unwrap();
    // `.expect(1)` on the mock asserts exactly one POST landed on drop.
}

#[tokio::test]
async fn scrobble_submit_playing_now_posts_without_timestamp() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/submit-listens"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "status": "ok" })))
        .expect(1)
        .mount(&server)
        .await;

    // Capture the request body to assert the listen_type and absence of a
    // timestamp directly.
    let track = scrobble_track("item-7", "Drift", "Saloli", None);
    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "tok").unwrap();
    scrobbler.submit_playing_now(&track).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    let body: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert_eq!(body["listen_type"], "playing_now");
    assert!(body["payload"][0].get("listened_at").is_none());
}

#[tokio::test]
async fn scrobble_submit_maps_401_to_auth_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/submit-listens"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({ "error": "Invalid token" })))
        .mount(&server)
        .await;

    let track = scrobble_track("item-1", "Yona", "Saloli", None);
    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "bad-token").unwrap();
    let err = scrobbler.submit_listen(&track, 1).await.unwrap_err();
    assert!(matches!(err, LyrebirdError::Auth(_)));
}

#[tokio::test]
async fn scrobble_submit_maps_500_to_server_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/submit-listens"))
        .respond_with(ResponseTemplate::new(500).set_body_string("upstream boom"))
        .mount(&server)
        .await;

    let track = scrobble_track("item-1", "Yona", "Saloli", None);
    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "tok").unwrap();
    let err = scrobbler.submit_listen(&track, 1).await.unwrap_err();
    match err {
        LyrebirdError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server error, got {other:?}"),
    }
}

#[tokio::test]
async fn scrobble_submit_maps_429_to_rate_limit_with_retry_after() {
    // ListenBrainz throttling (429 + Retry-After) must map to RateLimit
    // carrying the parsed seconds, not a generic Server error.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/submit-listens"))
        .respond_with(
            ResponseTemplate::new(429)
                .insert_header("Retry-After", "17")
                .set_body_string("rate limited"),
        )
        .mount(&server)
        .await;

    let track = scrobble_track("item-1", "Yona", "Saloli", None);
    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "tok").unwrap();
    let err = scrobbler.submit_listen(&track, 1).await.unwrap_err();
    match err {
        LyrebirdError::RateLimit { retry_after } => assert_eq!(retry_after, Some(17)),
        other => panic!("expected RateLimit {{ Some(17) }}, got {other:?}"),
    }
}

#[tokio::test]
async fn scrobble_skips_track_missing_name_or_artist() {
    // A track with a blank name or artist would be rejected by ListenBrainz;
    // the client must guard at the boundary and return InvalidInput WITHOUT
    // POSTing. We mount NO submit route so a stray POST surfaces as a failure.
    let server = MockServer::start().await;

    let scrobbler = crate::scrobble::Scrobbler::with_root(server.uri(), "tok").unwrap();

    let no_name = scrobble_track("item-1", "   ", "Artist", None);
    let err = scrobbler.submit_playing_now(&no_name).await.unwrap_err();
    assert!(matches!(err, LyrebirdError::InvalidInput(_)), "got {err:?}");

    let no_artist = scrobble_track("item-2", "Title", "", None);
    let err = scrobbler.submit_listen(&no_artist, 1).await.unwrap_err();
    assert!(matches!(err, LyrebirdError::InvalidInput(_)), "got {err:?}");

    // Nothing should have been POSTed.
    let posts = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/1/submit-listens")
        .count();
    assert_eq!(
        posts, 0,
        "invalid tracks must not be submitted, got {posts} POSTs"
    );
}

#[test]
fn scrobble_token_persistence_and_configured_flag() {
    // The scrobble token now lives in the OS keyring; install the in-memory
    // mock so this doesn't touch the real keychain. The scrobble key is a
    // single fixed entry shared process-wide, so clear it first for
    // determinism and leave it cleared at the end.
    install_mock_keyring();
    let _serial = scrobble_keyring_guard();
    CredentialStore::delete_scrobble_token().ok();

    let dir = tempfile::tempdir().unwrap();
    let config = CoreConfig {
        data_dir: dir.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    };
    let core = LyrebirdCore::new(config).unwrap();

    // Fresh install: not configured.
    assert!(!core.is_scrobble_configured());

    // Set a token -> configured.
    core.set_scrobble_token(Some("lb-user-token".into()))
        .unwrap();
    assert!(core.is_scrobble_configured());

    // Blank/whitespace token clears it (treated as disconnect).
    core.set_scrobble_token(Some("   ".into())).unwrap();
    assert!(!core.is_scrobble_configured());

    // Set again, then explicit None clears.
    core.set_scrobble_token(Some("lb-user-token".into()))
        .unwrap();
    assert!(core.is_scrobble_configured());
    core.set_scrobble_token(None).unwrap();
    assert!(!core.is_scrobble_configured());
}

#[test]
fn scrobble_submit_without_token_errors_invalid_input() {
    // `scrobble_token()` reads the keyring now; install the mock and clear the
    // (shared) scrobble key so this test sees the "no token" state.
    install_mock_keyring();
    let _serial = scrobble_keyring_guard();
    CredentialStore::delete_scrobble_token().ok();

    let dir = tempfile::tempdir().unwrap();
    let config = CoreConfig {
        data_dir: dir.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    };
    let core = LyrebirdCore::new(config).unwrap();
    let track = scrobble_track("x", "X", "Y", None);

    // No token configured -> InvalidInput, never a panic / network call.
    let err = core.scrobble_now_playing(track.clone()).unwrap_err();
    assert!(matches!(err, LyrebirdError::InvalidInput(_)));
    let err = core.scrobble_submit_listen(track, 1).unwrap_err();
    assert!(matches!(err, LyrebirdError::InvalidInput(_)));
}

#[test]
fn scrobble_token_survives_clear_user_data() {
    // Logout must NOT wipe the scrobble token (account-independent pref). The
    // token now lives in the keyring, which `clear_user_data` (settings table
    // + caches only) doesn't touch — so the connection survives a sign-out.
    install_mock_keyring();
    let _serial = scrobble_keyring_guard();
    CredentialStore::save_scrobble_token("keep-me").unwrap();

    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path().join("lb.db")).unwrap();
    db.clear_user_data().unwrap();

    assert_eq!(
        CredentialStore::load_scrobble_token().unwrap().as_deref(),
        Some("keep-me"),
        "clear_user_data must not delete the keyring scrobble token"
    );
    CredentialStore::delete_scrobble_token().ok();
}

#[test]
fn scrobble_core_threshold_predicate_matches_module() {
    let dir = tempfile::tempdir().unwrap();
    let config = CoreConfig {
        data_dir: dir.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    };
    let core = LyrebirdCore::new(config).unwrap();
    // The FFI wrapper must agree with the pure function it delegates to.
    assert!(!core.scrobble_threshold_reached(89.0, 180.0));
    assert!(core.scrobble_threshold_reached(90.0, 180.0));
    assert!(core.scrobble_threshold_reached(240.0, 0.0));
}
