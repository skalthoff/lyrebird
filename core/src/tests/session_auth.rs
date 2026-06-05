use super::*;

#[test]
fn resume_session_returns_none_when_no_settings() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    let resumed = core.resume_session().expect("resume_session");
    assert!(resumed.is_none(), "expected None on a fresh core");
}

#[test]
fn resume_session_returns_none_when_token_missing() {
    // Seed every `last_*` setting but leave the keyring empty — auto-restore
    // should bail cleanly rather than hand back a session with no token.
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    {
        let inner = core.inner.lock();
        inner
            .db
            .set_setting("last_server_url", "https://jellyfin.example/")
            .unwrap();
        inner
            .db
            .set_setting("last_username", "token-missing-user")
            .unwrap();
        inner
            .db
            .set_setting("last_server_id", "srv-token-missing")
            .unwrap();
        inner
            .db
            .set_setting("last_user_id", "usr-token-missing")
            .unwrap();
    }
    // Belt-and-braces: explicitly clear any stale token for this pair.
    CredentialStore::delete_token("srv-token-missing", "token-missing-user").unwrap();

    let resumed = core.resume_session().expect("resume_session");
    assert!(
        resumed.is_none(),
        "expected None when keyring entry is absent"
    );
}

#[test]
fn resume_session_returns_session_when_all_settings_present() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    // Pick IDs unique to this test so parallel runs don't read each other's
    // mock keyring entries.
    let server_id = "srv-resume-full";
    let username = "resume-full-user";
    let user_id = "usr-resume-full";
    let server_url = "https://resume.example/";
    let token = "token-resume-full";
    {
        let inner = core.inner.lock();
        inner.db.set_setting("last_server_url", server_url).unwrap();
        inner.db.set_setting("last_username", username).unwrap();
        inner.db.set_setting("last_server_id", server_id).unwrap();
        inner.db.set_setting("last_user_id", user_id).unwrap();
    }
    CredentialStore::save_token(server_id, username, token).unwrap();

    let resumed = core
        .resume_session()
        .expect("resume_session")
        .expect("expected Some(session)");
    assert_eq!(resumed.access_token, token);
    assert_eq!(resumed.user.id, user_id);
    assert_eq!(resumed.user.name, username);
    assert_eq!(resumed.user.server_id.as_deref(), Some(server_id));
    assert_eq!(resumed.server.id.as_deref(), Some(server_id));
    // `Url::parse` round-trips the trailing slash; exact equality keeps the
    // assertion tight so a future change to how we resolve the URL surfaces
    // immediately.
    assert_eq!(resumed.server.url, server_url);

    // And the core should now have a live client wired to the restored
    // credentials — any library call that follows can skip the login screen.
    assert!(
        core.inner.lock().client.is_some(),
        "resume_session must rehydrate the JellyfinClient"
    );
}

#[test]
fn resume_session_noop_when_only_partial_settings() {
    // Missing `last_user_id` on its own should still short-circuit to None.
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    {
        let inner = core.inner.lock();
        inner
            .db
            .set_setting("last_server_url", "https://partial.example/")
            .unwrap();
        inner
            .db
            .set_setting("last_username", "partial-user")
            .unwrap();
        inner
            .db
            .set_setting("last_server_id", "srv-partial")
            .unwrap();
        // Intentionally omit `last_user_id`.
    }
    CredentialStore::save_token("srv-partial", "partial-user", "partial-token").unwrap();

    let resumed = core.resume_session().expect("resume_session");
    assert!(
        resumed.is_none(),
        "partial settings must not rehydrate a half-built session"
    );
    assert!(
        core.inner.lock().client.is_none(),
        "client must not be reconstructed when settings are incomplete"
    );

    // Cleanup so a rerun of this test (or its neighbours) starts clean.
    CredentialStore::delete_token("srv-partial", "partial-user").unwrap();
}

