use super::*;

#[tokio::test]
async fn public_info_parses() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ServerName": "Home Jellyfin",
            "Version": "10.10.0",
            "Id": "abc123"
        })))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let info = client.public_info().await.unwrap();
    assert_eq!(info.server_name.as_deref(), Some("Home Jellyfin"));
    assert_eq!(info.version.as_deref(), Some("10.10.0"));
}

#[tokio::test]
async fn authenticate_by_name_captures_session() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "xyz-token",
            "ServerId": "server-id-1",
            "ServerName": "My Jellyfin",
            "User": {
                "Id": "user-id-1",
                "Name": "soren",
                "ServerId": "server-id-1",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    let session = client.authenticate_by_name("soren", "pw").await.unwrap();
    assert_eq!(session.access_token, "xyz-token");
    assert_eq!(session.user.id, "user-id-1");
    assert_eq!(session.server.name, "My Jellyfin");
}

#[tokio::test]
async fn album_tracks_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t",
            "ServerId": "s",
            "ServerName": "S",
            "User": { "Id": "u1", "Name": "user", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Yona", "Type": "Audio",
                    "AlbumId": "a1", "Album": "The Deep End",
                    "AlbumArtist": "Saloli", "Artists": ["Saloli"],
                    "IndexNumber": 3, "ParentIndexNumber": 1,
                    "ProductionYear": 2020,
                    "RunTimeTicks": 2220000000u64,
                    "UserData": { "IsFavorite": true, "PlayCount": 7 },
                    "ImageTags": { "Primary": "abcd" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("user", "pw").await.unwrap();
    let tracks = client.album_tracks("a1").await.unwrap();
    assert_eq!(tracks.len(), 1);
    let t = &tracks[0];
    assert_eq!(t.name, "Yona");
    assert_eq!(t.artist_name, "Saloli");
    assert!(t.is_favorite);
    assert_eq!(t.play_count, 7);
    assert!((t.duration_seconds() - 222.0).abs() < 0.001);
    // album_tracks is the only Track-producing path that exercises these
    // mappings end-to-end; lock them so a regression in the RawItem -> Track
    // projection is caught (incl. ParentIndexNumber -> disc_number, which is
    // otherwise untested across the whole suite).
    assert_eq!(t.album_id.as_deref(), Some("a1"));
    assert_eq!(t.album_name.as_deref(), Some("The Deep End"));
    assert_eq!(t.index_number, Some(3));
    assert_eq!(
        t.disc_number,
        Some(1),
        "ParentIndexNumber must map to disc_number"
    );
    assert_eq!(t.year, Some(2020));
    assert_eq!(t.image_tag.as_deref(), Some("abcd"));
}

/// Asserts the query parameters sent by `album_tracks` (#570, #571, rc7):
/// - `Recursive` is NOT sent — Jellyfin's library walk dominates query
///   time on large libraries; omitting it is a 53× speedup with zero
///   content change because music albums are flat (multi-disc albums
///   carry the disc number on `ParentIndexNumber`, not in nested folders).
/// - `SortBy` and `SortOrder` are parallel comma-separated arrays (3 fields
///   each) so track ordering is well-defined on Jellyfin.
#[tokio::test]
async fn album_tracks_query_params() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "user", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("user", "pw").await.unwrap();
    let _ = client.album_tracks("album-42").await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");

    // rc7 — `Recursive=true` is intentionally NOT sent. The original
    // assumption (#570) was that Recursive was needed for multi-disc
    // albums, but Jellyfin models multi-disc albums as a flat track list
    // with `ParentIndexNumber` carrying the disc number — verified live
    // against music.skalthoff.com on a 17-track multi-disc album, which
    // returns the same 17 tracks with or without Recursive. Recursive=true
    // forces the server to walk the entire library tree under the album
    // (3.6s/request on a 157k-track library); omitting it drops the same
    // query to ~70ms.
    assert!(
        !q.contains("Recursive"),
        "Recursive must not be in album_tracks query (53× perf hit), got: {q}"
    );

    // #571 — SortBy and SortOrder must be parallel arrays of equal length.
    // URL encoding: ',' → '%2C'.
    assert!(
        q.contains("SortBy=ParentIndexNumber%2CIndexNumber%2CSortName"),
        "unexpected SortBy, got: {q}"
    );
    assert!(
        q.contains("SortOrder=Ascending%2CAscending%2CAscending"),
        "SortOrder must have one entry per SortBy field, got: {q}"
    );

    assert!(
        q.contains("ParentId=album-42"),
        "missing ParentId, got: {q}"
    );
}

