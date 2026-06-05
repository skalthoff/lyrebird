use super::*;

// ---------------------------------------------------------------------------
// Discovery: instant_mix / suggestions / similar_* / frequently_played
// ---------------------------------------------------------------------------

#[tokio::test]
async fn instant_mix_builds_query_and_parses() {
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
        .and(path("/Items/seed-1/InstantMix"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Radio One", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Starter",
                    "AlbumArtist": "DJ Seed", "Artists": ["DJ Seed"],
                    "RunTimeTicks": 2000000000u64,
                    "UserData": { "IsFavorite": true, "PlayCount": 9 },
                    "ImageTags": { "Primary": "imgA" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.instant_mix("seed-1", 25).await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].name, "Radio One");
    // The fixture populates the full UserData / album / artist / image
    // projection, so verify the field mapping (not just len + name) — a
    // regression dropping any of these from the InstantMix parse is caught.
    assert_eq!(tracks[0].album_id.as_deref(), Some("a1"));
    assert_eq!(tracks[0].artist_name, "DJ Seed");
    assert_eq!(tracks[0].play_count, 9);
    assert!(tracks[0].is_favorite);
    assert_eq!(tracks[0].image_tag.as_deref(), Some("imgA"));

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    assert!(q.contains("Limit=25"), "query: {q}");
}

#[tokio::test]
async fn instant_mix_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.instant_mix("seed-1", 25).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn suggestions_builds_query_and_parses() {
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
        .and(path("/Items/Suggestions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "You Might Like", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Discover",
                    "AlbumArtist": "New Artist", "Artists": ["New Artist"],
                    "RunTimeTicks": 1800000000u64,
                    "ImageTags": { "Primary": "img" }
                },
                // A non-Audio row the server slipped into the suggestions
                // response. The client-side `kind == "Audio"` filter must drop
                // it so a MusicAlbum never renders as a minute-long "track".
                {
                    "Id": "alb1", "Name": "Discover (Album)", "Type": "MusicAlbum",
                    "ChildCount": 10
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.suggestions(12).await.unwrap();
    // The MusicAlbum row is filtered out client-side — only the Audio track
    // survives. This pins the response-side Audio filter (a regression that
    // removes it would let the album through).
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].name, "You Might Like");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    // Must filter by item type, not MediaType, so only music items are returned
    assert!(
        q.contains("IncludeItemTypes=Audio"),
        "expected IncludeItemTypes in query: {q}"
    );
    assert!(
        !q.contains("MusicAlbum"),
        "must request Audio only; MusicAlbum rows consume Limit slots and get discarded: {q}"
    );
    assert!(
        !q.contains("MediaType=Audio"),
        "must not send MediaType=Audio (returns movies+TV): {q}"
    );
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("Limit=12"), "query: {q}");
}

