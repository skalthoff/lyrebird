use super::*;

#[tokio::test]
async fn user_playlists_returns_every_playlist_in_library_view() {
    // Rationale: the prior `Path.contains("/data/")` filter was a false
    // discriminator — it assumed Jellyfin stored user-owned playlists
    // under `/config/data/users/…` but any server that mounts its
    // Playlists library elsewhere (e.g. `/sMusic/playlists/` as on the
    // author's own server) had 100% of its playlists filtered out, leaving
    // the UI reading "0 OF N PLAYLISTS".
    //
    // Corrected behaviour: `user_playlists` returns every playlist the
    // server lists under the given library view, without a client-side
    // path filter.
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
        .and(path("/Items"))
        .and(query_param("ParentId", "lib-pl"))
        .and(query_param("UserId", "u1"))
        .and(query_param("IncludeItemTypes", "Playlist"))
        .and(query_param("Limit", "20"))
        .and(query_param("StartIndex", "5"))
        .and(query_param("Fields", "ChildCount,Path,UserData"))
        .and(query_param("EnableUserData", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "p1", "Name": "My Mix", "Type": "Playlist",
                    "ChildCount": 12,
                    "RunTimeTicks": 42_000_000_000u64,
                    "Path": "/config/data/users/u1/playlists/my-mix",
                    "ImageTags": { "Primary": "tag-1" },
                    "UserData": { "IsFavorite": true }
                },
                {
                    "Id": "p2", "Name": "Community Top 40", "Type": "Playlist",
                    "ChildCount": 40,
                    "Path": "/sMusic/playlists/community-top-40",
                    "ImageTags": {}
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .user_playlists("lib-pl", Paging::new(5, 20))
        .await
        .unwrap();

    assert_eq!(
        page.items.len(),
        2,
        "should return every playlist, not apply a /data/ filter"
    );
    assert_eq!(page.total_count, 2);
    assert_eq!(page.items[0].id, "p1");
    assert_eq!(page.items[0].name, "My Mix");
    assert_eq!(page.items[0].track_count, 12);
    assert_eq!(page.items[0].image_tag.as_deref(), Some("tag-1"));
    assert_eq!(
        page.items[0].user_data.as_ref().map(|u| u.is_favorite),
        Some(true),
        "UserData.IsFavorite must be carried through on the playlist"
    );
    // Crucially, the non-`/data/`-path playlist is included.
    assert_eq!(page.items[1].id, "p2");
    assert_eq!(page.items[1].name, "Community Top 40");
    assert!(page.items[1].user_data.is_none());
}

// NOTE: `public_playlists` (a stub that delegated to `user_playlists` with no
// real public-vs-private filtering) was removed in the audit pass — the name
// promised behavior the body never implemented and no caller used it. Callers
// use `user_playlists` explicitly so the "community playlists" gap is visible
// rather than disguised as green coverage. See client.rs `user_playlists`.

#[tokio::test]
async fn user_playlists_empty_when_server_returns_no_items() {
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
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let user = client
        .user_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();
    assert!(user.items.is_empty());
    assert_eq!(user.total_count, 0);
}

#[tokio::test]
async fn playlists_require_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .user_playlists("lib-pl", Paging::new(0, 20))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn playlist_tracks_preserves_order_and_builds_query() {
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
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .and(query_param("UserId", "u1"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param("Limit", "50"))
        .and(query_param("StartIndex", "0"))
        .and(query_param(
            "Fields",
            "MediaSources,ParentId,Path,PlaylistItemId,SortName,UserData",
        ))
        .and(query_param("EnableUserData", "true"))
        .respond_with(|req: &Request| {
            // Playlist order is load-bearing: the client must NOT send
            // SortBy/SortOrder for this endpoint.
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            assert!(
                !pairs.contains_key("SortBy"),
                "playlist_tracks must not set SortBy"
            );
            assert!(
                !pairs.contains_key("SortOrder"),
                "playlist_tracks must not set SortOrder"
            );
            // Auth header must be present.
            let auth = req
                .headers
                .get(reqwest::header::AUTHORIZATION)
                .expect("expected Authorization header")
                .to_str()
                .unwrap();
            assert!(auth.contains("Token=\"t\""), "auth header: {auth}");
            // Deliberately return items in an order that is NOT sorted by id
            // (t3 < t1 < t2 is false) NOR by name (Charlie/Alpha/Bravo is not
            // alphabetical). If `playlist_tracks` re-sorted by either key the
            // assertion below would fail — so this proves it preserves the
            // server's stored playlist order rather than re-deriving one.
            ResponseTemplate::new(200).set_body_json(json!({
                "Items": [
                    {
                        "Id": "t3", "Name": "Charlie", "Type": "Audio",
                        "AlbumId": "a3", "Album": "Album Three",
                        "AlbumArtist": "Artist C", "Artists": ["Artist C"],
                        "RunTimeTicks": 2000000000u64,
                        "ImageTags": { "Primary": "img-3" }
                    },
                    {
                        "Id": "t1", "Name": "Alpha", "Type": "Audio",
                        "AlbumId": "a1", "Album": "Album One",
                        "AlbumArtist": "Artist A", "Artists": ["Artist A"],
                        "RunTimeTicks": 1800000000u64,
                        "ImageTags": { "Primary": "img-1" }
                    },
                    {
                        "Id": "t2", "Name": "Bravo", "Type": "Audio",
                        "AlbumId": "a2", "Album": "Album Two",
                        "AlbumArtist": "Artist B", "Artists": ["Artist B"],
                        "RunTimeTicks": 2220000000u64,
                        "ImageTags": { "Primary": "img-2" }
                    }
                ],
                "TotalRecordCount": 3
            }))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", Paging::new(0, 50))
        .await
        .unwrap();
    let tracks = page.items;

    // Server order (t3, t1, t2) must be preserved exactly — neither
    // id-ascending nor name-ascending would reproduce this.
    assert_eq!(tracks.len(), 3);
    assert_eq!(page.total_count, 3);
    assert_eq!(tracks[0].id, "t3");
    assert_eq!(tracks[0].name, "Charlie");
    assert_eq!(tracks[1].id, "t1");
    assert_eq!(tracks[1].name, "Alpha");
    assert_eq!(tracks[2].id, "t2");
    assert_eq!(tracks[2].name, "Bravo");
}

#[tokio::test]
async fn playlist_tracks_uses_paging() {
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
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .and(query_param("Limit", "25"))
        .and(query_param("StartIndex", "10"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 1200
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", Paging::new(10, 25))
        .await
        .unwrap();
    assert!(page.items.is_empty());
    // Even when this page is empty, callers can still see there's more to
    // fetch — important for the "page until total_count" loop in AppModel.
    assert_eq!(page.total_count, 1200);
}

#[tokio::test]
async fn playlist_tracks_requires_authenticated_session() {
    // No MockServer routes registered: the guard must short-circuit before
    // any HTTP call. Pointing at a live MockServer means a regression would
    // surface as an unmatched-route error instead of silently hitting a real
    // host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .playlist_tracks("pl-1", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn create_playlist_posts_pascal_case_body_and_returns_id() {
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
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Id": "new-playlist-id"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client
        .create_playlist("Road Trip", &["t1", "t2", "t3"])
        .await
        .unwrap();
    assert_eq!(id, "new-playlist-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");

    // Content-Type should be JSON (set by reqwest when using `.json()`).
    let content_type = post
        .headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    assert!(
        content_type.contains("application/json"),
        "unexpected content-type: {content_type}"
    );

    // Auth header must be present with token.
    let auth = post
        .headers
        .get(reqwest::header::AUTHORIZATION)
        .expect("expected Authorization header")
        .to_str()
        .unwrap();
    assert!(auth.contains("Token=\"t\""), "auth header: {auth}");

    // Body must use Jellyfin's PascalCase keys, with MediaType = "Audio".
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    assert_eq!(
        body.get("Name").and_then(|v| v.as_str()),
        Some("Road Trip"),
        "body: {body}"
    );
    assert_eq!(
        body.get("UserId").and_then(|v| v.as_str()),
        Some("u1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("MediaType").and_then(|v| v.as_str()),
        Some("Audio"),
        "body: {body}"
    );
    let ids = body
        .get("Ids")
        .and_then(|v| v.as_array())
        .expect("Ids should be an array");
    let id_strs: Vec<&str> = ids.iter().filter_map(|v| v.as_str()).collect();
    assert_eq!(id_strs, vec!["t1", "t2", "t3"], "body: {body}");

    // Keys must be PascalCase only — no snake_case leakage.
    let obj = body.as_object().expect("body should be an object");
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only, got: {:?}",
        obj.keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn create_playlist_with_empty_ids_sends_empty_array() {
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
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Id": "empty-playlist-id"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client.create_playlist("Empty List", &[]).await.unwrap();
    assert_eq!(id, "empty-playlist-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    let ids = body
        .get("Ids")
        .and_then(|v| v.as_array())
        .expect("Ids should be an array");
    assert!(ids.is_empty(), "expected empty Ids array, got: {body}");
}

#[tokio::test]
async fn create_playlist_propagates_server_errors() {
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
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.create_playlist("x", &[]).await.unwrap_err();
    match err {
        crate::error::LyrebirdError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }

    // create_playlist is a resource-creating POST: it must NOT auto-retry on
    // 5xx (a duplicate playlist could be created if the first POST committed
    // but its response was lost). Exactly one POST must have hit /Playlists.
    let create_posts = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .count();
    assert_eq!(
        create_posts, 1,
        "non-idempotent create_playlist must not retry a 5xx, got {create_posts} POSTs"
    );
}

#[tokio::test]
async fn create_playlist_requires_authenticated_session() {
    // No MockServer routes registered: the auth guard must short-circuit
    // before any HTTP call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.create_playlist("x", &[]).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn add_to_playlist_posts_ids_csv_and_user_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Jellyfin returns 204 No Content on success.
    Mock::given(method("POST"))
        .and(path("/Playlists/pl-123/Items"))
        .and(query_param("UserId", "u1"))
        .and(query_param("Ids", "t1,t2,t3"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .add_to_playlist("pl-123", &["t1", "t2", "t3"], None)
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists/pl-123/Items")
        .expect("expected POST to /Playlists/pl-123/Items");

    // Query carries Ids as a comma-separated list and UserId is set.
    let q = post.url.query().expect("expected a query string");
    assert!(q.contains("Ids=t1%2Ct2%2Ct3"), "query: {q}");
    assert!(q.contains("UserId=u1"), "query: {q}");

    // Body must be empty — the endpoint accepts query-only input.
    assert!(
        post.body.is_empty(),
        "expected empty body, got {:?}",
        post.body
    );
}

#[tokio::test]
async fn add_to_playlist_requires_authenticated_session() {
    // No MockServer route registered for /Playlists/*/Items: the auth guard
    // must short-circuit before any HTTP call. Pointing at a live MockServer
    // means a regression would surface as an unmatched-route error rather
    // than silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .add_to_playlist("pl-123", &["t1"], None)
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// playlist_tracks — PlaylistItemId in Fields (#572)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn playlist_tracks_includes_playlist_item_id_in_fields() {
    // #572: PlaylistItemId must appear in the Fields param so the server
    // returns per-entry identifiers. Without it, duplicate tracks are
    // indistinguishable and remove-by-entry operations delete all copies.
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
        .and(path("/Items"))
        .and(query_param("ParentId", "dup-pl"))
        .respond_with(|req: &Request| {
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            let fields = pairs.get("Fields").cloned().unwrap_or_default();
            assert!(
                fields.contains("PlaylistItemId"),
                "Fields must contain PlaylistItemId, got: {fields}"
            );
            ResponseTemplate::new(200).set_body_json(json!({
                "Items": [
                    {
                        "Id": "t1", "Name": "Repeated", "Type": "Audio",
                        "AlbumId": "a1", "Album": "A", "AlbumArtist": "X",
                        "Artists": ["X"], "RunTimeTicks": 1000000000u64,
                        "PlaylistItemId": "pi-1",
                        "ImageTags": {}
                    },
                    {
                        "Id": "t1", "Name": "Repeated", "Type": "Audio",
                        "AlbumId": "a1", "Album": "A", "AlbumArtist": "X",
                        "Artists": ["X"], "RunTimeTicks": 1000000000u64,
                        "PlaylistItemId": "pi-2",
                        "ImageTags": {}
                    }
                ],
                "TotalRecordCount": 2
            }))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("dup-pl", Paging::new(0, 50))
        .await
        .unwrap();
    // Both duplicate entries must be returned — the server distinguishes them
    // via PlaylistItemId, which is now requested in Fields.
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.total_count, 2);
    // The two entries are byte-identical except for PlaylistItemId, so assert
    // the values actually parsed onto the Track models — otherwise
    // remove-by-entry / reorder can't tell the duplicates apart.
    assert_eq!(page.items[0].playlist_item_id.as_deref(), Some("pi-1"));
    assert_eq!(page.items[1].playlist_item_id.as_deref(), Some("pi-2"));
}

// ---------------------------------------------------------------------------
// add_to_playlist — optional position param (#607)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn add_to_playlist_with_position_sends_start_index() {
    // #607: when position is Some(n) the client must include StartIndex=n in
    // the query string so Jellyfin inserts at that position instead of
    // appending.
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
        .and(path("/Playlists/pl-99/Items"))
        .and(query_param("StartIndex", "3"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .add_to_playlist("pl-99", &["t1"], Some(3))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists/pl-99/Items")
        .expect("expected POST to /Playlists/pl-99/Items");
    let q = post.url.query().expect("expected a query string");
    assert!(q.contains("StartIndex=3"), "query: {q}");
}

#[tokio::test]
async fn add_to_playlist_without_position_omits_start_index() {
    // #607: when position is None, StartIndex must NOT appear in the query —
    // Jellyfin interprets its absence as "append to end".
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
        .and(path("/Playlists/pl-append/Items"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .add_to_playlist("pl-append", &["t2"], None)
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists/pl-append/Items")
        .expect("expected POST to /Playlists/pl-append/Items");
    let q = post.url.query().unwrap_or_default();
    assert!(
        !q.contains("StartIndex"),
        "StartIndex must be absent when position is None, query: {q}"
    );
}

// ---------------------------------------------------------------------------
// create_playlist — never sends StartIndex (#607 removed: the param had no
// server-side effect on POST /Playlists, so the misleading hint was dropped).
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_playlist_never_sends_start_index() {
    // `POST /Playlists` has no `StartIndex` semantics; the client must not
    // append it. Pins the post-removal contract so a future reintroduction of
    // a no-op position hint is caught.
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
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "Id": "no-pos-pl-id" })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client.create_playlist("Appended", &["t1"]).await.unwrap();
    assert_eq!(id, "no-pos-pl-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");
    let q = post.url.query().unwrap_or_default();
    assert!(
        !q.contains("StartIndex"),
        "StartIndex must never be sent, query: {q}"
    );
}

// ---------------------------------------------------------------------------
// remove_from_playlist — DELETE /Playlists/{id}/Items?entryIds=...
// ---------------------------------------------------------------------------

#[tokio::test]
async fn remove_from_playlist_sends_entry_ids_query_and_expects_204() {
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
        .and(path("/Playlists/pl-1/Items"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .remove_from_playlist("pl-1", &["entry-1".into(), "entry-2".into()])
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let del = requests
        .iter()
        .find(|r| r.method.as_str() == "DELETE" && r.url.path() == "/Playlists/pl-1/Items")
        .expect("expected DELETE to /Playlists/pl-1/Items");
    let entry_ids = del
        .url
        .query_pairs()
        .find(|(k, _)| k == "entryIds")
        .map(|(_, v)| v.into_owned())
        .expect("expected entryIds query param");
    assert_eq!(entry_ids, "entry-1,entry-2");
}

#[tokio::test]
async fn remove_from_playlist_is_noop_on_empty_entry_ids() {
    // No DELETE mock is registered — an accidental network hit would
    // surface as an unmatched-route error rather than silently succeed.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.remove_from_playlist("pl-1", &[]).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    assert!(
        !requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE" && r.url.path().starts_with("/Playlists/")),
        "empty entry_ids must short-circuit before any HTTP request"
    );
}

#[tokio::test]
async fn remove_from_playlist_propagates_server_errors() {
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
        .and(path("/Playlists/pl-1/Items"))
        .respond_with(ResponseTemplate::new(403).set_body_string("forbidden"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .remove_from_playlist("pl-1", &["entry-1".into()])
        .await
        .unwrap_err();
    // Post-refactor: 403 responses surface as the dedicated `Forbidden`
    // variant rather than the coarse `Server { status: 403 }`.
    assert!(
        matches!(err, crate::error::LyrebirdError::Forbidden(_)),
        "expected Forbidden, got {err:?}"
    );
}

#[tokio::test]
async fn remove_from_playlist_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .remove_from_playlist("pl-1", &["entry-1".into()])
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ============================================================================
// Playlist CRUD — rename / delete / reorder (#564)
// ============================================================================

/// `rename_playlist` must GET the current item body, overwrite `Name`, then
/// POST back to `/Items/{id}`.
#[tokio::test]
async fn rename_playlist_fetches_then_posts() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // GET /Items?Ids=pl-1 — fetch_item uses the /Items?Ids= endpoint. Include
    // the metadata the rename round-trip must preserve (the whole reason it
    // does a GET first — UpdateItem blind-assigns the posted body).
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("Ids", "pl-1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "pl-1",
                    "Name": "Old Name",
                    "Type": "Playlist",
                    "Genres": ["Chill", "Focus"],
                    "Tags": ["roadtrip"],
                    "Overview": "My carefully curated mix.",
                    "SortName": "old name",
                    "ProductionYear": 2021
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // POST /Items/pl-1 — server accepts the update.
    Mock::given(method("POST"))
        .and(path("/Items/pl-1"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.rename_playlist("pl-1", "New Name").await.unwrap();

    // Verify the POST body has the updated Name.
    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Items/pl-1")
        .expect("expected POST to /Items/pl-1");
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    assert_eq!(
        body["Name"].as_str(),
        Some("New Name"),
        "body Name must be updated, got: {body}"
    );
    // The fetched fields must survive the fetch-merge-post round-trip — this is
    // the entire reason rename does a GET first. A regression that posts a
    // sparse body would wipe these server-side (#audit lossy-RMW).
    assert_eq!(
        body["Id"].as_str(),
        Some("pl-1"),
        "Id must be preserved: {body}"
    );
    assert_eq!(
        body["Type"].as_str(),
        Some("Playlist"),
        "Type must be preserved: {body}"
    );
    assert_eq!(
        body["Genres"],
        json!(["Chill", "Focus"]),
        "Genres must be preserved: {body}"
    );
    assert_eq!(
        body["Tags"],
        json!(["roadtrip"]),
        "Tags must be preserved: {body}"
    );
    assert_eq!(
        body["Overview"].as_str(),
        Some("My carefully curated mix."),
        "Overview must be preserved: {body}"
    );
    assert_eq!(
        body["ProductionYear"].as_i64(),
        Some(2021),
        "ProductionYear must be preserved: {body}"
    );
    // SortName must be mapped to ForcedSortName (the field UpdateItem reads)
    // so the custom sort isn't cleared on rename.
    assert_eq!(
        body["ForcedSortName"].as_str(),
        Some("old name"),
        "SortName must be mapped to ForcedSortName: {body}"
    );
}

/// `rename_playlist` must require an authenticated session.
#[tokio::test]
async fn rename_playlist_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .rename_playlist("pl-1", "Anything")
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

/// `delete_playlist` must send `DELETE /Items/{id}`.
#[tokio::test]
async fn delete_playlist_sends_delete_request() {
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
        .and(path("/Items/pl-42"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.delete_playlist("pl-42").await.unwrap();

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE" && r.url.path() == "/Items/pl-42"),
        "expected DELETE /Items/pl-42"
    );
}

/// `delete_playlist` must require an authenticated session.
#[tokio::test]
async fn delete_playlist_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.delete_playlist("pl-1").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

/// `reorder_playlist_track` must POST to
/// `/Playlists/{playlistId}/Items/{playlistItemId}/Move/{newIndex}`.
#[tokio::test]
async fn reorder_playlist_track_sends_move_request() {
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
        .and(path("/Playlists/pl-7/Items/pi-99/Move/2"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .reorder_playlist_track("pl-7", "pi-99", 2)
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.iter().any(|r| {
            r.method.as_str() == "POST" && r.url.path() == "/Playlists/pl-7/Items/pi-99/Move/2"
        }),
        "expected POST to /Playlists/pl-7/Items/pi-99/Move/2"
    );
}

/// `reorder_playlist_track` must require an authenticated session.
#[tokio::test]
async fn reorder_playlist_track_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .reorder_playlist_track("pl-1", "pi-1", 0)
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

/// `playlist_tracks` must populate `playlist_item_id` on each returned track.
#[tokio::test]
async fn playlist_tracks_populates_playlist_item_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // playlist_tracks uses GET /Items?ParentId=...&UserId=...
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Track One", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Album A",
                    "AlbumArtist": "Artist A", "Artists": ["Artist A"],
                    "RunTimeTicks": 1000000000u64,
                    "PlaylistItemId": "pi-alpha",
                    "ImageTags": {}
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", crate::models::Paging::new(0, 50))
        .await
        .unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(
        page.items[0].playlist_item_id.as_deref(),
        Some("pi-alpha"),
        "playlist_item_id must be populated from the server response"
    );
}

/// `playlist_tracks` must request UserData so favorited tracks in a
/// playlist render as favorited on first paint. Without `EnableUserData` +
/// `UserData` in `Fields`, the server omits `UserData` and every track maps
/// to `is_favorite == false`.
#[tokio::test]
async fn playlist_tracks_populates_favorite_from_user_data() {
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
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .and(query_param("EnableUserData", "true"))
        .respond_with(|req: &Request| {
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            let fields = pairs.get("Fields").cloned().unwrap_or_default();
            assert!(
                fields.contains("UserData"),
                "Fields must contain UserData, got: {fields}"
            );
            ResponseTemplate::new(200).set_body_json(json!({
                "Items": [
                    {
                        "Id": "t1", "Name": "Faved", "Type": "Audio",
                        "AlbumId": "a1", "Album": "A", "AlbumArtist": "X",
                        "Artists": ["X"], "RunTimeTicks": 1000000000u64,
                        "ImageTags": {},
                        "UserData": { "IsFavorite": true, "PlayCount": 3 }
                    }
                ],
                "TotalRecordCount": 1
            }))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", crate::models::Paging::new(0, 50))
        .await
        .unwrap();
    assert_eq!(page.items.len(), 1);
    assert!(
        page.items[0].is_favorite,
        "is_favorite must reflect server UserData.IsFavorite"
    );
    assert_eq!(
        page.items[0].user_data.as_ref().map(|u| u.is_favorite),
        Some(true),
        "user_data must be populated from the server response"
    );
}

// ============================================================================
// playlist_tracks defensive Type filter — #313 / ux-audit
// ============================================================================

/// Regression for the "Playlists > Playlists" screenshot. When the caller
/// accidentally hands the Playlists *CollectionFolder* id (the library-view
/// id, not a single playlist) as `playlist_id`, the server ignores
/// `IncludeItemTypes=Audio` under a folder parent and returns the folder's
/// children — Playlist-typed items that, if mapped through `Track::from`,
/// would render as minute-long "tracks" on the UI. The Rust client now
/// post-filters by `Type == "Audio"` so the downstream UI never sees
/// non-audio rows regardless of what the server returns.
#[tokio::test]
async fn playlist_tracks_rejects_non_audio_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Simulate the server's bad behaviour: return a mix of Audio and
    // Playlist items for the /Items?ParentId=<folderId>&IncludeItemTypes=Audio
    // request.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Real Track", "Type": "Audio",
                    "AlbumId": "a1", "AlbumArtist": "Artist",
                    "RunTimeTicks": 180_000_000_000u64
                },
                {
                    "Id": "pl1", "Name": "Africa by Toto", "Type": "Playlist",
                    "RunTimeTicks": 12_000_000_000u64,
                    "ChildCount": 5
                },
                {
                    "Id": "pl2", "Name": "Ayla Music", "Type": "Playlist",
                    "RunTimeTicks": 205_200_000_000u64,
                    "ChildCount": 92
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("library-folder-id", crate::Paging::new(0, 50))
        .await
        .unwrap();

    // Only the Audio entry survives; the Playlist items would otherwise
    // render as tracks with multi-hour durations on the UI.
    assert_eq!(page.items.len(), 1, "non-Audio rows must be dropped");
    assert_eq!(page.items[0].id, "t1");
    assert_eq!(page.items[0].name, "Real Track");
}

/// `playlists_containing_artist` walks every playlist in the library
/// view and keeps only those whose track list credits the target artist at
/// the track level (`ArtistItems`) or as album artist. The membership test is
/// client-side because Jellyfin ignores `ArtistIds` under a playlist parent.
#[tokio::test]
async fn playlists_containing_artist_filters_by_track_credit() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Library view: three playlists.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "lib-pl"))
        .and(query_param("IncludeItemTypes", "Playlist"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "pl-a", "Name": "Has Artist", "Type": "Playlist", "ChildCount": 2 },
                { "Id": "pl-b", "Name": "No Artist", "Type": "Playlist", "ChildCount": 1 },
                { "Id": "pl-c", "Name": "Album Artist", "Type": "Playlist", "ChildCount": 1 }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;
    // pl-a — artist credited at the track level via ArtistItems.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-a"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param("Fields", "ArtistItems"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Some Other", "Type": "Audio",
                    "ArtistItems": [ { "Id": "other", "Name": "Other" } ]
                },
                {
                    "Id": "t2", "Name": "Guest Feature", "Type": "Audio",
                    "ArtistItems": [
                        { "Id": "other2", "Name": "Other Two" },
                        { "Id": "artist-x", "Name": "Artist X" }
                    ]
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;
    // pl-b — no credit for the artist anywhere.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-b"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t3", "Name": "Unrelated", "Type": "Audio",
                    "ArtistItems": [ { "Id": "nope", "Name": "Nope" } ]
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;
    // pl-c — artist credited only as album artist (AlbumArtistId) still counts.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-c"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t4", "Name": "Album Track", "Type": "Audio",
                    "AlbumArtistId": "artist-x",
                    "ArtistItems": []
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let result = client
        .playlists_containing_artist("lib-pl", "artist-x", 6)
        .await
        .unwrap();

    let ids: Vec<&str> = result.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["pl-a", "pl-c"],
        "only playlists crediting the artist (track-level or album-artist) are returned"
    );
}

/// A zero `limit` short-circuits without issuing any HTTP request.
#[tokio::test]
async fn playlists_containing_artist_zero_limit_is_empty() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let result = client
        .playlists_containing_artist("lib-pl", "artist-x", 0)
        .await
        .unwrap();
    assert!(result.is_empty());
}