/// Covers the Artist "Top Tracks" endpoint wired for #229. Asserts the
/// query shape (ArtistIds, IncludeItemTypes=Audio, SortBy=PlayCount,
/// SortOrder=Descending, Limit) and that the parsed tracks carry the
/// `play_count` the UI rank sort depends on.
#[tokio::test]
async fn artist_top_tracks_builds_query_and_parses() {
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
                    "Id": "t1", "Name": "Hit Song", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Greatest Hits",
                    "AlbumArtist": "Solo", "Artists": ["Solo"],
                    "RunTimeTicks": 1200000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 42 },
                    "ImageTags": { "Primary": "imgA" }
                },
                {
                    "Id": "t2", "Name": "Deeper Cut", "Type": "Audio",
                    "AlbumId": "a2", "Album": "B-Sides",
                    "AlbumArtist": "Solo", "Artists": ["Solo"],
                    "RunTimeTicks": 1500000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 5 },
                    "ImageTags": { "Primary": "imgB" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.artist_top_tracks("artist-xyz", 5).await.unwrap();

    assert_eq!(tracks.len(), 2);
    assert_eq!(tracks[0].name, "Hit Song");
    assert_eq!(tracks[0].play_count, 42);
    assert_eq!(tracks[1].play_count, 5);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("ArtistIds=artist-xyz"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=5"), "query: {q}");
    // `PlayCount,SortName` is URL-encoded as `PlayCount%2CSortName`.
    assert!(
        q.contains("SortBy=PlayCount%2CSortName"),
        "expected play-count sort, got: {q}"
    );
    assert!(
        q.contains("SortOrder=Descending%2CAscending"),
        "expected descending play-count sort, got: {q}"
    );
}

/// Zero `limit` should clamp to `1` (matching the pattern used for other
/// `Paging`/`Limit` endpoints) so the server never gets a no-op query.
#[tokio::test]
async fn artist_top_tracks_clamps_zero_limit_to_one() {
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
    let _ = client.artist_top_tracks("artist-xyz", 0).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=1"), "expected clamp to Limit=1, got: {q}");
}

#[tokio::test]
async fn recently_played_builds_query_and_parses() {
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
                    "Id": "t1", "Name": "Echo", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Tides",
                    "AlbumArtist": "Ocean", "Artists": ["Ocean"],
                    "RunTimeTicks": 1800000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 3 },
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1234
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .recently_played(Some("lib-1"), Paging::new(0, 50))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 1234);
    let tracks = page.items;
    assert_eq!(tracks[0].name, "Echo");
    assert_eq!(tracks[0].play_count, 3);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("SortBy=DatePlayed"), "query: {q}");
    assert!(q.contains("SortOrder=Descending"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    assert!(q.contains("ParentId=lib-1"), "query: {q}");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ParentId"),
        "Fields should include ParentId, got: {fields}"
    );
}

