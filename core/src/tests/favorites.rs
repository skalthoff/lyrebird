use super::*;

#[tokio::test]
async fn set_favorite_uses_preferred_endpoint_and_returns_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Preferred route: user inferred from token, body returns UserItemData.
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.set_favorite("item-xyz").await.unwrap();
    assert!(state.is_favorite);
    assert_eq!(state.play_count, Some(0));
    assert!(state.last_played.is_none());

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz")
        .expect("expected POST to preferred favorite endpoint");
    // No body is sent for this endpoint.
    assert!(
        post.body.is_empty(),
        "expected empty body, got {:?}",
        post.body
    );
    // Client must not hit the legacy route when the preferred one succeeds.
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/FavoriteItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn unset_favorite_uses_preferred_endpoint_and_returns_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 2,
            "LastPlayedDate": "2025-01-02T03:04:05Z"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.unset_favorite("item-xyz").await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(2));
    assert_eq!(state.last_played.as_deref(), Some("2025-01-02T03:04:05Z"));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE"
                && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected DELETE to /UserFavoriteItems/item-xyz"
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/FavoriteItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn set_favorite_falls_back_to_legacy_route_on_404() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Older servers respond 404 to /UserFavoriteItems/...
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;
    // ...so the client must retry the legacy route.
    Mock::given(method("POST"))
        .and(path("/Users/u1/FavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 5,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.set_favorite("item-xyz").await.unwrap();
    assert!(state.is_favorite);
    assert_eq!(state.play_count, Some(5));

    // Assert ORDER, not just presence: the preferred route must be hit
    // *before* the legacy route, proving the legacy call is a fallback from
    // the 404 rather than an unordered coincidence.
    let requests = server.received_requests().await.unwrap();
    let fav_paths: Vec<&str> = requests
        .iter()
        .filter(|r| r.method.as_str() == "POST")
        .map(|r| r.url.path())
        .filter(|p| *p == "/UserFavoriteItems/item-xyz" || *p == "/Users/u1/FavoriteItems/item-xyz")
        .collect();
    assert_eq!(
        fav_paths,
        vec![
            "/UserFavoriteItems/item-xyz",
            "/Users/u1/FavoriteItems/item-xyz",
        ],
        "preferred route must be tried first, then the legacy fallback"
    );
}

#[tokio::test]
async fn unset_favorite_falls_back_to_legacy_route_on_405() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(405))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/Users/u1/FavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 1,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.unset_favorite("item-xyz").await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(1));

    // Assert ORDER, not just presence (see set_favorite test above).
    let requests = server.received_requests().await.unwrap();
    let fav_paths: Vec<&str> = requests
        .iter()
        .filter(|r| r.method.as_str() == "DELETE")
        .map(|r| r.url.path())
        .filter(|p| *p == "/UserFavoriteItems/item-xyz" || *p == "/Users/u1/FavoriteItems/item-xyz")
        .collect();
    assert_eq!(
        fav_paths,
        vec![
            "/UserFavoriteItems/item-xyz",
            "/Users/u1/FavoriteItems/item-xyz",
        ],
        "preferred route must be tried first, then the legacy fallback after 405"
    );
}

#[tokio::test]
async fn set_favorite_without_session_returns_not_authenticated() {
    // No MockServer routes registered: the guard must short-circuit before any
    // HTTP call. Pointing at a live MockServer means a regression would surface
    // as an unmatched-route error instead of silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.set_favorite("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn unset_favorite_without_session_returns_not_authenticated() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.unset_favorite("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn toggle_favorite_dispatches_to_set_when_true() {
    // `toggle_favorite(_, true)` must use POST (matching set_favorite), not
    // DELETE — otherwise a macOS `likeCommand` tap would unfavorite on a
    // track whose state is already "not favorited" (the target state).
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.toggle_favorite("item-xyz", true).await.unwrap();
    assert!(state.is_favorite);

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected POST to /UserFavoriteItems on toggle_favorite(true)"
    );
    assert!(
        !requests.iter().any(|r| r.method.as_str() == "DELETE"),
        "toggle_favorite(true) must not issue a DELETE"
    );
}

#[tokio::test]
async fn toggle_favorite_dispatches_to_unset_when_false() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 3,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.toggle_favorite("item-xyz", false).await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(3));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.iter().any(|r| r.method.as_str() == "DELETE"
            && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected DELETE to /UserFavoriteItems on toggle_favorite(false)"
    );
    // Auth is also a POST — we only care that we don't hit the favorite
    // endpoint with POST.
    assert!(
        !requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "toggle_favorite(false) must not issue a POST to the favorite endpoint"
    );
}

// ============================================================================
// mark_played / mark_unplayed (#133)
// Mirrors the favorite-endpoint test shape: preferred /UserPlayedItems route
// for new servers, legacy /Users/{userId}/PlayedItems fallback for old ones,
// and an auth-required guard before any HTTP traffic.
// ============================================================================

#[tokio::test]
async fn mark_played_uses_preferred_endpoint_and_returns_user_data() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/UserPlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "Played": true,
            "PlayCount": 3,
            "PlaybackPositionTicks": 0,
            "LastPlayedDate": "2026-04-25T18:00:00Z"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.mark_played("track-abc").await.unwrap();
    assert!(state.played);
    assert_eq!(state.play_count, 3);
    assert_eq!(
        state.last_played_at.as_deref(),
        Some("2026-04-25T18:00:00Z")
    );

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/UserPlayedItems/track-abc")
        .expect("expected POST to preferred played endpoint");
    assert!(
        post.body.is_empty(),
        "expected empty body, got {:?}",
        post.body
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/PlayedItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn mark_unplayed_uses_preferred_endpoint_and_returns_user_data() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserPlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "Played": false,
            "PlayCount": 0,
            "PlaybackPositionTicks": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.mark_unplayed("track-abc").await.unwrap();
    assert!(!state.played);
    assert_eq!(state.play_count, 0);
    assert!(state.last_played_at.is_none());

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE" && r.url.path() == "/UserPlayedItems/track-abc"),
        "expected DELETE to /UserPlayedItems/track-abc"
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/PlayedItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn mark_played_falls_back_to_legacy_route_on_404() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/UserPlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Users/u1/PlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "Played": true,
            "PlayCount": 1,
            "PlaybackPositionTicks": 0,
            "LastPlayedDate": "2026-04-25T18:30:00Z"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.mark_played("track-abc").await.unwrap();
    assert!(state.played);
    assert_eq!(state.play_count, 1);

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserPlayedItems/track-abc"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST"
                && r.url.path() == "/Users/u1/PlayedItems/track-abc"),
        "expected fallback to legacy route after 404"
    );
}

#[tokio::test]
async fn mark_unplayed_falls_back_to_legacy_route_on_405() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserPlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(405))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/Users/u1/PlayedItems/track-abc"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "Played": false,
            "PlayCount": 0,
            "PlaybackPositionTicks": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.mark_unplayed("track-abc").await.unwrap();
    assert!(!state.played);
    assert_eq!(state.play_count, 0);

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE" && r.url.path() == "/UserPlayedItems/track-abc"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE"
                && r.url.path() == "/Users/u1/PlayedItems/track-abc"),
        "expected fallback to legacy route after 405"
    );
}

#[tokio::test]
async fn mark_played_without_session_returns_not_authenticated() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.mark_played("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    let err = client.mark_unplayed("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    // No HTTP traffic should have escaped the guard.
    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.is_empty(),
        "guard should short-circuit before any HTTP call, got {:?}",
        requests
    );
}
