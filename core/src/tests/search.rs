use super::*;

#[tokio::test]
async fn search_hints_builds_expected_query_and_parses() {
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
        .and(path("/Search/Hints"))
        .and(query_param("userId", "u1"))
        .and(query_param("searchTerm", "colleen"))
        .and(query_param(
            "includeItemTypes",
            "Audio,MusicAlbum,MusicArtist,Playlist",
        ))
        .and(query_param("limit", "24"))
        .and(query_param("startIndex", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [
                {
                    "Id": "artist-1",
                    "Name": "Colleen",
                    "Type": "MusicArtist",
                    "MediaType": "Unknown",
                    "MatchedTerm": "colleen",
                    "PrimaryImageTag": "img-artist",
                    "Artists": []
                },
                {
                    "Id": "album-1",
                    "Name": "The Weighing of the Heart",
                    "Type": "MusicAlbum",
                    "MediaType": "Unknown",
                    "AlbumArtist": "Colleen",
                    "Artists": ["Colleen"],
                    "MatchedTerm": "colleen",
                    "PrimaryImageTag": "img-album",
                    "ProductionYear": 2013,
                    "RunTimeTicks": 18000000000u64
                },
                {
                    "Id": "track-1",
                    "Name": "Push the Boat Onto the Sand",
                    "Type": "Audio",
                    "MediaType": "Audio",
                    "Album": "The Weighing of the Heart",
                    "AlbumId": "album-1",
                    "AlbumArtist": "Colleen",
                    "Artists": ["Colleen"],
                    "MatchedTerm": "colleen",
                    "IndexNumber": 3,
                    "ParentIndexNumber": 1,
                    "RunTimeTicks": 2220000000u64,
                    "PrimaryImageTag": "img-track"
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search_hints("colleen", Paging::new(0, 24))
        .await
        .unwrap();

    assert_eq!(results.total_record_count, 3);
    assert_eq!(results.search_hints.len(), 3);

    let artist = &results.search_hints[0];
    assert_eq!(artist.id, "artist-1");
    assert_eq!(artist.name, "Colleen");
    assert_eq!(artist.kind.as_deref(), Some("MusicArtist"));
    assert_eq!(artist.matched_term.as_deref(), Some("colleen"));
    assert_eq!(artist.primary_image_tag.as_deref(), Some("img-artist"));

    let album = &results.search_hints[1];
    assert_eq!(album.kind.as_deref(), Some("MusicAlbum"));
    assert_eq!(album.album_artist.as_deref(), Some("Colleen"));
    assert_eq!(album.production_year, Some(2013));
    assert_eq!(album.runtime_ticks, Some(18_000_000_000));

    let track = &results.search_hints[2];
    assert_eq!(track.kind.as_deref(), Some("Audio"));
    assert_eq!(track.media_type.as_deref(), Some("Audio"));
    assert_eq!(track.album.as_deref(), Some("The Weighing of the Heart"));
    assert_eq!(track.album_id.as_deref(), Some("album-1"));
    assert_eq!(track.index_number, Some(3));
    assert_eq!(track.parent_index_number, Some(1));
}

/// Verify that the three image-related fields added in #596
/// (`ThumbImageTag`, `BackdropImageTag`, `PrimaryImageAspectRatio`) are
/// correctly deserialised from the Jellyfin `SearchHint` DTO.
#[tokio::test]
async fn search_hint_parses_image_fields() {
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
        .and(path("/Search/Hints"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [
                {
                    "Id": "album-99",
                    "Name": "Wide Screen Album",
                    "Type": "MusicAlbum",
                    "MediaType": "Unknown",
                    "Artists": [],
                    "PrimaryImageTag": "img-primary",
                    "ThumbImageTag": "img-thumb",
                    "BackdropImageTag": "img-backdrop",
                    "PrimaryImageAspectRatio": 1.777_777_8_f64
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search_hints("Wide Screen", Paging::new(0, 8))
        .await
        .unwrap();

    assert_eq!(results.total_record_count, 1);
    let hint = &results.search_hints[0];
    assert_eq!(hint.primary_image_tag.as_deref(), Some("img-primary"));
    assert_eq!(hint.thumb_image_tag.as_deref(), Some("img-thumb"));
    assert_eq!(hint.backdrop_image_tag.as_deref(), Some("img-backdrop"));
    let ratio = hint.primary_image_aspect_ratio.expect("aspect ratio");
    assert!((ratio - 1.777_777_8_f64).abs() < 1e-5, "ratio: {ratio}");
}

/// Hints whose optional image fields are absent must deserialise cleanly
/// (all three fields must be `None`).
#[tokio::test]
async fn search_hint_image_fields_absent_is_none() {
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
        .and(path("/Search/Hints"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [
                {
                    "Id": "artist-42",
                    "Name": "No Image Artist",
                    "Type": "MusicArtist",
                    "MediaType": "Unknown",
                    "Artists": []
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search_hints("No Image", Paging::new(0, 8))
        .await
        .unwrap();

    let hint = &results.search_hints[0];
    assert!(hint.thumb_image_tag.is_none(), "thumb should be None");
    assert!(hint.backdrop_image_tag.is_none(), "backdrop should be None");
    assert!(
        hint.primary_image_aspect_ratio.is_none(),
        "aspect ratio should be None"
    );
}

#[tokio::test]
async fn search_hints_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .search_hints("anything", Paging::new(0, 24))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn search_hints_clamps_zero_limit_to_one() {
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
        .and(path("/Search/Hints"))
        .and(query_param("limit", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client.search_hints("x", Paging::new(0, 0)).await.unwrap();
    assert_eq!(results.total_record_count, 0);
    assert!(results.search_hints.is_empty());
}

#[tokio::test]
async fn search_paginates_and_exposes_total_record_count() {
    // The combined-type search endpoint must forward offset/limit as
    // StartIndex/Limit and surface TotalRecordCount so the UI can offer
    // "Show all N results" affordances. Items are bucketed by `Type` into
    // the SearchResults struct's three arrays.
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
        .and(query_param("SearchTerm", "mountain"))
        .and(query_param(
            "IncludeItemTypes",
            "MusicArtist,MusicAlbum,Audio",
        ))
        .and(query_param("Limit", "25"))
        .and(query_param("StartIndex", "10"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "artist-1", "Name": "Mountain Goats", "Type": "MusicArtist",
                    "ImageTags": { "Primary": "a1" }
                },
                {
                    "Id": "album-1", "Name": "All Hail West Texas", "Type": "MusicAlbum",
                    "AlbumArtist": "The Mountain Goats", "Artists": ["The Mountain Goats"],
                    "ProductionYear": 2002, "ChildCount": 14,
                    "ImageTags": { "Primary": "b1" }
                },
                {
                    "Id": "track-1", "Name": "The Best Ever Death Metal Band Out Of Denton", "Type": "Audio",
                    "AlbumId": "album-1", "Album": "All Hail West Texas",
                    "AlbumArtist": "The Mountain Goats", "Artists": ["The Mountain Goats"],
                    "RunTimeTicks": 1680000000u64,
                    "ImageTags": { "Primary": "c1" }
                }
            ],
            "TotalRecordCount": 147
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search("mountain", Paging::new(10, 25))
        .await
        .unwrap();

    assert_eq!(results.total_record_count, 147);
    assert_eq!(results.artists.len(), 1);
    assert_eq!(results.albums.len(), 1);
    assert_eq!(results.tracks.len(), 1);
    assert_eq!(results.artists[0].name, "Mountain Goats");
    assert_eq!(results.albums[0].name, "All Hail West Texas");
    assert_eq!(
        results.tracks[0].name,
        "The Best Ever Death Metal Band Out Of Denton"
    );
    // The fixture deliberately populates ProductionYear / ChildCount /
    // ImageTags / AlbumId; assert the parsed-into-model fields so a regression
    // in the search result mapping (not just bucketing) is caught.
    assert_eq!(results.albums[0].year, Some(2002));
    assert_eq!(results.albums[0].track_count, 14);
    assert_eq!(results.albums[0].image_tag.as_deref(), Some("b1"));
    assert_eq!(results.artists[0].image_tag.as_deref(), Some("a1"));
    assert_eq!(results.tracks[0].album_id.as_deref(), Some("album-1"));
    assert_eq!(results.tracks[0].image_tag.as_deref(), Some("c1"));
}

#[tokio::test]
async fn search_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .search("anything", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn search_sends_enable_user_data_and_expanded_fields() {
    // Regression for #574: search must include EnableUserData=true and
    // Fields containing UserData + AlbumId so that favorites state and
    // track-to-album links are populated in the response.
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
        .and(query_param("SearchTerm", "radio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    let (user, secret) = test_credentials();
    client.authenticate_by_name(user, secret).await.unwrap();
    client.search("radio", Paging::new(0, 10)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(
        q.contains("EnableUserData=true"),
        "missing EnableUserData=true in query: {q}"
    );
    assert!(
        q.contains("UserData"),
        "Fields must include UserData in query: {q}"
    );
    assert!(
        q.contains("AlbumId"),
        "Fields must include AlbumId in query: {q}"
    );
}

#[tokio::test]
async fn search_hints_forwards_offset_as_start_index() {
    // Regression check for pagination on the typeahead: `paging.offset`
    // must appear as `startIndex` on the outbound request so "Show more"
    // can fetch the next page.
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
        .and(path("/Search/Hints"))
        .and(query_param("limit", "20"))
        .and(query_param("startIndex", "40"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [],
            "TotalRecordCount": 100
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client.search_hints("q", Paging::new(40, 20)).await.unwrap();
    assert_eq!(results.total_record_count, 100);
}