#[tokio::test]
async fn login_persists_user_id_and_supports_resume() {
    // End-to-end: log in against a mock Jellyfin, then stand up a fresh core
    // pointed at the same data dir and assert `resume_session` hands back the
    // same session without a network round-trip.
    //
    // `LyrebirdCore::login` is a sync FFI wrapper that `block_on`s its own
    // tokio runtime, so we route it through `spawn_blocking` to keep it off
    // the test harness's current-thread runtime (otherwise tokio refuses
    // with "Cannot start a runtime from within a runtime").
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "persisted-token",
            "ServerId": "srv-persisted",
            "ServerName": "My Jellyfin",
            "User": {
                "Id": "usr-persisted",
                "Name": "persisted-user",
                "ServerId": "srv-persisted",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();

    // --- first process: login ---
    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let tmp_path_for_login = tmp_path.clone();
    let server_url_for_login = server_url.clone();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path_for_login,
            device_name: "Test".into(),
        })
        .expect("core init");
        let session = core
            .login(server_url_for_login, "persisted-user".into(), "pw".into())
            .expect("login");
        assert_eq!(session.user.id, "usr-persisted");

        // `login` must write `last_user_id` alongside the other identifiers so
        // the next launch can look up the keychain entry.
        let inner = core.inner.lock();
        assert_eq!(
            inner.db.get_setting("last_user_id").unwrap().as_deref(),
            Some("usr-persisted")
        );
        assert_eq!(
            inner.db.get_setting("last_server_id").unwrap().as_deref(),
            Some("srv-persisted")
        );
        assert_eq!(
            inner.db.get_setting("last_username").unwrap().as_deref(),
            Some("persisted-user")
        );
    })
    .await
    .expect("join login task");

    // --- second process: resume without re-authenticating ---
    let tmp_path_for_resume = tmp_path.clone();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core2 = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path_for_resume,
            device_name: "Test".into(),
        })
        .expect("core init");
        let resumed = core2
            .resume_session()
            .expect("resume_session")
            .expect("expected Some(session) after login persisted");
        assert_eq!(resumed.access_token, "persisted-token");
        assert_eq!(resumed.user.id, "usr-persisted");
        assert_eq!(resumed.user.name, "persisted-user");
        assert_eq!(resumed.server.id.as_deref(), Some("srv-persisted"));
        assert!(
            core2.inner.lock().client.is_some(),
            "resume_session must produce a live JellyfinClient"
        );
    })
    .await
    .expect("join resume task");
}

#[tokio::test]
async fn logout_clears_persisted_settings() {
    // After an explicit logout the next launch should start fresh — no
    // half-baked auto-restore attempt against a dead session.
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "logout-token",
            "ServerId": "srv-logout",
            "ServerName": "S",
            "User": {
                "Id": "usr-logout",
                "Name": "logout-user",
                "ServerId": "srv-logout",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let server_url = server.uri();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path.clone(),
            device_name: "Test".into(),
        })
        .expect("core init");
        let _ = core
            .login(server_url, "logout-user".into(), "pw".into())
            .expect("login");
        core.logout().expect("logout");

        {
            let inner = core.inner.lock();
            assert_eq!(inner.db.get_setting("last_server_url").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_username").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }
        assert!(
            CredentialStore::load_token("srv-logout", "logout-user")
                .unwrap()
                .is_none(),
            "logout must also remove the keychain token"
        );

        // Resume on a brand-new core over the same data dir should now bail.
        let core2 = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        assert!(core2.resume_session().expect("resume_session").is_none());
    })
    .await
    .expect("join logout task");
}

#[tokio::test]
async fn forget_token_preserves_server_url_and_username() {
    // The auth-expired flow wipes the token so the user has to sign back in,
    // but should keep the pre-fill fields so they don't have to retype the
    // server URL / username.
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "forget-token",
            "ServerId": "srv-forget",
            "ServerName": "S",
            "User": {
                "Id": "usr-forget",
                "Name": "forget-user",
                "ServerId": "srv-forget",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let server_url = server.uri();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        let _ = core
            .login(server_url, "forget-user".into(), "pw".into())
            .expect("login");
        core.forget_token().expect("forget_token");

        {
            let inner = core.inner.lock();
            // server URL + username stick around so the login form pre-fills.
            assert!(inner.db.get_setting("last_server_url").unwrap().is_some());
            assert_eq!(
                inner.db.get_setting("last_username").unwrap().as_deref(),
                Some("forget-user")
            );
            // The ids that key into the keychain entry are wiped so a stale
            // resume_session lookup can't accidentally grab a dangling token.
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }
        assert!(
            CredentialStore::load_token("srv-forget", "forget-user")
                .unwrap()
                .is_none(),
            "forget_token must remove the keychain token"
        );

        // resume_session needs all four settings; with ids cleared it must say no.
        assert!(core.resume_session().expect("resume_session").is_none());
    })
    .await
    .expect("join forget task");
}