#[tokio::test]
async fn suggestions_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.suggestions(12).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn similar_artists_builds_query_and_parses() {
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
        .and(path("/Artists/artist-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Artist", "Type": "MusicArtist",
                    "Genres": ["Indie"],
                    "ImageTags": { "Primary": "imgSim" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let artists = client.similar_artists("artist-1", 10).await.unwrap();
    assert_eq!(artists.len(), 1);
    assert_eq!(artists[0].name, "Similar Artist");
    assert_eq!(artists[0].genres, vec!["Indie".to_string()]);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    assert!(q.contains("Limit=10"), "query: {q}");
}

#[tokio::test]
async fn similar_albums_builds_query_and_parses() {
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
        .and(path("/Albums/album-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Album", "Type": "MusicAlbum",
                    "AlbumArtist": "Sibling",
                    "ProductionYear": 2022, "ChildCount": 9,
                    "ImageTags": { "Primary": "imgAlb" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let albums = client.similar_albums("album-1", 8).await.unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].name, "Similar Album");
    assert_eq!(albums[0].track_count, 9);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=8"), "query: {q}");
    assert!(q.contains("UserId=u1"), "query: {q}");
}

#[tokio::test]
async fn similar_items_builds_query_and_parses() {
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
        .and(path("/Items/seed-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Album", "Type": "MusicAlbum",
                    "ImageTags": { "Primary": "img1" }
                },
                {
                    "Id": "t2", "Name": "Similar Track", "Type": "Audio",
                    "ImageTags": { "Primary": "img2" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let items = client.similar_items("seed-1", 20).await.unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].kind.as_deref(), Some("MusicAlbum"));
    assert_eq!(items[1].kind.as_deref(), Some("Audio"));

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Fields="), "query should include Fields: {q}");
    assert!(
        q.contains("PrimaryImageAspectRatio"),
        "Fields should include PrimaryImageAspectRatio: {q}"
    );
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn frequently_played_tracks_builds_query_and_parses() {
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
                    "Id": "t1", "Name": "On Repeat", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Stuck",
                    "AlbumArtist": "Loops", "Artists": ["Loops"],
                    "RunTimeTicks": 1800000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 99 },
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.frequently_played_tracks(50).await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].play_count, 99);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
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

// ---------------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------------

#[tokio::test]
async fn genres_builds_query_and_parses_counts() {
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
        .and(path("/Genres"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "g-1", "Name": "Ambient",
                    "SongCount": 42, "AlbumCount": 6,
                    "ImageTags": { "Primary": "imgA" }
                },
                {
                    "Id": "g-2", "Name": "Jazz",
                    "SongCount": 110, "AlbumCount": 14,
                    "ImageTags": { "Primary": "imgJ" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.genres(Paging::new(0, 100)).await.unwrap();
    assert_eq!(page.total_count, 2);
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].name, "Ambient");
    assert_eq!(page.items[0].song_count, 42);
    assert_eq!(page.items[0].album_count, 6);
    assert_eq!(page.items[1].name, "Jazz");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    assert_eq!(
        get.url.path(),
        "/Genres",
        "should call /Genres, not /MusicGenres"
    );
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("userId=u1"), "query: {q}");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    let include_types = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "IncludeItemTypes")
        .map(|(_, v)| v.into_owned())
        .expect("expected IncludeItemTypes query param");
    assert!(
        include_types.split(',').any(|t| t == "Audio"),
        "IncludeItemTypes should include Audio, got: {include_types}"
    );
    assert!(
        include_types.split(',').any(|t| t == "MusicAlbum"),
        "IncludeItemTypes should include MusicAlbum, got: {include_types}"
    );
    assert!(
        include_types.split(',').any(|t| t == "MusicArtist"),
        "IncludeItemTypes should include MusicArtist (production sends all three), got: {include_types}"
    );
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ItemCounts"),
        "Fields should include ItemCounts, got: {fields}"
    );
}

#[tokio::test]
async fn items_by_genre_builds_query_and_parses() {
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
                    "Id": "a1", "Name": "Jazzy", "Type": "MusicAlbum",
                    "AlbumArtist": "Sax Man",
                    "ProductionYear": 2020, "ChildCount": 10,
                    "ImageTags": { "Primary": "imgJ" }
                }
            ],
            "TotalRecordCount": 55
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .items_by_genre("g-1", Paging::new(0, 30))
        .await
        .unwrap();
    assert_eq!(page.total_count, 55);
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].name, "Jazzy");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("GenreIds=g-1"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=30"), "query: {q}");
}

#[tokio::test]
async fn tracks_by_genre_builds_query() {
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
                    "Id": "t1", "Name": "Smooth Solo", "Type": "Audio",
                    "AlbumId": "a1", "AlbumArtist": "Sax Man"
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .tracks_by_genre("g-1", Paging::new(20, 40))
        .await
        .unwrap();
    assert_eq!(page.total_count, 1);
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "t1");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("GenreIds=g-1"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=40"), "query: {q}");
    assert!(q.contains("StartIndex=20"), "query: {q}");
    // Catalog order: album name, then disc, then track number — NOT
    // SortName-first (which scattered tracks alphabetically across albums).
    assert!(
        q.contains("SortBy=Album%2CParentIndexNumber%2CIndexNumber"),
        "query: {q}"
    );
}

