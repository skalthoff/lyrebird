use super::*;

// ---------------------------------------------------------------------------
// BATCH-24: typed enums / ItemsQuery / structured errors / UserItemData
// ---------------------------------------------------------------------------

#[tokio::test]
async fn items_query_builder_round_trips_through_server() {
    // End-to-end: a hand-built `ItemsQuery` should produce the same
    // server-facing request as the legacy per-endpoint methods. We check
    // for the critical query params and confirm the response maps to the
    // expected `PaginatedAlbums`.
    use crate::enums::{ItemField, ItemKind, ItemSortBy, SortOrder};
    use crate::query::ItemsQuery;

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
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a1", "Name": "Test Album", "Type": "MusicAlbum",
                    "AlbumArtist": "Test Artist",
                    "ProductionYear": 2024, "ChildCount": 10,
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = ItemsQuery::new()
        .recursive()
        .item_types(vec![ItemKind::MusicAlbum])
        .sort(ItemSortBy::SortName, SortOrder::Ascending)
        .limit(50)
        .offset(0)
        .fields(vec![ItemField::Genres, ItemField::ProductionYear])
        .fetch_albums(&client)
        .await
        .unwrap();

    assert_eq!(page.total_count, 1);
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].name, "Test Album");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
}

#[tokio::test]
async fn items_query_builder_clamps_zero_limit_to_one() {
    use crate::query::ItemsQuery;

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
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = ItemsQuery::new().limit(0).execute(&client).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("query");
    assert!(q.contains("Limit=1"), "expected clamped limit: {q}");
}