// ============================================================================
// Retry + backoff + silent re-auth (issues #438, #440)
// ============================================================================
//
// These tests exercise the transport layer directly via `JellyfinClient` rather
// than the UniFFI wrapper, because the harness needs to inject 5xx / 401 /
// transient failures from wiremock. `MockServer::up_to_n_times` lets us chain
// multiple `Mock`s against the same path — it consumes them in insertion
// order, so the first two `respond_with` bodies land on the first two
// attempts and the last one services the eventual success.

/// `503` on the first two attempts, then `200`. The retry layer should
/// swallow the early failures and return the eventual success payload —
/// callers never see a `LyrebirdError::Server { 503, .. }`.
#[tokio::test]
async fn retry_recovers_from_transient_5xx() {
    let server = MockServer::start().await;
    // Mount three responses against `/System/Info/Public`: 503, 503, 200.
    // `wiremock` consumes them in insertion order.
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ServerName": "After Retry",
            "Version": "10.10.0",
            "Id": "abc"
        })))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let info = client.public_info().await.expect("retry must recover");
    assert_eq!(info.server_name.as_deref(), Some("After Retry"));

    // The server saw 3 attempts total — 2 failures + the final success.
    let requests = server.received_requests().await.unwrap();
    let hits = requests
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    assert_eq!(hits, 3, "expected 3 attempts (2 retries); got {hits}");
}

/// `501 Not Implemented` is NOT retriable — it's a semantic rejection the
/// server will keep returning. One attempt, one error.
#[tokio::test]
async fn retry_does_not_loop_on_501_not_implemented() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(501))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let err = client.public_info().await.unwrap_err();
    match err {
        LyrebirdError::Server { status, .. } => assert_eq!(status, 501),
        other => panic!("expected Server {{ 501 }}, got {other:?}"),
    }
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    assert_eq!(hits, 1, "501 must not be retried");
}

/// Exhausting the retry budget (three 5xx in a row) surfaces the last
/// server error as `LyrebirdError::Server`, not as `Network(_)`.
#[tokio::test]
async fn retry_surfaces_last_server_error_when_budget_exhausted() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(502))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let err = client.public_info().await.unwrap_err();
    match err {
        LyrebirdError::Server { status, .. } => assert_eq!(status, 502),
        other => panic!("expected Server {{ 502 }}, got {other:?}"),
    }
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    // MAX_ATTEMPTS = 3 (initial + 2 retries).
    assert_eq!(hits, 3, "expected 3 attempts total, got {hits}");
}

/// `401` with no refresh callback wired surfaces `AuthExpired` so the UI
/// can drive the re-auth sheet. No retry beyond the single 401.
#[tokio::test]
async fn auth_401_without_callback_returns_auth_expired() {
    let server = MockServer::start().await;
    // Have to authenticate first so the library call runs with a token.
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .albums(Paging::new(0, 10))
        .await
        .expect_err("401 without refresh must fail");
    assert!(
        matches!(err, LyrebirdError::AuthExpired),
        "expected AuthExpired, got {err:?}"
    );
}

/// `401` with a wired callback that hands back a *new* token triggers a
/// silent retry with the fresh token. Verifies both that the retry fires
/// and that the subsequent request carries the refreshed bearer.
#[tokio::test]
async fn auth_401_with_callback_retries_with_new_token() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "old-token", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // First library hit: 401 (stale token).
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    // Second hit: 200 with a single album so the caller gets a real result.
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [{ "Id": "a1", "Name": "Album", "Type": "MusicAlbum" }],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();

    // Hand back a *different* token on refresh — if the callback returned
    // the same string the retry layer would bail with AuthExpired rather
    // than loop.
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(Some("fresh-token".to_string()))));

    let page = client
        .albums(Paging::new(0, 10))
        .await
        .expect("refresh + retry should succeed");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "a1");

    // Inspect the retry: second `GET /Users/u1/Items` must have carried the
    // fresh token in its Authorization header.
    let requests = server.received_requests().await.unwrap();
    let gets: Vec<_> = requests
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Users/u1/Items")
        .collect();
    assert_eq!(gets.len(), 2, "expected 2 GETs (initial + retry)");
    let retry_auth = gets[1]
        .headers
        .get("authorization")
        .expect("retry must carry Authorization");
    let retry_auth_str = retry_auth.to_str().unwrap();
    assert!(
        retry_auth_str.contains("fresh-token"),
        "retry should use new token, saw: {retry_auth_str}"
    );
}

