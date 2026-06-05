use super::*;

// ---------------------------------------------------------------------------
// Library resolution — /UserViews + ManualPlaylistsFolder
// ---------------------------------------------------------------------------

#[tokio::test]
async fn user_views_parses_and_returns_all_libraries() {
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
        .and(path("/UserViews"))
        .and(query_param("userId", "u1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" },
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" },
                { "Id": "lib-pl", "Name": "Playlists", "CollectionType": "playlists" }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let views = client.user_views().await.unwrap();
    assert_eq!(views.len(), 3);
    assert_eq!(views[0].id, "lib-music");
    assert_eq!(views[0].collection_type.as_deref(), Some("music"));
    assert_eq!(views[2].collection_type.as_deref(), Some("playlists"));
}

#[tokio::test]
async fn music_library_id_filters_and_caches() {
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
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" },
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let first = client.music_library_id().await.unwrap();
    assert_eq!(first, "lib-music");

    // Second call must come from the cache, not a fresh HTTP hit — if the
    // cache regresses this count would be 2.
    let second = client.music_library_id().await.unwrap();
    assert_eq!(second, "lib-music");
    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .count();
    assert_eq!(
        get_count, 1,
        "music_library_id must cache /UserViews response"
    );
}

#[tokio::test]
async fn music_library_id_returns_404_when_no_music_view() {
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
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.music_library_id().await.unwrap_err();
    // Post-refactor: a missing "music" collection view surfaces as
    // `NotFound` rather than the coarse `Server { status: 404 }`.
    assert!(
        matches!(err, crate::error::LyrebirdError::NotFound(_)),
        "expected NotFound, got {err:?}"
    );
}

#[tokio::test]
async fn playlist_library_id_finds_playlists_user_view() {
    // Rationale: an earlier implementation hit
    // `/Items?includeItemTypes=ManualPlaylistsFolder` which returned the
    // ManualPlaylistsFolder entity's id — but that id is NOT a valid
    // `ParentId` for `/Items?ParentId=…&IncludeItemTypes=Playlist` on
    // real servers. The UserView id (the one surfaced by /UserViews) is.
    // So the canonical resolution goes through /UserViews + CollectionType
    // filter, same as music_library_id.
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
        .and(path("/UserViews"))
        .and(query_param("userId", "u1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music", "Type": "CollectionFolder" },
                { "Id": "lib-pl", "Name": "Playlists", "CollectionType": "playlists", "Type": "UserView" }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client.playlist_library_id().await.unwrap();
    assert_eq!(id, "lib-pl");

    // Second call is served from the cache (no additional /UserViews hit).
    let again = client.playlist_library_id().await.unwrap();
    assert_eq!(again, "lib-pl");
    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .count();
    assert_eq!(
        get_count, 1,
        "playlist_library_id must cache its resolution"
    );
}

#[tokio::test]
async fn library_resolution_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.user_views().await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated on user_views, got {err:?}"
    );
    let err = client.music_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated on music_library_id, got {err:?}"
    );
    let err = client.playlist_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated on playlist_library_id, got {err:?}"
    );
}

#[tokio::test]
async fn set_session_invalidates_library_cache() {
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
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.music_library_id().await.unwrap();
    // Re-auth against the same mock: cache must be dropped so the new
    // session triggers a fresh /UserViews lookup.
    client.set_session("t2".into(), "u2".into());
    let _ = client.music_library_id().await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let user_view_users: Vec<String> = requests
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .map(|r| {
            r.url
                .query_pairs()
                .find(|(k, _)| k == "userId")
                .map(|(_, v)| v.into_owned())
                .unwrap_or_default()
        })
        .collect();
    assert_eq!(
        user_view_users.len(),
        2,
        "set_session must invalidate cached library ids"
    );
    // The cache invalidation must propagate the NEW user id to the second
    // lookup — not just re-fetch under the stale user.
    assert_eq!(
        user_view_users,
        vec!["u1".to_string(), "u2".to_string()],
        "second /UserViews must be issued for the new user (u2)"
    );
}