#[tokio::test]
async fn recently_played_omits_parent_id_when_none() {
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
    let _ = client
        .recently_played(None, Paging::new(5, 25))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(!q.contains("ParentId="), "unexpected ParentId: {q}");
    assert!(q.contains("Limit=25"), "query: {q}");
    assert!(q.contains("StartIndex=5"), "query: {q}");
    assert!(q.contains("SortBy=DatePlayed"), "query: {q}");
    assert!(q.contains("SortOrder=Descending"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_builds_query_and_parses() {
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
                    "Id": "t1", "Name": "Aria", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Sunrise",
                    "AlbumArtist": "Colleen", "Artists": ["Colleen"],
                    "ProductionYear": 2019,
                    "RunTimeTicks": 1800000000u64,
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 9876
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .list_tracks(Some("lib-1"), Paging::new(100, 50))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 9876);
    assert_eq!(page.items[0].name, "Aria");
    assert_eq!(page.items[0].artist_name, "Colleen");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("StartIndex=100"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
    assert!(q.contains("ParentId=lib-1"), "query: {q}");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ParentId"),
        "Fields should include ParentId, got: {fields}"
    );
}

#[tokio::test]
async fn list_tracks_omits_parent_id_when_none() {
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
    let _ = client.list_tracks(None, Paging::new(0, 100)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(!q.contains("ParentId="), "unexpected ParentId: {q}");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_requires_authenticated_session() {
    // No MockServer routes registered: the guard must short-circuit before
    // any HTTP call. Pointing at a live MockServer means a regression would
    // surface as an unmatched-route error instead of silently hitting a real
    // host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .list_tracks(Some("lib-1"), Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Browse flag assertions — EnableUserData + EnableImages + ImageTypeLimit
// ---------------------------------------------------------------------------

#[tokio::test]
async fn artists_includes_user_data_and_image_flags() {
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.artists(Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn albums_includes_user_data_and_image_flags() {
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
    let _ = client.albums(Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn latest_albums_includes_user_data_and_image_flags() {
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
        .and(path("/Items/Latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([])))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .latest_albums("lib-1", Paging::new(0, 24))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_includes_user_data_and_image_flags() {
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
    let _ = client.list_tracks(None, Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn recently_played_includes_user_data_and_image_flags() {
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
    let _ = client
        .recently_played(None, Paging::new(0, 50))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

// ---------------------------------------------------------------------------
// Artist detail
// ---------------------------------------------------------------------------

#[tokio::test]
async fn artist_detail_parses_overview_and_backdrops() {
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
        .and(query_param("Ids", "artist-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "artist-xyz",
                    "Name": "Ambient Pioneer",
                    "Genres": ["Ambient", "Electronic"],
                    "Overview": "A long biography.",
                    "BackdropImageTags": ["bd1", "bd2"],
                    "ExternalUrls": [
                        { "Name": "MusicBrainz", "Url": "https://mb.example/a" },
                        { "Name": "Last.fm", "Url": "https://last.fm/a" }
                    ],
                    "ImageTags": { "Primary": "imgArtist" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let detail = client.artist_detail("artist-xyz").await.unwrap();
    assert_eq!(detail.id, "artist-xyz");
    assert_eq!(detail.name, "Ambient Pioneer");
    assert_eq!(detail.overview.as_deref(), Some("A long biography."));
    assert_eq!(
        detail.backdrop_image_tags,
        vec!["bd1".to_string(), "bd2".to_string()]
    );
    assert_eq!(detail.external_urls.len(), 2);
    assert_eq!(detail.external_urls[0].name, "MusicBrainz");
    assert_eq!(detail.external_urls[0].url, "https://mb.example/a");
    assert_eq!(detail.image_tag.as_deref(), Some("imgArtist"));

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET" && r.url.path() == "/Items")
        .expect("expected a GET /Items");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "Overview"),
        "Fields should include Overview, got: {fields}"
    );
    assert!(
        fields.split(',').any(|f| f == "ExternalUrls"),
        "Fields should include ExternalUrls, got: {fields}"
    );
    assert!(
        fields.split(',').any(|f| f == "BackdropImageTags"),
        "Fields should include BackdropImageTags, got: {fields}"
    );
}

#[tokio::test]
async fn artist_detail_returns_server_404_on_empty_items() {
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
    let err = client.artist_detail("missing").await.unwrap_err();
    // Post-refactor: the 404 local-miss case uses the dedicated
    // `NotFound` variant rather than the coarse `Server { status: 404 }`.
    assert!(
        matches!(err, crate::error::LyrebirdError::NotFound(_)),
        "expected NotFound, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Lyrics
// ---------------------------------------------------------------------------

#[tokio::test]
async fn lyrics_parses_synced_payload() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // 10_000_000 ticks == 1.0 seconds; 50_000_000 == 5.0 seconds.
    Mock::given(method("GET"))
        .and(path("/Audio/track-1/Lyrics"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Metadata": { "IsSynced": true },
            "Lyrics": [
                { "Start": 10000000i64, "Text": "First line" },
                { "Start": 50000000i64, "Text": "Second line" }
            ]
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let lyrics = client
        .lyrics("track-1")
        .await
        .unwrap()
        .expect("expected Some(Lyrics) on 200");
    assert!(lyrics.is_synced);
    assert_eq!(lyrics.lines.len(), 2);
    assert!((lyrics.lines[0].time_seconds - 1.0).abs() < 0.0001);
    assert_eq!(lyrics.lines[0].text, "First line");
    assert!((lyrics.lines[1].time_seconds - 5.0).abs() < 0.0001);
}

#[tokio::test]
async fn lyrics_parses_plain_text() {
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
        .and(path("/Audio/track-2/Lyrics"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Metadata": { "IsSynced": false },
            "Lyrics": [
                { "Start": 0i64, "Text": "Just the words\nno timing" }
            ]
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let lyrics = client.lyrics("track-2").await.unwrap().unwrap();
    assert!(!lyrics.is_synced);
    assert_eq!(lyrics.lines.len(), 1);
    assert!((lyrics.lines[0].time_seconds - 0.0).abs() < 0.0001);
    assert!(lyrics.lines[0].text.contains("Just the words"));
}

#[tokio::test]
async fn lyrics_returns_none_on_404() {
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
        .and(path("/Audio/track-404/Lyrics"))
        .respond_with(ResponseTemplate::new(404).set_body_string("Not found"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let result = client.lyrics("track-404").await.unwrap();
    assert!(result.is_none(), "expected None on 404, got {result:?}");
}

#[tokio::test]
async fn lyrics_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.lyrics("any").await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn albums_uses_paging() {
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
    let _ = client.albums(Paging::new(10, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("StartIndex=10"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
}

#[tokio::test]
async fn albums_exposes_total_record_count() {
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
                    "Id": "a1", "Name": "First", "Type": "MusicAlbum",
                    "AlbumArtist": "Artist",
                    "ProductionYear": 2020, "ChildCount": 8,
                    "ImageTags": { "Primary": "t1" }
                },
                {
                    "Id": "a2", "Name": "Second", "Type": "MusicAlbum",
                    "AlbumArtist": "Artist",
                    "ProductionYear": 2021, "ChildCount": 10,
                    "ImageTags": { "Primary": "t2" }
                }
            ],
            "TotalRecordCount": 4321
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.albums(Paging::new(0, 2)).await.unwrap();
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.total_count, 4321);
    assert_eq!(page.items[0].name, "First");
    assert_eq!(page.items[1].name, "Second");
}

#[tokio::test]
async fn artists_exposes_total_record_count_and_paging() {
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "ar1", "Name": "Colleen", "Type": "MusicArtist",
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 999
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.artists(Paging::new(25, 100)).await.unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 999);
    assert_eq!(page.items[0].name, "Colleen");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=25"), "query: {q}");
    // Deliberately absent: `IncludeItemTypes=MusicArtist`. Live Jellyfin
    // 10.11 servers return 0 items from this endpoint when the filter is
    // present (see artists_does_not_send_include_item_types_music_artist
    // for the regression assertion).
    assert!(
        !q.contains("IncludeItemTypes=MusicArtist"),
        "artists() must NOT send IncludeItemTypes=MusicArtist, got: {q}"
    );
}

#[tokio::test]
async fn latest_albums_builds_expected_query_and_parses_unwrapped_array() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // `/Items/Latest` returns a bare array, not `{ Items, TotalRecordCount }`.
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .and(query_param("UserId", "u1"))
        .and(query_param("ParentId", "lib-music"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param("Limit", "24"))
        .and(query_param("GroupItems", "true"))
        .respond_with(|req: &Request| {
            // Sanity-check that no unexpected extra params were added and that
            // the full expected set (including `Fields`) is present on the
            // actual request. Building a set from `query_pairs` and comparing
            // to the expected set catches both extra keys and missing ones.
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            assert_eq!(pairs.get("UserId").map(String::as_str), Some("u1"));
            assert_eq!(pairs.get("ParentId").map(String::as_str), Some("lib-music"));
            assert_eq!(
                pairs.get("IncludeItemTypes").map(String::as_str),
                Some("MusicAlbum")
            );
            assert_eq!(pairs.get("Limit").map(String::as_str), Some("24"));
            assert_eq!(pairs.get("GroupItems").map(String::as_str), Some("true"));
            assert_eq!(
                pairs.get("Fields").map(String::as_str),
                Some("Genres,ProductionYear,ChildCount,PrimaryImageAspectRatio")
            );
            assert_eq!(
                pairs.get("EnableUserData").map(String::as_str),
                Some("true")
            );
            assert_eq!(pairs.get("EnableImages").map(String::as_str), Some("true"));
            assert_eq!(pairs.get("ImageTypeLimit").map(String::as_str), Some("1"));
            let expected_keys: std::collections::HashSet<&str> = [
                "UserId",
                "ParentId",
                "IncludeItemTypes",
                "Limit",
                "GroupItems",
                "Fields",
                "EnableUserData",
                "EnableImages",
                "ImageTypeLimit",
            ]
            .into_iter()
            .collect();
            let actual_keys: std::collections::HashSet<&str> =
                pairs.keys().map(String::as_str).collect();
            assert_eq!(
                actual_keys, expected_keys,
                "unexpected or missing query params on /Items/Latest request"
            );
            ResponseTemplate::new(200).set_body_json(json!([
                {
                    "Id": "a1", "Name": "The Deep End", "Type": "MusicAlbum",
                    "AlbumArtist": "Saloli", "Artists": ["Saloli"],
                    "ProductionYear": 2020, "ChildCount": 8,
                    "RunTimeTicks": 18000000000u64,
                    "ImageTags": { "Primary": "abcd" }
                },
                {
                    "Id": "a2", "Name": "Spiral", "Type": "MusicAlbum",
                    "AlbumArtist": "Colleen", "Artists": ["Colleen"],
                    "ProductionYear": 2023, "ChildCount": 11,
                    "ImageTags": {}
                }
            ]))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .latest_albums("lib-music", Paging::new(0, 24))
        .await
        .unwrap();
    let albums = page.items;
    assert_eq!(albums.len(), 2);
    // `/Items/Latest` doesn't report TotalRecordCount, so `total_count` is
    // the raw number of items the server returned for this request.
    assert_eq!(page.total_count, 2);
    assert_eq!(albums[0].name, "The Deep End");
    assert_eq!(albums[0].artist_name, "Saloli");
    assert_eq!(albums[0].year, Some(2020));
    assert_eq!(albums[0].track_count, 8);
    assert_eq!(albums[0].image_tag.as_deref(), Some("abcd"));
    assert_eq!(albums[1].name, "Spiral");
    assert!(albums[1].image_tag.is_none());
}

#[tokio::test]
async fn latest_albums_applies_offset_client_side() {
    // `/Items/Latest` doesn't support `StartIndex`, so `latest_albums`
    // fetches `offset + limit` items and slices the tail client-side.
    // The server sees `Limit=offset+limit` on the outbound request.
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
        .and(path("/Items/Latest"))
        .respond_with(|req: &Request| {
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            // `Limit` is the requested offset+limit so the slice has what to
            // skip. `StartIndex` must NOT be sent — the endpoint rejects it.
            assert_eq!(pairs.get("Limit").map(String::as_str), Some("7"));
            assert!(
                !pairs.contains_key("StartIndex"),
                "latest_albums must not send StartIndex"
            );
            ResponseTemplate::new(200).set_body_json(json!([
                { "Id": "a1", "Name": "One", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a2", "Name": "Two", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a3", "Name": "Three", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a4", "Name": "Four", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a5", "Name": "Five", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a6", "Name": "Six", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a7", "Name": "Seven", "Type": "MusicAlbum", "ImageTags": {} }
            ]))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    // offset=4, limit=3 → request Limit=7, skip 4, take 3 → items 5..7
    let page = client
        .latest_albums("lib-music", Paging::new(4, 3))
        .await
        .unwrap();
    let names: Vec<&str> = page.items.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["Five", "Six", "Seven"]);
    // total_count mirrors the returned page size (post-slice), not the
    // pre-slice fetch window — /Items/Latest has no server total, and the old
    // window-length value falsely implied more pages existed.
    assert_eq!(
        page.total_count, 3,
        "total_count must equal the returned page size, not offset+limit"
    );
}

#[tokio::test]
async fn latest_albums_requires_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .latest_albums("lib-music", Paging::new(0, 24))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn fetch_item_builds_expected_query_and_extracts_first() {
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
        .and(wiremock::matchers::query_param("Ids", "item-xyz"))
        .and(wiremock::matchers::query_param(
            "Fields",
            "Overview,Genres,Tags,ProductionYear",
        ))
        .and(wiremock::matchers::query_param("userId", "u1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "item-xyz",
                    "Name": "Mystery",
                    "Type": "MusicAlbum",
                    "Overview": "A very fine record.",
                    "Genres": ["Ambient", "Electronic"],
                    "Tags": ["Downtempo"],
                    "ProductionYear": 2024
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let value = client
        .fetch_item(
            "item-xyz",
            &["Overview", "Genres", "Tags", "ProductionYear"],
        )
        .await
        .unwrap();
    assert_eq!(value.get("Id").and_then(|v| v.as_str()), Some("item-xyz"));
    assert_eq!(
        value.get("Overview").and_then(|v| v.as_str()),
        Some("A very fine record.")
    );
    assert_eq!(
        value.get("ProductionYear").and_then(|v| v.as_i64()),
        Some(2024)
    );
}

#[tokio::test]
async fn fetch_item_empty_items_returns_not_found() {
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
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.fetch_item("missing-id", &[]).await.unwrap_err();
    // Post-refactor: the local empty-items miss raises `NotFound` rather
    // than the coarse `Server { status: 404 }`.
    assert!(
        matches!(err, crate::error::LyrebirdError::NotFound(_)),
        "expected NotFound, got {err:?}"
    );
}

#[tokio::test]
async fn fetch_item_without_session_returns_not_authenticated() {
    // No MockServer endpoints registered for /Items: the guard must short-circuit
    // before any network call. We still point at a live MockServer so that if
    // the guard regresses, the request would surface as an unmatched-route error
    // rather than silently hitting an unrelated host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.fetch_item("anything", &[]).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ============================================================================
// albums_by_artist — #60, ArtistDetailView Discography
// ============================================================================

/// Covers the artist-scoped Discography endpoint. Asserts the query is
/// scoped by `AlbumArtistIds` (not `ArtistIds` — compilations the artist
/// only appears on should NOT show up in Discography), that the response
/// is parsed, and that `total_count` carries the server's total.
#[tokio::test]
async fn albums_by_artist_scopes_by_album_artist_ids() {
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
                    "Id": "al1", "Name": "Debut", "Type": "MusicAlbum",
                    "AlbumArtist": "Solo",
                    "AlbumArtistId": "artist-xyz",
                    "AlbumArtists": [{"Id": "artist-xyz", "Name": "Solo"}],
                    "ArtistItems": [{"Id": "artist-xyz", "Name": "Solo"}],
                    "ProductionYear": 2020, "RunTimeTicks": 1800000000000u64,
                    "ChildCount": 11, "Genres": ["Indie"],
                    "ImageTags": { "Primary": "imgA" }
                },
                {
                    "Id": "al2", "Name": "Sophomore Slump", "Type": "MusicAlbum",
                    "AlbumArtist": "Solo",
                    "AlbumArtistId": "artist-xyz",
                    "AlbumArtists": [{"Id": "artist-xyz", "Name": "Solo"}],
                    "ArtistItems": [{"Id": "artist-xyz", "Name": "Solo"}],
                    "ProductionYear": 2022, "RunTimeTicks": 2400000000000u64,
                    "ChildCount": 14, "Genres": ["Indie"],
                    "ImageTags": { "Primary": "imgB" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .albums_by_artist("artist-xyz", crate::Paging::new(0, 20))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 2);
    assert_eq!(page.total_count, 2);
    assert_eq!(page.items[0].name, "Debut");
    assert_eq!(page.items[0].artist_id.as_deref(), Some("artist-xyz"));
    assert_eq!(page.items[1].name, "Sophomore Slump");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(
        q.contains("AlbumArtistIds=artist-xyz"),
        "should scope by AlbumArtistIds, got: {q}"
    );
    // "AlbumArtistIds=" contains "ArtistIds=" as a substring, so check
    // for the broader filter either as the first param or after an `&`.
    assert!(
        !q.starts_with("ArtistIds=") && !q.contains("&ArtistIds="),
        "should NOT use the broader ArtistIds filter (would include compilations), got: {q}"
    );
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=20"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
}

/// `albums_by_artist` with `limit = 0` should clamp to 1, matching the
/// other `Paging`-taking endpoints (`albums`, `artists`, `list_tracks`,
/// `albums_by_artist`, ...). The server treats `Limit=0` as "no limit"
/// which would blow response size on an artist with a deep back
/// catalogue; clamping keeps the contract uniform.
#[tokio::test]
async fn albums_by_artist_clamps_zero_limit_to_one() {
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
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .albums_by_artist("artist-xyz", crate::Paging::new(0, 0))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(
        q.contains("Limit=1"),
        "zero limit should clamp to 1, got: {q}"
    );
}

// ============================================================================
// artists endpoint — MusicArtist filter regression (UX fix)
// ============================================================================

/// Regression for the "0 artists" bug. Some Jellyfin 10.11 builds return
/// zero items from `/Artists/AlbumArtists` when `IncludeItemTypes=MusicArtist`
/// is supplied — verified live against music.skalthoff.com. The endpoint
/// already scopes to MusicArtist by path, so the filter is redundant *and*
/// breaks the server-side query builder's AND-intersection on some configs.
/// Assert the query no longer carries that parameter.
#[tokio::test]
async fn artists_does_not_send_include_item_types_music_artist() {
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "a1", "Name": "Solo", "Type": "MusicArtist" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.artists(crate::Paging::new(0, 50)).await.unwrap();
    assert_eq!(page.items.len(), 1);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(
        !q.contains("IncludeItemTypes=MusicArtist"),
        "artists() must NOT send IncludeItemTypes=MusicArtist (breaks live Jellyfin 10.11), got: {q}"
    );
    // Sanity: all the other fields we depend on are still present.
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
}

// ============================================================================
// with_client releases `Inner` before HTTP I/O — main-thread unblocking
// ============================================================================

/// When one thread is mid-`list_albums` (holding a 400ms HTTP round-trip), a
/// concurrent `image_url` call on another thread must NOT wait for that HTTP
/// to complete. Before the fix, `with_client` held `Inner` across
/// `runtime.block_on(...)`, so every main-thread FFI (auth_header, image_url,
/// or a second network call) serialized behind whichever background
/// pagination fetch was in flight. That's what caused the UI beach-balls.
#[tokio::test]
async fn with_client_releases_inner_lock_before_http() {
    install_mock_keyring();
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok",
            "ServerId": "server-lock-release",
            "ServerName": "S",
            "User": {
                "Id": "u1", "Name": "n",
                "ServerId": "server-lock-release",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    // Slow enough that we get a clear signal if the test thread serializes
    // behind it, but not so slow that CI runs glacially.
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "Items": [], "TotalRecordCount": 0 }))
                .set_delay(std::time::Duration::from_millis(400)),
        )
        .mount(&server)
        .await;

    let server_url = server.uri();
    // Per-test tempdir avoids parallel-test SQLite contention with other
    // tests that share the default data_dir (see #781).
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();
    tokio::task::spawn_blocking(move || {
        let core = std::sync::Arc::new(
            LyrebirdCore::new(CoreConfig {
                data_dir: tmp_path,
                device_name: "Test".into(),
            })
            .unwrap(),
        );
        core.login(server_url, "lockrel-user".into(), "pw".into())
            .expect("login should succeed");

        // Thread A: fires the slow list_albums. Pre-fix, its FFI held
        // `Inner` for the full 400ms HTTP round-trip.
        let core_a = core.clone();
        let a = std::thread::spawn(move || {
            let start = std::time::Instant::now();
            let _ = core_a.list_albums(0, 10);
            start.elapsed()
        });

        // Give Thread A a head start so it's genuinely mid-flight when
        // Thread B runs.
        std::thread::sleep(std::time::Duration::from_millis(50));

        // Thread B: image_url is pure URL math — no network. It goes
        // through `with_client`, so before the fix it blocked on Inner
        // for the remainder of Thread A's HTTP.
        let start = std::time::Instant::now();
        core.image_url("item-1".into(), Some("tag-1".into()), 400)
            .expect("image_url should succeed");
        let b_elapsed = start.elapsed();

        let a_elapsed = a.join().expect("thread A panicked");

        // The 400ms mock delay minus the 50ms head start leaves ~350ms
        // of block-time pre-fix; 200ms is a comfortable regression cap
        // that still absorbs CI jitter.
        assert!(
            b_elapsed < std::time::Duration::from_millis(200),
            "image_url blocked for {b_elapsed:?} while list_albums held the \
             mutex (list_albums took {a_elapsed:?}); Inner must be released \
             before HTTP I/O"
        );
        // Sanity: the slow mock really did delay Thread A.
        assert!(
            a_elapsed >= std::time::Duration::from_millis(300),
            "slow list_albums mock should have taken >= 300ms; was {a_elapsed:?}"
        );
    })
    .await
    .expect("spawn_blocking panicked");
}

// ============================================================================
// tracks_by_artist (#156)
// ============================================================================

#[tokio::test]
async fn tracks_by_artist_filters_by_album_artist_with_catalog_sort() {
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
        .and(query_param("AlbumArtistIds", "artist-77"))
        .and(query_param("Recursive", "true"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param("SortBy", "Album,ParentIndexNumber,IndexNumber"))
        .and(query_param("SortOrder", "Ascending,Ascending,Ascending"))
        .and(query_param("EnableUserData", "true"))
        .and(query_param("Limit", "500"))
        .and(query_param("StartIndex", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "t1", "Name": "Track One", "Type": "Audio", "AlbumId": "a1", "AlbumArtist": "X" },
                { "Id": "t2", "Name": "Track Two", "Type": "Audio", "AlbumId": "a1", "AlbumArtist": "X" }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .tracks_by_artist("artist-77", Paging::new(0, 500))
        .await
        .unwrap();
    assert_eq!(page.total_count, 2);
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].id, "t1");
    assert_eq!(page.items[1].id, "t2");
}

#[tokio::test]
async fn tracks_by_artist_propagates_pagination_offset() {
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
        .and(query_param("AlbumArtistIds", "artist-77"))
        .and(query_param("Limit", "50"))
        .and(query_param("StartIndex", "100"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 250
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .tracks_by_artist("artist-77", Paging::new(100, 50))
        .await
        .unwrap();
    assert_eq!(
        page.total_count, 250,
        "server-reported total wins over page len"
    );
    assert!(page.items.is_empty());
}

#[tokio::test]
async fn tracks_by_artist_without_session_returns_not_authenticated() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .tracks_by_artist("artist-77", Paging::new(0, 500))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    assert!(
        server.received_requests().await.unwrap().is_empty(),
        "guard must short-circuit before any HTTP call"
    );
}

#[tokio::test]
async fn album_tracks_parses_negative_bitrate_sentinel() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "user", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Yona", "Type": "Audio",
                    "AlbumId": "a1", "Container": "flac", "Bitrate": -1000,
                    "RunTimeTicks": 2220000000u64
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("user", "pw").await.unwrap();
    let tracks = client.album_tracks("a1").await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].bitrate, Some(-1000));
}

// ---- #252: Recently Discovered Artists (DateCreated-desc artists) ----

#[tokio::test]
async fn recently_added_artists_builds_query_and_parses() {
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "ar1", "Name": "Zillion", "Type": "MusicArtist",
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 3213
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .recently_added_artists(Paging::new(0, 12))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 3213);
    assert_eq!(page.items[0].name, "Zillion");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    // The whole point of #252: newest-added artists first.
    assert!(q.contains("SortBy=DateCreated"), "query: {q}");
    assert!(q.contains("SortOrder=Descending"), "query: {q}");
    // Otherwise identical to the plain `artists` query.
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=12"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
    // Same `IncludeItemTypes`-absence contract as `artists` (see
    // `artists_does_not_send_include_item_types_music_artist`).
    assert!(
        !q.contains("IncludeItemTypes="),
        "unexpected IncludeItemTypes: {q}"
    );
}

#[tokio::test]
async fn recently_added_artists_honours_paging_offset() {
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .recently_added_artists(Paging::new(40, 20))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("StartIndex=40"), "query: {q}");
    assert!(q.contains("Limit=20"), "query: {q}");
    assert!(q.contains("SortBy=DateCreated"), "query: {q}");
}

#[tokio::test]
async fn plain_artists_query_still_sorts_by_sort_name_ascending() {
    // Guards the #252 refactor: extracting `album_artists_sorted` must not
    // change the default `artists()` sort away from SortName ascending.
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
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.artists(Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
}