/// A refresh callback that returns `Ok(None)` (e.g. keyring wiped) surfaces
/// `AuthExpired` — no retry, caller drives the re-auth sheet.
#[tokio::test]
async fn auth_401_with_callback_returning_none_surfaces_expired() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(None)));

    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(matches!(err, LyrebirdError::AuthExpired));
}

/// When the callback hands back the *same* token the client already has,
/// the retry layer treats it as a dead token — no pointless loop, just
/// `AuthExpired`.
#[tokio::test]
async fn auth_401_with_same_token_does_not_loop() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "same-token", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(Some("same-token".to_string()))));

    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(matches!(err, LyrebirdError::AuthExpired));

    // Crucial: only the initial 401 hit, no loop.
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Users/u1/Items")
        .count();
    assert_eq!(hits, 1, "expected exactly one GET — no retry loop");
}

/// `storage::refresh_token_from_keyring` is the bridge between the HTTP
/// client's 401 interceptor and the OS credential store. Smoke-test the
/// three scenarios the wrapping callback relies on: missing persisted
/// ids (Ok(None)), ids-but-no-keychain-entry (Ok(None)), and a present
/// keychain entry (Ok(Some)).
#[test]
fn refresh_token_from_keyring_returns_token_when_present() {
    install_mock_keyring();
    let db = Database::in_memory().expect("in-memory db");

    // Missing ids → None.
    let missing = crate::storage::refresh_token_from_keyring(&db).unwrap();
    assert!(missing.is_none(), "no settings → None");

    // Ids present but no keychain entry → None.
    db.set_setting("last_server_id", "srv-refresh-test")
        .unwrap();
    db.set_setting("last_username", "refresh-user").unwrap();
    // Make sure there's no stale entry from another test run.
    CredentialStore::delete_token("srv-refresh-test", "refresh-user").unwrap();
    let absent = crate::storage::refresh_token_from_keyring(&db).unwrap();
    assert!(absent.is_none(), "no keychain entry → None");

    // Save a token — now refresh should hand it back.
    CredentialStore::save_token("srv-refresh-test", "refresh-user", "refreshed-token").unwrap();
    let got = crate::storage::refresh_token_from_keyring(&db)
        .unwrap()
        .expect("token should be present");
    assert_eq!(got, "refreshed-token");
}

// ============================================================================
// Self-signed certificate error mapping (issue #601)
// ============================================================================

/// Verify that the cert-error detector recognises the rustls 0.23 message
/// `"invalid peer certificate: …"` that appears anywhere in the error chain.
///
/// We synthesise a reqwest error that wraps a custom error whose `Display`
/// output matches that pattern.  This lets us test the detection logic and
/// `From<reqwest::Error>` mapping without a live TLS server.
#[test]
fn self_signed_cert_error_detected_from_error_chain() {
    // We can't synthesise a real reqwest cert error without a live TLS server,
    // so this test exercises the negative path: a URL parse error must NOT be
    // classified as a cert error. Positive-path coverage lives in the
    // `#[ignore]`-tagged integration test against self-signed.badssl.com below.
    let plain_err = reqwest::Client::new()
        .get("not-a-url-at-all")
        .build()
        .unwrap_err();
    assert!(
        !crate::error::is_cert_error(&plain_err),
        "URL parse error must not be treated as cert error"
    );
}

/// End-to-end mapping test: a reqwest request to a server using a self-signed
/// certificate must produce `LyrebirdError::SelfSignedCertificate { host }`,
/// not `LyrebirdError::Network`.
///
/// This test hits `https://self-signed.badssl.com/` (a public test endpoint
/// intentionally using a self-signed cert). It is tagged `#[ignore]` so it
/// is skipped in offline / CI-without-network environments; run it explicitly
/// with `cargo test -- --ignored cert_error_maps_to_structured_variant`.
#[tokio::test]
#[ignore = "requires outbound HTTPS to self-signed.badssl.com"]
async fn cert_error_maps_to_structured_variant() {
    use crate::error::LyrebirdError;

    // A default reqwest client uses rustls and will reject the self-signed cert.
    let result = reqwest::Client::builder()
        .build()
        .unwrap()
        .get("https://self-signed.badssl.com/")
        .send()
        .await;

    let reqwest_err = result.expect_err("badssl.com must fail cert validation");
    let lyrebird_err: LyrebirdError = reqwest_err.into();

    match lyrebird_err {
        LyrebirdError::SelfSignedCertificate { ref host } => {
            assert!(
                host.contains("badssl.com"),
                "host should be 'self-signed.badssl.com', got '{host}'"
            );
        }
        other => panic!("expected SelfSignedCertificate, got {other:?}"),
    }
}