#[tokio::test]
async fn tracks_by_genre_parses_pagination() {
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
                    "Id": "t1", "Name": "Track One", "Type": "Audio",
                    "AlbumId": "a1", "AlbumArtist": "Artist X"
                },
                {
                    "Id": "t2", "Name": "Track Two", "Type": "Audio",
                    "AlbumId": "a2", "AlbumArtist": "Artist Y"
                },
                {
                    "Id": "t3", "Name": "Track Three", "Type": "Audio",
                    "AlbumId": "a3", "AlbumArtist": "Artist Z"
                }
            ],
            "TotalRecordCount": 42
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .tracks_by_genre("g-1", Paging::new(0, 100))
        .await
        .unwrap();
    assert_eq!(
        page.total_count, 42,
        "server-reported total wins over page len"
    );
    assert_eq!(page.items.len(), 3);
    assert_eq!(page.items[0].id, "t1");
    assert_eq!(page.items[1].id, "t2");
    assert_eq!(page.items[2].id, "t3");
}

// ============================================================================
// suggestions defensive Type filter — #815 / auto-audit
// ============================================================================

/// Regression for the Home "You might like" shelf. Jellyfin's
/// `/Items/Suggestions` endpoint ignores `IncludeItemTypes=Audio,MusicAlbum`
/// and returns a mix of Audio, MusicAlbum, and MusicArtist items
/// (verified live against music.skalthoff.com on 2026-05-12). Non-Audio
/// items mapped through `Track::from` produce structurally broken tracks
/// with no container / no album_id, which then fail to stream. The client
/// now post-filters by `Type == "Audio"` so the downstream UI never sees
/// non-audio rows regardless of what the server returns.
#[tokio::test]
async fn suggestions_rejects_non_audio_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Simulate the live server behaviour: return a mix of Audio, MusicAlbum,
    // and MusicArtist items even though the request asks for Audio,MusicAlbum.
    Mock::given(method("GET"))
        .and(path("/Items/Suggestions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Real Track", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Discover",
                    "AlbumArtist": "Artist", "Artists": ["Artist"],
                    "RunTimeTicks": 1800000000u64
                },
                {
                    "Id": "al1", "Name": "Quite A Shame", "Type": "MusicAlbum",
                    "AlbumArtist": "Some Artist"
                },
                {
                    "Id": "ar1", "Name": "Boston", "Type": "MusicArtist"
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.suggestions(20).await.unwrap();

    // Only the Audio entry survives; the MusicAlbum / MusicArtist items
    // would otherwise produce unplayable Track objects in the Home shelf.
    assert_eq!(tracks.len(), 1, "non-Audio rows must be dropped");
    assert_eq!(tracks[0].id, "t1");
    assert_eq!(tracks[0].name, "Real Track");
}

// ===========================================================================
// Audit follow-ups (2.0 polish)
// ===========================================================================

// ---------------------------------------------------------------------------
// Unauthenticated-session guards for the discovery / genre endpoints that
// previously lacked a `*_requires_authenticated_session` test (mirrors the
// existing `instant_mix_requires_authenticated_session`). Each must
// short-circuit with NotAuthenticated before issuing any HTTP request.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn similar_artists_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.similar_artists("artist-1", 10).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn similar_albums_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.similar_albums("album-1", 10).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn similar_items_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.similar_items("item-1", 10).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn genres_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.genres(Paging::new(0, 50)).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn items_by_genre_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .items_by_genre("genre-1", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn tracks_by_genre_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .tracks_by_genre("genre-1", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn frequently_played_tracks_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.frequently_played_tracks(50).await.unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}