#[tokio::test]
async fn items_query_builder_requires_user_id() {
    // With no session AND no explicit `user_id`, `execute` must short-circuit
    // before any HTTP call with `NotAuthenticated`.
    use crate::query::ItemsQuery;

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = ItemsQuery::new().execute(&client).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn structured_error_auth_maps_401() {
    // A 401 on an authenticated library call goes through the silent
    // re-auth path in `send_with_retry_raw`; with no refresh callback
    // wired (and therefore no fresh keyring token to grab), the caller
    // sees [`LyrebirdError::AuthExpired`] rather than the raw `Auth(body)`.
    // The raw `Auth(_)` variant is still the target of `from_status` for
    // endpoints that bypass the retry layer — verified separately on
    // `from_status` directly.
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
        .respond_with(ResponseTemplate::new(401).set_body_string("unauthorized"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::AuthExpired),
        "expected AuthExpired for 401 on authenticated call, got {err:?}"
    );

    // And the raw mapping (`from_status`) still lands on `Auth(body)` —
    // which is what endpoints that bypass the retry layer will see.
    let raw = crate::error::LyrebirdError::from_status(401, "unauthorized".into(), None);
    assert!(
        matches!(raw, crate::error::LyrebirdError::Auth(_)),
        "from_status(401) must be Auth, got {raw:?}"
    );
}

#[tokio::test]
async fn structured_error_forbidden_maps_403() {
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
        .respond_with(ResponseTemplate::new(403).set_body_string("forbidden"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::Forbidden(_)),
        "expected Forbidden for 403, got {err:?}"
    );
}

// A retriable 429 drives the full MAX_ATTEMPTS loop, sleeping
// min(Retry-After=42, RETRY_AFTER_CAP=5) = 5s before each of the two retries —
// ~10s of real wall-clock if run on a live clock. We virtualize that backoff
// with the same pause-after-auth + manual advance/yield pump the heartbeat
// tests use (a bare `start_paused` auto-advances tokio's clock and fires
// reqwest's client timeout before wiremock's I/O completes; manual pause
// freezes time so in-flight requests finish during the yields). The `Some(42)`
// assertion is unaffected.
#[tokio::test]
async fn structured_error_rate_limit_parses_retry_after() {
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
        .respond_with(
            ResponseTemplate::new(429)
                .insert_header("Retry-After", "42")
                .set_body_string("slow down"),
        )
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    match err {
        crate::error::LyrebirdError::RateLimit { retry_after } => {
            assert_eq!(retry_after, Some(42));
        }
        other => panic!("expected RateLimit, got {other:?}"),
    }
}

#[tokio::test]
async fn structured_error_server_5xx_is_retryable() {
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
        .respond_with(ResponseTemplate::new(503).set_body_string("unavailable"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    match &err {
        crate::error::LyrebirdError::Server { status, .. } => assert_eq!(*status, 503),
        other => panic!("expected Server, got {other:?}"),
    }
    assert!(err.is_retryable(), "5xx must be retryable");
}

#[test]
fn structured_error_is_retryable_classification() {
    use crate::error::LyrebirdError;

    // Retryable: RateLimit, Network, Server 5xx.
    assert!(LyrebirdError::RateLimit { retry_after: None }.is_retryable());
    assert!(LyrebirdError::Network("boom".into()).is_retryable());
    assert!(LyrebirdError::Server {
        status: 500,
        body: "".into(),
    }
    .is_retryable());
    assert!(LyrebirdError::Server {
        status: 599,
        body: "".into(),
    }
    .is_retryable());

    // Not retryable: Auth, Forbidden, NotFound, Decode, InvalidInput,
    // NotAuthenticated, NoSession.
    assert!(!LyrebirdError::Auth("".into()).is_retryable());
    assert!(!LyrebirdError::Forbidden("".into()).is_retryable());
    assert!(!LyrebirdError::NotFound("".into()).is_retryable());
    assert!(!LyrebirdError::Decode("".into()).is_retryable());
    assert!(!LyrebirdError::InvalidInput("".into()).is_retryable());
    assert!(!LyrebirdError::NotAuthenticated.is_retryable());
    assert!(!LyrebirdError::NoSession.is_retryable());
    // A 4xx `Server` (unclassified) is NOT retryable — only 5xx is.
    assert!(!LyrebirdError::Server {
        status: 418,
        body: "".into(),
    }
    .is_retryable());

    // Consistency contract with client.rs `is_retriable_status`: 408 Request
    // Timeout IS retryable (even though not 5xx); 501 Not Implemented is NOT
    // (even though it is 5xx). The two classifiers must agree.
    assert!(
        LyrebirdError::Server {
            status: 408,
            body: "".into(),
        }
        .is_retryable(),
        "408 Request Timeout must be retryable (matches client.rs)"
    );
    assert!(
        !LyrebirdError::Server {
            status: 501,
            body: "".into(),
        }
        .is_retryable(),
        "501 Not Implemented must NOT be retryable (matches client.rs)"
    );
}

/// The user-facing message mapping (`user_message`) must give blank-credential
/// and certificate errors their own copy, not the generic session-expired /
/// network fallbacks they were previously lumped into.
#[test]
fn user_message_distinguishes_credentials_and_certificate() {
    use crate::error::LyrebirdError;

    // InvalidCredentials (blank login fields) is NOT a session-expiry.
    let cred = LyrebirdError::InvalidCredentials.user_message();
    assert!(
        cred.to_lowercase().contains("username") && cred.to_lowercase().contains("password"),
        "InvalidCredentials must prompt for username/password, got: {cred}"
    );
    assert_ne!(
        cred,
        LyrebirdError::AuthExpired.user_message(),
        "InvalidCredentials must not share the session-expired copy"
    );

    // SelfSignedCertificate names the host and hints at trusting it.
    let cert = LyrebirdError::SelfSignedCertificate {
        host: "music.example.com".into(),
    }
    .user_message();
    assert!(
        cert.contains("music.example.com"),
        "cert message must name the host, got: {cert}"
    );
    assert_ne!(
        cert,
        LyrebirdError::Network("x".into()).user_message(),
        "cert message must differ from the generic network message"
    );
}

/// The `RateLimit` Display string must render the `Option<u64>` cleanly (not
/// Rust debug `Some(30)` / `None`), since that string is the only thing the
/// flat-error FFI surfaces to the Swift presenter.
#[test]
fn rate_limit_display_formats_retry_after_cleanly() {
    use crate::error::LyrebirdError;

    let with = LyrebirdError::RateLimit {
        retry_after: Some(30),
    }
    .to_string();
    assert_eq!(with, "rate limited (retry after 30s)", "got: {with}");
    // No debug-formatted Option leaks.
    assert!(
        !with.contains("Some("),
        "must not debug-format the Option: {with}"
    );

    let without = LyrebirdError::RateLimit { retry_after: None }.to_string();
    assert_eq!(without, "rate limited", "got: {without}");
    assert!(!without.contains("None"), "must not render None: {without}");
}

#[test]
fn structured_error_from_status_dispatches_variants() {
    use crate::error::LyrebirdError;
    assert!(matches!(
        LyrebirdError::from_status(401, "".into(), None),
        LyrebirdError::Auth(_)
    ));
    assert!(matches!(
        LyrebirdError::from_status(403, "".into(), None),
        LyrebirdError::Forbidden(_)
    ));
    assert!(matches!(
        LyrebirdError::from_status(404, "".into(), None),
        LyrebirdError::NotFound(_)
    ));
    assert!(matches!(
        LyrebirdError::from_status(429, "".into(), Some(5)),
        LyrebirdError::RateLimit {
            retry_after: Some(5)
        }
    ));
    assert!(matches!(
        LyrebirdError::from_status(500, "".into(), None),
        LyrebirdError::Server { status: 500, .. }
    ));
    assert!(matches!(
        LyrebirdError::from_status(418, "".into(), None),
        LyrebirdError::Server { status: 418, .. }
    ));
}

#[tokio::test]
async fn user_item_data_round_trips_on_track() {
    // `Fields=UserData` on a `/Items` query should populate every field of
    // `Track::user_data` — this is the end-to-end path that feeds the Home
    // "Play It Again" row and the player's "resume from position" UI.
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
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Track", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Alb",
                    "AlbumArtist": "Ar", "Artists": ["Ar"],
                    "RunTimeTicks": 3000000000u64,
                    "UserData": {
                        "IsFavorite": true,
                        "Played": true,
                        "PlayCount": 9,
                        "PlaybackPositionTicks": 500000000i64,
                        "LastPlayedDate": "2025-02-03T04:05:06Z",
                        "Likes": true,
                        "Rating": 4.5
                    },
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.album_tracks("a1").await.unwrap();
    assert_eq!(tracks.len(), 1);
    let t = &tracks[0];
    let ud = t.user_data.as_ref().expect("user_data must be populated");
    assert!(ud.is_favorite);
    assert!(ud.played);
    assert_eq!(ud.play_count, 9);
    assert_eq!(ud.playback_position_ticks, 500_000_000);
    assert_eq!(ud.last_played_at.as_deref(), Some("2025-02-03T04:05:06Z"));
    assert_eq!(ud.likes, Some(true));
    assert_eq!(ud.rating, Some(4.5));

    // Legacy convenience fields on `Track` mirror the payload.
    assert!(t.is_favorite);
    assert_eq!(t.play_count, 9);
}

#[tokio::test]
async fn user_item_data_is_none_when_server_omits_it() {
    // When the server does not include `UserData` on the payload, the
    // track's `user_data` field should be `None` (not `Some(default)`).
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
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Track", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Alb",
                    "RunTimeTicks": 1000000000u64,
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.album_tracks("a1").await.unwrap();
    assert!(tracks[0].user_data.is_none(), "no UserData => no user_data");
    assert!(!tracks[0].is_favorite);
    assert_eq!(tracks[0].play_count, 0);
}

// ---------------------------------------------------------------------------
// is_cert_error positive branch — a CI-runnable unit test (the only prior
// positive coverage was an #[ignore]d live test against badssl.com). We can't
// fabricate a `reqwest::Error` with an arbitrary source offline, so the
// substring logic is factored into `error_chain_is_cert_failure`, which we
// drive here with a synthetic `std::io::Error` source chain whose inner
// message carries each matched rustls/webpki cert marker.
// ---------------------------------------------------------------------------

#[test]
fn error_chain_is_cert_failure_true_for_each_cert_marker() {
    use crate::error::error_chain_is_cert_failure;
    use std::error::Error as StdError;
    use std::fmt;
    use std::io;

    // An outer error that wraps an inner source, so the detector must walk the
    // chain (not just inspect the top-level message) to find the marker —
    // exactly the rustls-buried-in-reqwest shape in production.
    #[derive(Debug)]
    struct Outer(io::Error);
    impl fmt::Display for Outer {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "error sending request")
        }
    }
    impl StdError for Outer {
        fn source(&self) -> Option<&(dyn StdError + 'static)> {
            Some(&self.0)
        }
    }

    // Each marker the production detector keys on must drive a `true` result
    // when it appears anywhere in the source chain.
    for marker in [
        "invalid peer certificate: UnknownIssuer",
        "invalid certificate: expired",
        "certificate verify failed",
        "the chain has an UnknownIssuer",
        "self-signed certificate in certificate chain",
    ] {
        let err = Outer(io::Error::other(marker));
        assert!(
            error_chain_is_cert_failure(&err),
            "cert marker must be detected in the source chain: {marker}"
        );
    }
}

#[test]
fn error_chain_is_cert_failure_false_for_benign_transport_error() {
    use crate::error::error_chain_is_cert_failure;
    use std::io;

    // A plain connection-refused error must NOT be classified as a cert error.
    let err = io::Error::new(io::ErrorKind::ConnectionRefused, "connection refused");
    assert!(
        !error_chain_is_cert_failure(&err),
        "benign transport error must not match cert markers"
    );
}