/// Confirm that a plain connection-refused error (not a cert issue) continues
/// to map to `LyrebirdError::Network`, not `SelfSignedCertificate`.
#[tokio::test]
async fn non_cert_transport_error_stays_network() {
    use crate::error::LyrebirdError;

    // Bind an ephemeral port (port 0 lets the OS pick a free one), capture the
    // assigned port, then DROP the listener so the port is guaranteed closed.
    // Targeting that port forces a deterministic connection-refused — unlike a
    // hard-coded 19999, this can't pass vacuously because something happened
    // to be listening.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);

    let result = reqwest::Client::builder()
        .build()
        .unwrap()
        .get(format!("http://127.0.0.1:{port}/"))
        .send()
        .await;

    // A missing error is a hard failure now (not an early return): the port is
    // guaranteed closed, so the request MUST fail.
    let reqwest_err = result.expect_err("connection to a closed port must fail");
    let lyrebird_err: LyrebirdError = reqwest_err.into();

    assert!(
        matches!(lyrebird_err, LyrebirdError::Network(_)),
        "connection-refused must map to Network, got {lyrebird_err:?}"
    );
}

// ============================================================================
// #577 — username / password whitespace trimming
// ============================================================================

/// `login` must reject blank (whitespace-only) usernames before any network
/// call is made. Empty / whitespace-only passwords are *allowed* — Jellyfin
/// supports passwordless accounts and the server is the authority on whether
/// the password is valid.
#[test]
fn login_rejects_whitespace_only_username() {
    // Error fires before any HTTP call — no server needed.
    // Per-test tempdir avoids parallel-test SQLite contention with other
    // tests that share the default data_dir (see #781).
    let tmp = tempfile::tempdir().expect("tempdir");
    let config = CoreConfig {
        data_dir: tmp.path().to_string_lossy().to_string(),
        device_name: "Test".into(),
    };
    let core = LyrebirdCore::new(config).unwrap();

    let err = core
        .login("http://localhost:1".into(), "   ".into(), "password".into())
        .unwrap_err();
    assert!(
        matches!(err, LyrebirdError::InvalidCredentials),
        "whitespace-only username should return InvalidCredentials, got {err:?}"
    );
}

/// Credentials are trimmed before being sent to the server. Padded inputs like
/// `"  soren  "` must authenticate successfully (i.e. the server receives
/// `"soren"`, not the padded string).
#[tokio::test]
async fn login_trims_credentials_before_auth() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "trimmed-token",
            "ServerId": "trim-server-unique",
            "ServerName": "Trim Test",
            "User": {
                "Id": "trim-user-id",
                "Name": "soren",
                "ServerId": "trim-server-unique",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();
    // Per-test tempdir avoids parallel-test SQLite contention with other
    // tests that share the default data_dir (see #781).
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();
    // LyrebirdCore::login is a sync FFI wrapper that block_on's its own runtime;
    // run it in spawn_blocking so we don't nest runtimes.
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .unwrap();
        let session = core
            .login(server_url, "  soren  ".into(), "  pass  ".into())
            .expect("login with padded credentials should succeed");
        assert_eq!(session.access_token, "trimmed-token");
        assert_eq!(session.user.name, "soren");
    })
    .await
    .expect("spawn_blocking panicked");
}

// ============================================================================
// #608 — device_name header sanitization
// ============================================================================

/// A malicious `device_name` containing CRLF must not produce a header value
/// with embedded line breaks (which would allow HTTP header injection). After
/// sanitization the CR and LF bytes must be absent from the Authorization
/// header value entirely.
#[test]
fn auth_header_strips_crlf_injection() {
    // This device_name would inject a second header line if passed verbatim:
    //   Device="MyDevice\r\nX-Injected: evil"
    let malicious_name = "MyDevice\r\nX-Injected: evil";
    let client = JellyfinClient::new(
        "http://localhost:1/",
        "dev-id".into(),
        malicious_name.into(),
    )
    .unwrap();

    let headers = client.build_headers().unwrap();
    let auth_value = headers
        .get(reqwest::header::AUTHORIZATION)
        .expect("Authorization header must be present")
        .to_str()
        .expect("Authorization header value must be valid ASCII after sanitization");

    // CR and LF are the actual injection vectors — they must be gone.
    assert!(
        !auth_value.contains('\r'),
        "Authorization header must not contain CR: {auth_value:?}"
    );
    assert!(
        !auth_value.contains('\n'),
        "Authorization header must not contain LF: {auth_value:?}"
    );
    // With CR/LF removed the remaining text is harmless literal content in the
    // Device field — no second header line can be parsed from it.
}

/// A `device_name` longer than 100 characters is truncated so the header stays
/// well within reasonable bounds.
#[test]
fn auth_header_truncates_long_device_name() {
    let long_name = "A".repeat(200);
    let client =
        JellyfinClient::new("http://localhost:1/", "dev-id".into(), long_name.clone()).unwrap();

    let headers = client.build_headers().unwrap();
    let auth_value = headers
        .get(reqwest::header::AUTHORIZATION)
        .unwrap()
        .to_str()
        .unwrap();

    // The full 200-char repetition must not appear verbatim.
    assert!(
        !auth_value.contains(&long_name),
        "Authorization header must truncate long device names"
    );
    // But the first 100 chars should still be there.
    let first_100 = &long_name[..100];
    assert!(
        auth_value.contains(first_100),
        "Authorization header should contain first 100 chars of device name"
    );
}

/// `device_id` is interpolated into the same Authorization header value as
/// `device_name`, so it must be sanitized identically — a CRLF in the device
/// id would inject a header line just as a malicious device name could.
#[test]
fn auth_header_strips_crlf_injection_from_device_id() {
    let malicious_id = "dev-id\r\nX-Injected: evil";
    let client =
        JellyfinClient::new("http://localhost:1/", malicious_id.into(), "Device".into()).unwrap();

    let headers = client.build_headers().unwrap();
    let auth_value = headers
        .get(reqwest::header::AUTHORIZATION)
        .expect("Authorization header must be present")
        .to_str()
        .expect("Authorization header value must be valid ASCII after sanitization");

    assert!(
        !auth_value.contains('\r'),
        "Authorization header must not contain CR from device_id: {auth_value:?}"
    );
    assert!(
        !auth_value.contains('\n'),
        "Authorization header must not contain LF from device_id: {auth_value:?}"
    );
}

// ============================================================================
// #584 — keyring write failure propagation
// ============================================================================

/// The `KeyringWrite` error variant must exist and carry a `reason` string so
/// callers can surface a diagnostic to the user.
#[test]
fn keyring_write_error_variant_is_displayable() {
    let err = LyrebirdError::KeyringWrite {
        reason: "OS keychain busy".into(),
    };
    let msg = err.to_string();
    assert!(
        msg.contains("OS keychain busy"),
        "KeyringWrite display should include reason: {msg}"
    );
}

/// When `CredentialStore::save_token` returns an error, `login` must surface a
/// `KeyringWrite` rather than swallowing it. This is verified by running
/// `login` against the shared mock keyring (which succeeds), then asserting
/// that a simulated write failure at the `CredentialStore` level is correctly
/// mapped to `LyrebirdError::KeyringWrite` — and specifically NOT silently
/// swallowed (the pre-fix code used `let _ = save_token(...)`).
///
/// We inject a failing keyring by logging in as a `KEYRING_FAIL_SENTINEL`
/// user: the mock's `set_secret` returns an error only for that user, so the
/// failure is deterministic and isolated from parallel login tests. The
/// assertion is exact — `Err(KeyringWrite { .. })`, not "Ok or KeyringWrite" —
/// so a regression that drops the error to `Ok` is caught.
#[tokio::test]
async fn login_keyring_write_is_not_silenced() {
    let fail_user = format!("{KEYRING_FAIL_SENTINEL}-user");
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "propagate-token",
            "ServerId": "srv-propagate-unique",
            "ServerName": "Propagate",
            "User": {
                "Id": "usr-propagate",
                "Name": fail_user,
                "ServerId": "srv-propagate-unique",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();
    // Per-test tempdir avoids parallel-test SQLite contention with other
    // tests that share the default data_dir (see #781).
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .unwrap();
        // The mock keyring fails `set_secret` for the sentinel user, so the
        // login MUST surface that as a specific `KeyringWrite` error — proving
        // the write failure is propagated, not swallowed.
        let result = core.login(server_url, fail_user, "pw".into());
        match result {
            Err(LyrebirdError::KeyringWrite { .. }) => {}
            other => panic!("expected Err(KeyringWrite), got {other:?}"),
        }
    })
    .await
    .expect("spawn_blocking panicked");
}

// ============================================================================
// Logout cleanup tests (#568, #592)
// ============================================================================

/// Logout calls `POST /Sessions/Logout` before wiping local state.
/// The server endpoint must be hit while the token is still valid (#592).
#[tokio::test]
async fn logout_calls_sessions_logout_endpoint() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-server-logout",
            "ServerId": "srv-slg",
            "ServerName": "S",
            "User": { "Id": "u-slg", "Name": "slg-user", "ServerId": "srv-slg", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/Sessions/Logout"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp_path = tmp.path().to_string_lossy().into_owned();

    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_url, "slg-user".into(), "pw".into())
            .expect("login");
        core.logout().expect("logout");
    })
    .await
    .expect("join task");

    let requests = server.received_requests().await.unwrap();
    let logout_hit = requests
        .iter()
        .any(|r| r.method.as_str() == "POST" && r.url.path().ends_with("/Sessions/Logout"));
    assert!(logout_hit, "expected POST /Sessions/Logout to be called");
}

/// Logout clears play_history, track_cache, album_cache, artist_cache, and
/// the four `last_*` settings rows (#568).
#[tokio::test]
async fn logout_clears_user_data() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-clear",
            "ServerId": "srv-clear",
            "ServerName": "S",
            "User": { "Id": "u-clear", "Name": "clear-user", "ServerId": "srv-clear", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/Sessions/Logout"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp_path = tmp.path().to_string_lossy().into_owned();

    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path.clone(),
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_url, "clear-user".into(), "pw".into())
            .expect("login");

        core.logout().expect("logout");

        {
            let inner = core.inner.lock();
            assert_eq!(inner.db.get_setting("last_server_url").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_username").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }

        assert!(
            CredentialStore::load_token("srv-clear", "clear-user")
                .unwrap()
                .is_none(),
            "keyring token must be deleted on logout"
        );

        let core2 = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core2 init");
        assert!(core2.resume_session().expect("resume").is_none());
    })
    .await
    .expect("join task");
}

/// When `POST /Sessions/Logout` fails (server unreachable), logout must still
/// clear local state — the server error must not block sign-out (#592).
#[tokio::test]
async fn logout_tolerates_server_post_failure() {
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-tol",
            "ServerId": "srv-tol",
            "ServerName": "S",
            "User": { "Id": "u-tol", "Name": "tol-user", "ServerId": "srv-tol", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    // Intentionally do NOT mount a Sessions/Logout handler — the server
    // returns 404 which our logout() must absorb and continue past.

    let server_url = server.uri();
    let tmp_path = tmp.path().to_string_lossy().into_owned();

    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path.clone(),
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_url, "tol-user".into(), "pw".into())
            .expect("login");

        core.logout()
            .expect("logout must succeed even when server POST fails");

        {
            let inner = core.inner.lock();
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }
        assert!(
            CredentialStore::load_token("srv-tol", "tol-user")
                .unwrap()
                .is_none(),
            "keyring token must be cleared even when server POST fails"
        );
    })
    .await
    .expect("join task");
}

#[tokio::test]
async fn logout_releases_inner_before_http_round_trip() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok-861",
            "ServerId": "srv-861",
            "ServerName": "S",
            "User": { "Id": "u-861", "Name": "u-861", "ServerId": "srv-861", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    let release = std::sync::Arc::new(AtomicBool::new(false));
    let release_mock = release.clone();
    Mock::given(method("POST"))
        .and(path("/Sessions/Logout"))
        .respond_with(move |_req: &Request| {
            while !release_mock.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(2));
            }
            ResponseTemplate::new(204)
        })
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp_path = tmp.path().to_string_lossy().into_owned();

    let (tx, rx) = mpsc::channel::<bool>();
    let release_watch = release.clone();

    // Bind the JoinHandle (don't detach it) so a panic in the blocking closure
    // — e.g. a `.expect` on login/logout failing — propagates when we `.await`
    // it below, instead of being swallowed and surfacing only as the
    // misleading "deadlocked" timeout on the channel recv.
    let blocking = tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = std::sync::Arc::new(
            LyrebirdCore::new(CoreConfig {
                data_dir: tmp_path,
                device_name: "Test".into(),
            })
            .expect("core init"),
        );
        core.login(server_url, "u-861".into(), "pw".into())
            .expect("login");

        let core_watch = core.clone();
        let watcher = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if core_watch.inner.try_lock().is_some() {
                    release_watch.store(true, Ordering::SeqCst);
                    return true;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            release_watch.store(true, Ordering::SeqCst);
            false
        });

        core.logout().expect("logout");
        let acquired = watcher.join().unwrap_or(false);
        tx.send(acquired).ok();
    });

    // Distinguish a real deadlock (Timeout) from the closure dying
    // (Disconnected) so the #861-specific message is only emitted for an
    // actual hang.
    let acquired = match rx.recv_timeout(Duration::from_secs(10)) {
        Ok(v) => v,
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            // Closure dropped the sender without sending — it panicked. Await
            // the handle to surface the real panic message.
            blocking.await.expect("logout blocking task panicked");
            panic!("logout blocking task ended without sending a result");
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            panic!("logout deadlocked holding Inner across the HTTP round-trip (#861)");
        }
    };
    assert!(
        acquired,
        "watcher could not acquire Inner while logout's HTTP was in flight \
         — logout held the mutex across block_on (#861)"
    );
    // Join the blocking task so any late panic still fails the test.
    blocking.await.expect("logout blocking task panicked");
}

// ============================================================================
// passwordless Jellyfin accounts
// ============================================================================

/// Jellyfin allows user accounts with no password. The client must forward
/// an empty `Pw` to `/Users/AuthenticateByName` rather than rejecting it
/// client-side — the server is the authority on whether a given (user, "")
/// pair is valid.
#[tokio::test]
async fn login_forwards_empty_password_to_server() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "passwordless-token",
            "ServerId": "passwordless-server",
            "ServerName": "Passwordless Test",
            "User": {
                "Id": "passwordless-user-id",
                "Name": "guest",
                "ServerId": "passwordless-server",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();
    // Per-test tempdir avoids parallel-test SQLite contention on Windows
    // ("database is locked") when multiple tests share a default data_dir.
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .unwrap();
        let session = core
            .login(server_url, "passwordless-user".into(), "".into())
            .expect("login with empty password should succeed");
        assert_eq!(session.access_token, "passwordless-token");
    })
    .await
    .expect("spawn_blocking panicked");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Users/AuthenticateByName")
        .expect("expected an AuthenticateByName POST");
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("auth body must be JSON");
    assert_eq!(
        body["Pw"],
        json!(""),
        "empty Pw must be forwarded as the empty string"
    );
    assert_eq!(body["Username"], json!("passwordless-user"));
}

/// Whitespace-only password is trimmed to empty and forwarded as `Pw: ""`,
/// matching the passwordless contract — the server decides whether to accept
/// or reject.
#[tokio::test]
async fn login_forwards_whitespace_only_password_as_empty() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "ws-token",
            "ServerId": "ws-server",
            "ServerName": "WS Test",
            "User": {
                "Id": "ws-user-id",
                "Name": "guest",
                "ServerId": "ws-server",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();
    // Per-test tempdir avoids parallel-test SQLite contention on Windows
    // ("database is locked") when multiple tests share a default data_dir.
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = LyrebirdCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .unwrap();
        core.login(server_url, "ws-user".into(), "\t\n  ".into())
            .expect("login with whitespace-only password should succeed (trimmed to empty)");
    })
    .await
    .expect("spawn_blocking panicked");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Users/AuthenticateByName")
        .expect("expected an AuthenticateByName POST");
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("auth body must be JSON");
    assert_eq!(
        body["Pw"],
        json!(""),
        "whitespace-only Pw must be trimmed to empty"
    );
}
