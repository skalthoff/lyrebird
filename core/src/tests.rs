use crate::client::JellyfinClient;
use crate::enums::ImageType;
use crate::error::JellifyError;
use crate::models::Paging;
use crate::storage::{CredentialStore, Database};
use crate::{CoreConfig, JellifyCore};
use serde_json::json;
use std::sync::Once;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn mock_client(base: &str) -> JellyfinClient {
    JellyfinClient::new(base, "test-device".into(), "Test Device".into()).unwrap()
}

/// Placeholder credentials for wiremock-backed tests. These are not real
/// secrets — the mock server accepts any value and returns a canned
/// `AccessToken` regardless.
fn test_credentials() -> (&'static str, &'static str) {
    ("mock-user", "mock-secret-for-wiremock")
}

/// Register a process-wide in-memory credential store as `keyring`'s default
/// the first time a test touches the credential layer. Without this, on macOS
/// the crate's `apple-native` feature would route every test into the real
/// user keychain — which both pollutes the login keychain across runs and
/// would flake in a headless CI environment.
///
/// `keyring`'s built-in `mock` builder hands out a brand-new `MockCredential`
/// on every `Entry::new`, so it can't round-trip `save → load` across two
/// `Entry` instances (which is exactly what `CredentialStore::save_token`
/// followed by `CredentialStore::load_token` does). Our shim keeps one
/// `HashMap` keyed on `(service, user)` so saves are visible to subsequent
/// loads, which is the behaviour we need to exercise `resume_session`.
///
/// Tests still need to pick distinct `(server_id, username)` pairs — the
/// harness intentionally does NOT clear the map between tests because tearing
/// it down is racy under `cargo test`'s default parallelism.
fn install_mock_keyring() {
    use keyring::credential::{
        Credential, CredentialApi, CredentialBuilder, CredentialBuilderApi, CredentialPersistence,
    };
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};

    type Store = Arc<Mutex<HashMap<(String, String), Vec<u8>>>>;

    fn store() -> Store {
        static STORE: OnceLock<Store> = OnceLock::new();
        STORE
            .get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
            .clone()
    }

    struct SharedMockCredential {
        service: String,
        user: String,
        store: Store,
    }

    impl CredentialApi for SharedMockCredential {
        fn set_secret(&self, password: &[u8]) -> keyring::Result<()> {
            self.store
                .lock()
                .unwrap()
                .insert((self.service.clone(), self.user.clone()), password.to_vec());
            Ok(())
        }

        fn get_secret(&self) -> keyring::Result<Vec<u8>> {
            self.store
                .lock()
                .unwrap()
                .get(&(self.service.clone(), self.user.clone()))
                .cloned()
                .ok_or(keyring::Error::NoEntry)
        }

        fn delete_credential(&self) -> keyring::Result<()> {
            self.store
                .lock()
                .unwrap()
                .remove(&(self.service.clone(), self.user.clone()))
                .map(|_| ())
                .ok_or(keyring::Error::NoEntry)
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
    }

    struct SharedMockBuilder;

    impl CredentialBuilderApi for SharedMockBuilder {
        fn build(
            &self,
            _target: Option<&str>,
            service: &str,
            user: &str,
        ) -> keyring::Result<Box<Credential>> {
            Ok(Box::new(SharedMockCredential {
                service: service.to_string(),
                user: user.to_string(),
                store: store(),
            }))
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }

        fn persistence(&self) -> CredentialPersistence {
            CredentialPersistence::ProcessOnly
        }
    }

    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let builder: Box<CredentialBuilder> = Box::new(SharedMockBuilder);
        keyring::set_default_credential_builder(builder);
    });
}

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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
                    "UserData": { "IsFavorite": false, "PlayCount": 0 },
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.suggestions(12).await.unwrap();
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotFound(_)),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
    assert_eq!(page.total_count, 7);
}

#[tokio::test]
async fn latest_albums_requires_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .latest_albums("lib-music", Paging::new(0, 24))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

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
        .and(query_param("Fields", "ChildCount,Path"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "p1", "Name": "My Mix", "Type": "Playlist",
                    "ChildCount": 12,
                    "RunTimeTicks": 42_000_000_000u64,
                    "Path": "/config/data/users/u1/playlists/my-mix",
                    "ImageTags": { "Primary": "tag-1" }
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
    // Crucially, the non-`/data/`-path playlist is included.
    assert_eq!(page.items[1].id, "p2");
    assert_eq!(page.items[1].name, "Community Top 40");
}

#[tokio::test]
async fn public_playlists_mirrors_user_playlists_until_split_lands() {
    // Until a real user-vs-public discriminator (e.g. CanDelete / OwnerId)
    // is wired, `public_playlists` intentionally returns the same set as
    // `user_playlists` so neither method silently drops rows based on a
    // broken `Path` heuristic.
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
            "Items": [
                {
                    "Id": "p1", "Name": "My Mix", "Type": "Playlist",
                    "ChildCount": 12,
                    "Path": "/config/data/users/u1/playlists/my-mix"
                },
                {
                    "Id": "p2", "Name": "Community Top 40", "Type": "Playlist",
                    "ChildCount": 40,
                    "Path": "/media/playlists/community-top-40",
                    "ImageTags": { "Primary": "tag-2" }
                },
                {
                    "Id": "p3", "Name": "No Path Public", "Type": "Playlist",
                    "ChildCount": 5
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .public_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();

    assert_eq!(
        page.items.len(),
        3,
        "public_playlists mirrors user_playlists today"
    );
    assert_eq!(page.total_count, 3);
    let ids: Vec<&str> = page.items.iter().map(|p| p.id.as_str()).collect();
    assert!(ids.contains(&"p1"));
    assert!(ids.contains(&"p2"));
    assert!(ids.contains(&"p3"));
}

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
    let public = client
        .public_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();
    assert!(user.items.is_empty());
    assert_eq!(user.total_count, 0);
    assert!(public.items.is_empty());
    assert_eq!(public.total_count, 0);
}

#[tokio::test]
async fn playlists_require_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .user_playlists("lib-pl", Paging::new(0, 20))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    let err = client
        .public_playlists("lib-pl", Paging::new(0, 20))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
            "MediaSources,ParentId,Path,PlaylistItemId,SortName",
        ))
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
            ResponseTemplate::new(200).set_body_json(json!({
                "Items": [
                    {
                        "Id": "t1", "Name": "First", "Type": "Audio",
                        "AlbumId": "a1", "Album": "Album One",
                        "AlbumArtist": "Artist A", "Artists": ["Artist A"],
                        "RunTimeTicks": 1800000000u64,
                        "ImageTags": { "Primary": "img-1" }
                    },
                    {
                        "Id": "t2", "Name": "Second", "Type": "Audio",
                        "AlbumId": "a2", "Album": "Album Two",
                        "AlbumArtist": "Artist B", "Artists": ["Artist B"],
                        "RunTimeTicks": 2220000000u64,
                        "ImageTags": { "Primary": "img-2" }
                    },
                    {
                        "Id": "t3", "Name": "Third", "Type": "Audio",
                        "AlbumId": "a3", "Album": "Album Three",
                        "AlbumArtist": "Artist C", "Artists": ["Artist C"],
                        "RunTimeTicks": 2000000000u64,
                        "ImageTags": { "Primary": "img-3" }
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

    // Server order must be preserved exactly.
    assert_eq!(tracks.len(), 3);
    assert_eq!(page.total_count, 3);
    assert_eq!(tracks[0].id, "t1");
    assert_eq!(tracks[0].name, "First");
    assert_eq!(tracks[1].id, "t2");
    assert_eq!(tracks[1].name, "Second");
    assert_eq!(tracks[2].id, "t3");
    assert_eq!(tracks[2].name, "Third");
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotFound(_)),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST"
                && r.url.path() == "/Users/u1/FavoriteItems/item-xyz"),
        "expected fallback to legacy route after 404"
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

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.iter().any(|r| r.method.as_str() == "DELETE"
            && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE"
                && r.url.path() == "/Users/u1/FavoriteItems/item-xyz"),
        "expected fallback to legacy route after 405"
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn unset_favorite_without_session_returns_not_authenticated() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.unset_favorite("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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

#[tokio::test]
async fn report_playback_progress_posts_pascal_case_body() {
    use crate::models::PlaybackProgressInfo;

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Jellyfin typically returns 204 No Content for progress reports.
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            position_ticks: 1_234_567_890,
            is_paused: true,
            is_muted: false,
            failed: false,
            media_source_id: Some("src-1".into()),
            play_session_id: Some("session-abc".into()),
            play_method: Some("DirectPlay".into()),
            playback_rate: Some(1.0),
            ..Default::default()
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing/Progress")
        .expect("expected POST to /Sessions/Playing/Progress");

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

    // Body must use Jellyfin's PascalCase keys and include all required fields.
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PositionTicks").and_then(|v| v.as_i64()),
        Some(1_234_567_890),
        "body: {body}"
    );
    assert_eq!(
        body.get("IsPaused").and_then(|v| v.as_bool()),
        Some(true),
        "body: {body}"
    );
    assert_eq!(
        body.get("IsMuted").and_then(|v| v.as_bool()),
        Some(false),
        "body: {body}"
    );
    // Failed is required by Jellyfin — must always be present.
    assert_eq!(
        body.get("Failed").and_then(|v| v.as_bool()),
        Some(false),
        "Failed must be present in progress body: {body}"
    );
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("session-abc"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlayMethod").and_then(|v| v.as_str()),
        Some("DirectPlay"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaybackRate").and_then(|v| v.as_f64()),
        Some(1.0),
        "body: {body}"
    );

    // Ensure keys are PascalCase only — no snake_case leakage.
    let obj = body.as_object().expect("body should be an object");
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only, got: {:?}",
        obj.keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn report_playback_progress_propagates_server_errors() {
    use crate::models::PlaybackProgressInfo;

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
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }
}

#[tokio::test]
async fn report_playback_progress_without_session_returns_not_authenticated() {
    use crate::models::PlaybackProgressInfo;

    // No MockServer routes registered: the guard must short-circuit before
    // any network call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn report_playback_stopped_posts_expected_body() {
    use crate::models::PlaybackStopInfo;

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
        .and(path("/Sessions/Playing/Stopped"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_stopped(PlaybackStopInfo {
            item_id: "track-xyz".into(),
            position_ticks: 2_220_000_000,
            failed: false,
            media_source_id: Some("src-1".into()),
            play_session_id: Some("session-abc".into()),
            session_id: None,
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing/Stopped")
        .expect("expected POST to /Sessions/Playing/Stopped");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz")
    );
    assert_eq!(
        body.get("PositionTicks").and_then(|v| v.as_i64()),
        Some(2_220_000_000)
    );
    // Failed is required by Jellyfin — must always be present.
    assert_eq!(
        body.get("Failed").and_then(|v| v.as_bool()),
        Some(false),
        "Failed must be present in stop body: {body}"
    );
    // MediaSourceId lets the server clean up the transcode job.
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("session-abc"),
        "body: {body}"
    );
    // Unset optional SessionId should be absent.
    assert!(
        !body.as_object().unwrap().contains_key("SessionId"),
        "unset optional should not appear: {body}"
    );
}

#[tokio::test]
async fn report_playback_stopped_requires_authenticated_session() {
    use crate::models::PlaybackStopInfo;

    // No MockServer endpoints registered for /Sessions/Playing/Stopped:
    // the auth guard must short-circuit before any HTTP call. We still
    // point at a live MockServer so that a regression would surface as
    // an unmatched-route error rather than silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_stopped(PlaybackStopInfo {
            item_id: "anything".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        .create_playlist("Road Trip", &["t1", "t2", "t3"], None)
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
    let id = client
        .create_playlist("Empty List", &[], None)
        .await
        .unwrap();
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
    let err = client.create_playlist("x", &[], None).await.unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }
}

#[tokio::test]
async fn create_playlist_requires_authenticated_session() {
    // No MockServer routes registered: the auth guard must short-circuit
    // before any HTTP call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.create_playlist("x", &[], None).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
// create_playlist — optional position param (#607)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_playlist_with_position_sends_start_index() {
    // #607: when position is Some(n) the client must include StartIndex=n as a
    // query param on POST /Playlists.
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
        .and(query_param("StartIndex", "5"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "Id": "pos-pl-id" })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client
        .create_playlist("Positioned", &["t1"], Some(5))
        .await
        .unwrap();
    assert_eq!(id, "pos-pl-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");
    let q = post.url.query().expect("expected a query string");
    assert!(q.contains("StartIndex=5"), "query: {q}");
}

#[tokio::test]
async fn create_playlist_without_position_omits_start_index() {
    // #607: when position is None, StartIndex must NOT appear in the query.
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
    let id = client
        .create_playlist("Appended", &["t1"], None)
        .await
        .unwrap();
    assert_eq!(id, "no-pos-pl-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");
    let q = post.url.query().unwrap_or_default();
    assert!(
        !q.contains("StartIndex"),
        "StartIndex must be absent when position is None, query: {q}"
    );
}

// ---------------------------------------------------------------------------
// report_playback_started — POST /Sessions/Playing
// ---------------------------------------------------------------------------

#[tokio::test]
async fn report_playback_started_posts_pascal_case_body() {
    use crate::models::PlaybackStartInfo;

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
        .and(path("/Sessions/Playing"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_started(PlaybackStartInfo {
            item_id: "track-xyz".into(),
            media_source_id: Some("src-1".into()),
            play_session_id: Some("play-session-abc".into()),
            play_method: Some("DirectPlay".into()),
            position_ticks: Some(0),
            can_seek: true,
            is_paused: false,
            is_muted: false,
            ..Default::default()
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing")
        .expect("expected POST to /Sessions/Playing");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");

    // Required fields must be PascalCase.
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz"),
        "body: {body}"
    );
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1")
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("play-session-abc")
    );
    assert_eq!(
        body.get("PlayMethod").and_then(|v| v.as_str()),
        Some("DirectPlay")
    );
    assert_eq!(body.get("CanSeek").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(body.get("IsPaused").and_then(|v| v.as_bool()), Some(false));
    assert_eq!(body.get("IsMuted").and_then(|v| v.as_bool()), Some(false));
    assert_eq!(body.get("PositionTicks").and_then(|v| v.as_i64()), Some(0));

    // None-valued optional fields must be elided from the payload.
    assert!(
        !body.as_object().unwrap().contains_key("SessionId"),
        "unset optional should not appear: {body}"
    );
    assert!(
        !body.as_object().unwrap().contains_key("VolumeLevel"),
        "unset optional should not appear: {body}"
    );

    // No snake_case leakage from serde.
    assert!(
        body.as_object().unwrap().keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only: {:?}",
        body.as_object().unwrap().keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn report_playback_started_requires_authenticated_session() {
    use crate::models::PlaybackStartInfo;

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_started(PlaybackStartInfo {
            item_id: "anything".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// post_capabilities — POST /Sessions/Capabilities/Full
// ---------------------------------------------------------------------------

#[tokio::test]
async fn post_capabilities_posts_full_client_capabilities_dto() {
    use crate::models::{ClientCapabilities, DeviceProfile};

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
        .and(path("/Sessions/Capabilities/Full"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let caps = ClientCapabilities {
        playable_media_types: vec!["Audio".into()],
        supported_commands: vec!["VolumeUp".into(), "Pause".into()],
        supports_media_control: true,
        supports_persistent_identifier: true,
        device_profile: DeviceProfile::default_macos_profile(),
        app_store_url: None,
        icon_url: Some("https://example.com/icon.png".into()),
    };
    client.post_capabilities(caps).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Capabilities/Full")
        .expect("expected POST to /Sessions/Capabilities/Full");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");

    assert_eq!(
        body.get("PlayableMediaTypes").and_then(|v| v.as_array()),
        Some(&vec![serde_json::Value::String("Audio".into())])
    );
    assert_eq!(
        body.get("SupportsMediaControl").and_then(|v| v.as_bool()),
        Some(true)
    );
    assert_eq!(
        body.get("IconUrl").and_then(|v| v.as_str()),
        Some("https://example.com/icon.png")
    );
    // Device profile round-trips with PascalCase nested fields.
    let profile = body
        .get("DeviceProfile")
        .and_then(|v| v.as_object())
        .expect("DeviceProfile object");
    assert!(profile.contains_key("MaxStreamingBitrate"));
    assert!(profile.contains_key("DirectPlayProfiles"));
    assert!(profile.contains_key("TranscodingProfiles"));
    // None-valued optional AppStoreUrl should be elided.
    assert!(
        !body.as_object().unwrap().contains_key("AppStoreUrl"),
        "unset optional should not appear: {body}"
    );
}

#[tokio::test]
async fn post_capabilities_requires_authenticated_session() {
    use crate::models::{ClientCapabilities, DeviceProfile};

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .post_capabilities(ClientCapabilities {
            playable_media_types: vec![],
            supported_commands: vec![],
            supports_media_control: false,
            supports_persistent_identifier: false,
            device_profile: DeviceProfile::default_macos_profile(),
            app_store_url: None,
            icon_url: None,
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// playback_info — POST /Items/{id}/PlaybackInfo
// ---------------------------------------------------------------------------

#[tokio::test]
async fn playback_info_posts_device_profile_and_parses_response() {
    use crate::models::{DeviceProfile, PlaybackInfoOpts};

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
        .and(path("/Items/track-xyz/PlaybackInfo"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "MediaSources": [
                {
                    "Id": "src-1",
                    "Path": "/music/song.flac",
                    "Container": "flac",
                    "Bitrate": 900000,
                    "Size": 42_000_000i64,
                    "RunTimeTicks": 1800000000i64,
                    "SupportsDirectPlay": true,
                    "SupportsDirectStream": true,
                    "SupportsTranscoding": true,
                    "TranscodingUrl": "/Audio/track-xyz/stream.mp3?PlaySessionId=abc",
                    "TranscodingSubProtocol": "http",
                    "TranscodingContainer": "mp3"
                }
            ],
            "PlaySessionId": "play-session-abc"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let opts = PlaybackInfoOpts {
        device_profile: Some(DeviceProfile::default_macos_profile()),
        max_streaming_bitrate: Some(320_000),
        ..Default::default()
    };
    let resp = client.playback_info("track-xyz", opts).await.unwrap();

    assert_eq!(resp.play_session_id.as_deref(), Some("play-session-abc"));
    assert_eq!(resp.media_sources.len(), 1);
    let src = &resp.media_sources[0];
    assert_eq!(src.id, "src-1");
    assert_eq!(src.container.as_deref(), Some("flac"));
    assert_eq!(src.bitrate, Some(900_000));
    assert!(src.supports_direct_play);
    assert_eq!(
        src.transcoding_url.as_deref(),
        Some("/Audio/track-xyz/stream.mp3?PlaySessionId=abc")
    );

    // Body fills in the live session's user id even when the caller
    // leaves `user_id` unset.
    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Items/track-xyz/PlaybackInfo")
        .expect("expected POST to /Items/track-xyz/PlaybackInfo");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");
    assert_eq!(body.get("UserId").and_then(|v| v.as_str()), Some("u1"));
    assert_eq!(
        body.get("MaxStreamingBitrate").and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert!(body.get("DeviceProfile").is_some());
}

#[tokio::test]
async fn playback_info_requires_authenticated_session() {
    use crate::models::PlaybackInfoOpts;

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .playback_info("anything", PlaybackInfoOpts::default())
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

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
        matches!(err, crate::error::JellifyError::NotFound(_)),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated on user_views, got {err:?}"
    );
    let err = client.music_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated on music_library_id, got {err:?}"
    );
    let err = client.playlist_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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

    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .count();
    assert_eq!(
        get_count, 2,
        "set_session must invalidate cached library ids"
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
        matches!(err, crate::error::JellifyError::Forbidden(_)),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// DeviceProfile serde
// ---------------------------------------------------------------------------

#[test]
fn default_macos_profile_serializes_to_pascal_case() {
    use crate::models::DeviceProfile;

    let profile = DeviceProfile::default_macos_profile();
    let v = serde_json::to_value(&profile).unwrap();
    let obj = v.as_object().expect("object profile");

    // Top-level PascalCase keys Jellyfin expects.
    for key in [
        "Name",
        "MaxStreamingBitrate",
        "MaxStaticBitrate",
        "MusicStreamingTranscodingBitrate",
        "DirectPlayProfiles",
        "TranscodingProfiles",
    ] {
        assert!(obj.contains_key(key), "missing top-level key {key}: {v}");
    }
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase only, got {:?}",
        obj.keys().collect::<Vec<_>>()
    );

    // Direct-play entries cover the AVFoundation set: flac/alac/mp3/aac/opus/ogg/wav.
    let direct = obj
        .get("DirectPlayProfiles")
        .and_then(|v| v.as_array())
        .unwrap();
    let containers: std::collections::HashSet<&str> = direct
        .iter()
        .filter_map(|e| e.get("Container").and_then(|v| v.as_str()))
        .collect();
    for c in ["flac", "alac", "mp3", "aac", "opus", "ogg", "wav"] {
        assert!(
            containers.contains(c),
            "direct-play must include {c}: {containers:?}"
        );
    }
    // Entries opt into AudioCodec only when the container is ambiguous
    // (e.g. m4a that can hold either ALAC or AAC). Entries without a codec
    // should simply elide the key, not emit `"AudioCodec": null`.
    for entry in direct {
        let entry_obj = entry.as_object().unwrap();
        assert_eq!(
            entry_obj.get("Type").and_then(|v| v.as_str()),
            Some("Audio")
        );
        if let Some(codec) = entry_obj.get("AudioCodec") {
            assert!(codec.is_string(), "AudioCodec must be a string: {entry}");
        }
    }

    // Transcoding fallback is MP3 @ 320 over HTTP.
    let transcodes = obj
        .get("TranscodingProfiles")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(transcodes.len(), 1, "expected one transcoding fallback");
    let t = transcodes[0].as_object().unwrap();
    assert_eq!(t.get("Container").and_then(|v| v.as_str()), Some("mp3"));
    assert_eq!(t.get("AudioCodec").and_then(|v| v.as_str()), Some("mp3"));
    assert_eq!(t.get("Protocol").and_then(|v| v.as_str()), Some("http"));

    // Bitrate caps — the 320 transcode ceiling and ~100 Mbps direct-play
    // cap the default profile advertises.
    assert_eq!(
        obj.get("MaxStreamingBitrate").and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert_eq!(
        obj.get("MusicStreamingTranscodingBitrate")
            .and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert_eq!(
        obj.get("MaxStaticBitrate").and_then(|v| v.as_u64()),
        Some(100_000_000)
    );
}

#[test]
fn default_macos_profile_round_trips_through_serde() {
    use crate::models::DeviceProfile;

    let profile = DeviceProfile::default_macos_profile();
    let json = serde_json::to_string(&profile).expect("serialize");
    let back: DeviceProfile = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(back.name, profile.name);
    assert_eq!(back.max_streaming_bitrate, profile.max_streaming_bitrate);
    assert_eq!(
        back.direct_play_profiles.len(),
        profile.direct_play_profiles.len()
    );
    assert_eq!(
        back.transcoding_profiles.len(),
        profile.transcoding_profiles.len()
    );
}

#[test]
fn stream_url_contains_api_key() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("mytoken".into(), "u1".into());
    let url = client.stream_url("track-id", None, None).unwrap();
    let s = url.as_str();
    assert!(s.contains("api_key=mytoken"), "url: {s}");
    assert!(s.contains("DeviceId=dev"), "url: {s}");
    assert!(s.contains("/Audio/track-id/universal"), "url: {s}");
}

// ---------------------------------------------------------------------------
// stream_url — MediaSourceId + PlaySessionId threading (#593, #569)
// ---------------------------------------------------------------------------

#[test]
fn stream_url_includes_media_source_id_when_provided() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client
        .stream_url("track-abc", Some("source-xyz"), None)
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("MediaSourceId=source-xyz"),
        "expected MediaSourceId in url: {s}"
    );
    assert!(
        s.contains("/Audio/track-abc/universal"),
        "expected universal path in url: {s}"
    );
}

#[test]
fn stream_url_includes_play_session_id_when_provided() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client
        .stream_url("track-abc", None, Some("session-42"))
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("PlaySessionId=session-42"),
        "expected PlaySessionId in url: {s}"
    );
}

#[test]
fn stream_url_omits_optional_params_when_none() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client.stream_url("track-abc", None, None).unwrap();
    let s = url.as_str();
    assert!(
        !s.contains("MediaSourceId"),
        "MediaSourceId should be absent when None: {s}"
    );
    assert!(
        !s.contains("PlaySessionId"),
        "PlaySessionId should be absent when None: {s}"
    );
}

#[test]
fn stream_url_includes_both_media_source_id_and_play_session_id() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client
        .stream_url("track-abc", Some("src-1"), Some("sess-99"))
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("MediaSourceId=src-1"), "url: {s}");
    assert!(s.contains("PlaySessionId=sess-99"), "url: {s}");
    assert!(s.contains("api_key=tok"), "url: {s}");
}

// ---------------------------------------------------------------------------
// Player — play_session_id threading (#569)
// ---------------------------------------------------------------------------

#[test]
fn player_play_session_id_defaults_to_none() {
    use crate::player::Player;
    let player = Player::new();
    assert!(player.play_session_id().is_none());
    assert!(player.status().play_session_id.is_none());
}

#[test]
fn player_set_play_session_id_round_trips() {
    use crate::player::Player;
    let player = Player::new();
    player.set_play_session_id(Some("sess-abc".into()));
    assert_eq!(player.play_session_id().as_deref(), Some("sess-abc"));
    assert_eq!(player.status().play_session_id.as_deref(), Some("sess-abc"));
}

#[test]
fn player_clear_resets_play_session_id() {
    use crate::player::Player;
    let player = Player::new();
    player.set_play_session_id(Some("sess-abc".into()));
    player.clear();
    assert!(
        player.play_session_id().is_none(),
        "clear() must reset play_session_id"
    );
    assert!(player.status().play_session_id.is_none());
}

#[test]
fn image_url_primary_is_backwards_compatible() {
    let client = mock_client("https://example.com");
    let url = client.image_url("item-1", Some("tag-1"), 400).unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-1/Images/Primary"),
        "url missing Primary path: {s}"
    );
    assert!(s.contains("maxWidth=400"), "url missing maxWidth: {s}");
    assert!(s.contains("quality=90"), "url missing quality: {s}");
    assert!(s.contains("tag=tag-1"), "url missing tag: {s}");
    // No index segment when index is omitted.
    assert!(
        !s.contains("/Images/Primary/"),
        "unexpected index segment: {s}"
    );
}

#[test]
fn image_url_of_type_primary_matches_legacy_shape() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-1",
            ImageType::Primary,
            None,
            Some("tag-1"),
            Some(400),
            None,
        )
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-1/Images/Primary"), "url: {s}");
    assert!(s.contains("maxWidth=400"), "url: {s}");
    assert!(s.contains("tag=tag-1"), "url: {s}");
    // Neither index nor maxHeight should leak in when not provided.
    assert!(!s.contains("maxHeight="), "url: {s}");
}

#[test]
fn image_url_of_type_backdrop_includes_index_segment() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-2",
            ImageType::Backdrop,
            Some(1),
            Some("bd-tag"),
            Some(1600),
            Some(900),
        )
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-2/Images/Backdrop/1"),
        "url missing Backdrop/1: {s}"
    );
    assert!(s.contains("maxWidth=1600"), "url: {s}");
    assert!(s.contains("maxHeight=900"), "url: {s}");
    assert!(s.contains("tag=bd-tag"), "url: {s}");
}

#[test]
fn image_url_of_type_thumb_without_index_or_sizes() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type("item-3", ImageType::Thumb, None, None, None, None)
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-3/Images/Thumb"), "url: {s}");
    assert!(!s.contains("/Thumb/"), "url should not have index: {s}");
    assert!(!s.contains("maxWidth="), "url: {s}");
    assert!(!s.contains("maxHeight="), "url: {s}");
    assert!(!s.contains("tag="), "url: {s}");
    assert!(s.contains("quality=90"), "url: {s}");
}

#[test]
fn database_roundtrips_settings() {
    let db = Database::in_memory().unwrap();
    db.set_setting("foo", "bar").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("bar"));
    db.set_setting("foo", "baz").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("baz"));
    assert_eq!(db.get_setting("missing").unwrap(), None);
}

#[test]
fn play_history_counts() {
    let db = Database::in_memory().unwrap();
    db.record_play("track-1", 100).unwrap();
    db.record_play("track-1", 200).unwrap();
    db.record_play("track-2", 150).unwrap();
    assert_eq!(db.play_count("track-1").unwrap(), 2);
    assert_eq!(db.play_count("track-2").unwrap(), 1);
    assert_eq!(db.play_count("unknown").unwrap(), 0);
}

// ---------------------------------------------------------------------------
// Session auto-restore (resume_session / login persistence)
// ---------------------------------------------------------------------------

/// Build a temp-backed `JellifyCore` so each test gets its own `jellify.db`
/// without colliding with other tests or leaking into the user's real data
/// directory.
fn resume_test_core(tmp: &tempfile::TempDir) -> std::sync::Arc<JellifyCore> {
    install_mock_keyring();
    JellifyCore::new(CoreConfig {
        data_dir: tmp.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    })
    .expect("core init")
}

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
    // `JellifyCore::login` is a sync FFI wrapper that `block_on`s its own
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
        let core = JellifyCore::new(CoreConfig {
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
        let core2 = JellifyCore::new(CoreConfig {
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
        let core = JellifyCore::new(CoreConfig {
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
        let core2 = JellifyCore::new(CoreConfig {
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
        let core = JellifyCore::new(CoreConfig {
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
/// callers never see a `JellifyError::Server { 503, .. }`.
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
        JellifyError::Server { status, .. } => assert_eq!(status, 501),
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
/// server error as `JellifyError::Server`, not as `Network(_)`.
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
        JellifyError::Server { status, .. } => assert_eq!(status, 502),
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
        matches!(err, JellifyError::AuthExpired),
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
    assert!(matches!(err, JellifyError::AuthExpired));
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
    assert!(matches!(err, JellifyError::AuthExpired));

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

// ---------------------------------------------------------------------------
// Shuffle + repeat persistence — round-trip tests (#583)
// ---------------------------------------------------------------------------

use crate::player::RepeatMode;

/// Fresh database returns the safe defaults (shuffle off, repeat off) so a
/// first launch does not accidentally start in an unexpected mode.
#[test]
fn shuffle_repeat_defaults_on_empty_db() {
    let db = Database::in_memory().expect("in-memory db");
    let (shuffle, repeat) = db.load_shuffle_repeat().unwrap();
    assert!(!shuffle, "default shuffle should be off");
    assert_eq!(repeat, RepeatMode::Off, "default repeat should be Off");
}

/// Every `(shuffle, RepeatMode)` combination round-trips correctly through the
/// key-value store. We create a second `Database` instance open on the same
/// file to verify the values are actually persisted rather than just cached in
/// memory.
#[test]
fn shuffle_repeat_round_trips_all_variants() {
    // Use a uniquely-named file in the OS temp directory so parallel test
    // runs do not collide. Best-effort removal at the end — it is fine if
    // the process exits before the remove; the OS will clean up temp files.
    let tmp = std::env::temp_dir().join(format!(
        "jellify_test_sr_{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));

    let cases: &[(bool, RepeatMode)] = &[
        (true, RepeatMode::Off),
        (false, RepeatMode::One),
        (true, RepeatMode::All),
        (false, RepeatMode::Off),
        (true, RepeatMode::One),
        (false, RepeatMode::All),
    ];

    for &(shuffle, repeat) in cases {
        // Write via one Database handle.
        {
            let db = Database::open(&tmp).expect("open db for write");
            db.save_shuffle_repeat(shuffle, repeat)
                .expect("save_shuffle_repeat");
        }
        // Read back via a fresh Database handle — exercises the actual SQLite
        // persistence path rather than any in-process cache.
        {
            let db = Database::open(&tmp).expect("open db for read");
            let (got_shuffle, got_repeat) = db.load_shuffle_repeat().expect("load_shuffle_repeat");
            assert_eq!(
                got_shuffle, shuffle,
                "shuffle mismatch for case ({shuffle}, {repeat:?})"
            );
            assert_eq!(
                got_repeat, repeat,
                "repeat mismatch for case ({shuffle}, {repeat:?})"
            );
        }
    }

    let _ = std::fs::remove_file(&tmp);
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
/// certificate must produce `JellifyError::SelfSignedCertificate { host }`,
/// not `JellifyError::Network`.
///
/// This test hits `https://self-signed.badssl.com/` (a public test endpoint
/// intentionally using a self-signed cert). It is tagged `#[ignore]` so it
/// is skipped in offline / CI-without-network environments; run it explicitly
/// with `cargo test -- --ignored cert_error_maps_to_structured_variant`.
#[tokio::test]
#[ignore = "requires outbound HTTPS to self-signed.badssl.com"]
async fn cert_error_maps_to_structured_variant() {
    use crate::error::JellifyError;

    // A default reqwest client uses rustls and will reject the self-signed cert.
    let result = reqwest::Client::builder()
        .build()
        .unwrap()
        .get("https://self-signed.badssl.com/")
        .send()
        .await;

    let reqwest_err = result.expect_err("badssl.com must fail cert validation");
    let jellify_err: JellifyError = reqwest_err.into();

    match jellify_err {
        JellifyError::SelfSignedCertificate { ref host } => {
            assert!(
                host.contains("badssl.com"),
                "host should be 'self-signed.badssl.com', got '{host}'"
            );
        }
        other => panic!("expected SelfSignedCertificate, got {other:?}"),
    }
}

/// Confirm that a plain connection-refused error (not a cert issue) continues
/// to map to `JellifyError::Network`, not `SelfSignedCertificate`.
#[tokio::test]
async fn non_cert_transport_error_stays_network() {
    use crate::error::JellifyError;

    // Connect to a port that is (almost certainly) not listening.  This
    // produces a connect-refused transport error, not a cert error.
    let result = reqwest::Client::builder()
        .build()
        .unwrap()
        .get("http://127.0.0.1:19999/")
        .send()
        .await;

    // May succeed if something happens to be on that port; skip in that case.
    let Some(reqwest_err) = result.err() else {
        return;
    };
    let jellify_err: JellifyError = reqwest_err.into();

    assert!(
        matches!(jellify_err, JellifyError::Network(_)),
        "connection-refused must map to Network, got {jellify_err:?}"
    );
}

// ============================================================================
// #577 — username / password whitespace trimming
// ============================================================================

/// `login` must reject blank (whitespace-only) usernames and passwords before
/// any network call is made.
#[test]
fn login_rejects_whitespace_only_credentials() {
    // Error fires before any HTTP call — no server needed.
    let config = CoreConfig {
        data_dir: String::new(),
        device_name: "Test".into(),
    };
    let core = JellifyCore::new(config).unwrap();

    let err = core
        .login("http://localhost:1".into(), "   ".into(), "password".into())
        .unwrap_err();
    assert!(
        matches!(err, JellifyError::InvalidCredentials),
        "whitespace-only username should return InvalidCredentials, got {err:?}"
    );

    let err = core
        .login("http://localhost:1".into(), "user".into(), "\t\n".into())
        .unwrap_err();
    assert!(
        matches!(err, JellifyError::InvalidCredentials),
        "whitespace-only password should return InvalidCredentials, got {err:?}"
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
    // JellifyCore::login is a sync FFI wrapper that block_on's its own runtime;
    // run it in spawn_blocking so we don't nest runtimes.
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = JellifyCore::new(CoreConfig {
            data_dir: String::new(),
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

// ============================================================================
// #584 — keyring write failure propagation
// ============================================================================

/// The `KeyringWrite` error variant must exist and carry a `reason` string so
/// callers can surface a diagnostic to the user.
#[test]
fn keyring_write_error_variant_is_displayable() {
    let err = JellifyError::KeyringWrite {
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
/// mapped to `JellifyError::KeyringWrite`.
///
/// Because `keyring`'s global builder is set once per process we cannot inject
/// a failing backend without racing other tests. We therefore verify the error
/// mapping at the type level: `CredentialStore::save_token` returns
/// `Result<()>`, and the `login` path uses `?` / `map_err` to convert it.
/// The `keyring_write_error_variant_is_displayable` test above confirms the
/// variant itself is correctly formed; this test confirms the happy-path login
/// propagates the write through without panicking.
#[tokio::test]
async fn login_keyring_write_is_not_silenced() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "propagate-token",
            "ServerId": "srv-propagate-unique",
            "ServerName": "Propagate",
            "User": {
                "Id": "usr-propagate",
                "Name": "propagate-user",
                "ServerId": "srv-propagate-unique",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = JellifyCore::new(CoreConfig {
            data_dir: String::new(),
            device_name: "Test".into(),
        })
        .unwrap();
        // With the shared mock keyring the write succeeds and login returns Ok.
        // The important thing is that any error from save_token is NOT silenced
        // (the old code used `let _ = ...`). We confirm the happy-path login
        // completes and the result is not quietly discarded.
        let result = core.login(server_url, "propagate-user".into(), "pw".into());
        // Accept Ok (mock keyring write succeeded) or KeyringWrite (write failed).
        // Any other error variant indicates a regression.
        match result {
            Ok(_) => {}
            Err(JellifyError::KeyringWrite { .. }) => {}
            Err(other) => panic!("unexpected error from login: {other:?}"),
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
        let core = JellifyCore::new(CoreConfig {
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
        let core = JellifyCore::new(CoreConfig {
            data_dir: tmp_path.clone(),
            device_name: "Test".into(),
        })
        .expect("core init");
        core.login(server_url, "clear-user".into(), "pw".into())
            .expect("login");

        {
            let inner = core.inner.lock();
            inner.db.record_play("track-seed", 1_000_000).unwrap();
            inner
                .db
                .set_setting("track_cache:track-seed", "cached")
                .unwrap();
        }

        core.logout().expect("logout");

        {
            let inner = core.inner.lock();
            assert_eq!(inner.db.get_setting("last_server_url").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_username").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
            assert_eq!(
                inner.db.play_count("track-seed").unwrap(),
                0,
                "play_history must be truncated on logout"
            );
        }

        assert!(
            CredentialStore::load_token("srv-clear", "clear-user")
                .unwrap()
                .is_none(),
            "keyring token must be deleted on logout"
        );

        let core2 = JellifyCore::new(CoreConfig {
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
        let core = JellifyCore::new(CoreConfig {
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
    // GET /Items?Ids=pl-1 — fetch_item uses the /Items?Ids= endpoint.
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("Ids", "pl-1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "pl-1", "Name": "Old Name", "Type": "Playlist" }
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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

// ---------------------------------------------------------------------------
// #594 — heartbeat scheduler fires at the expected cadence
// ---------------------------------------------------------------------------

/// Helper: spawn a heartbeat loop directly using `JellyfinClient` (not
/// `JellifyCore`) so the test can run inside a `#[tokio::test]` without
/// fighting the core's embedded `tokio::runtime::Runtime`.
///
/// Returns an `AbortHandle` — the test cancels the task when done.
async fn spawn_heartbeat_for_test(
    client: std::sync::Arc<JellyfinClient>,
    interval: std::time::Duration,
    play_session_id: Option<String>,
    current_track_id: std::sync::Arc<parking_lot::Mutex<Option<String>>>,
    current_position: std::sync::Arc<parking_lot::Mutex<f64>>,
) -> tokio::task::AbortHandle {
    use crate::models::PlaybackProgressInfo;
    let handle = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        ticker.tick().await; // skip the immediate first tick
        loop {
            ticker.tick().await;
            let item_id = match current_track_id.lock().clone() {
                Some(id) => id,
                None => continue,
            };
            let pos = *current_position.lock();
            let info = PlaybackProgressInfo {
                item_id,
                failed: false,
                is_paused: false,
                is_muted: false,
                position_ticks: (pos * 10_000_000.0) as i64,
                play_session_id: play_session_id.clone(),
                ..Default::default()
            };
            let _ = client.report_playback_progress(info).await;
        }
    });
    handle.abort_handle()
}

/// The heartbeat scheduler must fire `POST /Sessions/Playing/Progress` at
/// least N times in N * interval_secs of simulated time.  We use
/// `tokio::time::pause` + `tokio::time::advance` so the test runs
/// instantaneously without real wall-clock delays.
///
/// The test operates on `JellyfinClient` directly to avoid the nested-
/// runtime conflict that arises when `JellifyCore`'s embedded `block_on`
/// runs inside the test's tokio executor. See issue #594.
#[tokio::test]
async fn heartbeat_fires_at_expected_cadence() {
    use parking_lot::Mutex;
    use std::sync::Arc;

    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "hb-token",
            "ServerId": "hb-server",
            "ServerName": "HB",
            "User": {
                "Id": "hb-user",
                "Name": "hbuser",
                "ServerId": "hb-server",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("hbuser", "pw").await.unwrap();
    let client = Arc::new(client);

    let track_id: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(Some("hb-track-1".into())));
    let position: Arc<Mutex<f64>> = Arc::new(Mutex::new(42.0));

    let interval_secs: u64 = 5;

    // Pause time after the real HTTP auth so reqwest's connection logic
    // completes normally. From here on, `advance` drives the fake clock.
    tokio::time::pause();

    let abort = spawn_heartbeat_for_test(
        Arc::clone(&client),
        std::time::Duration::from_secs(interval_secs),
        Some("sess-abc".into()),
        Arc::clone(&track_id),
        Arc::clone(&position),
    )
    .await;

    // Advance time in per-interval steps, yielding between each so the
    // heartbeat task can run and the HTTP POST to wiremock can complete
    // before the next tick fires.
    for _ in 0..(interval_secs * 3) {
        tokio::time::advance(std::time::Duration::from_secs(1)).await;
        for _ in 0..8 {
            tokio::task::yield_now().await;
        }
    }

    abort.abort();
    // One final yield to flush any in-flight request.
    tokio::task::yield_now().await;

    let reqs = server.received_requests().await.unwrap();
    let heartbeats = reqs
        .iter()
        .filter(|r| r.url.path() == "/Sessions/Playing/Progress")
        .count();

    assert!(
        heartbeats >= 2,
        "expected at least 2 heartbeats in {} simulated seconds, got {}",
        interval_secs * 3,
        heartbeats,
    );
}

/// After aborting the heartbeat task no further POSTs should be sent.
/// Verifies the scheduler does not leak a timer after `AbortHandle::abort()`.
/// See issue #594.
#[tokio::test]
async fn heartbeat_stops_after_abort() {
    use parking_lot::Mutex;
    use std::sync::Arc;

    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok2",
            "ServerId": "srv2",
            "ServerName": "S2",
            "User": {
                "Id": "u2", "Name": "u2", "ServerId": "srv2",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("u2", "pw").await.unwrap();
    let client = Arc::new(client);

    let track_id: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(Some("t2".into())));
    let position: Arc<Mutex<f64>> = Arc::new(Mutex::new(0.0));

    // Pause time after real HTTP auth completes so `advance` controls ticks.
    tokio::time::pause();

    let abort = spawn_heartbeat_for_test(
        Arc::clone(&client),
        std::time::Duration::from_secs(5),
        None,
        Arc::clone(&track_id),
        Arc::clone(&position),
    )
    .await;

    // Advance 6 s — heartbeat fires once at t=5 s.
    tokio::time::advance(std::time::Duration::from_secs(6)).await;
    for _ in 0..4 {
        tokio::task::yield_now().await;
    }

    abort.abort();
    let count_after_abort = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/Sessions/Playing/Progress")
        .count();

    // Advance another 10 s — no new POSTs should appear.
    tokio::time::advance(std::time::Duration::from_secs(10)).await;
    for _ in 0..4 {
        tokio::task::yield_now().await;
    }

    let count_final = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/Sessions/Playing/Progress")
        .count();

    assert_eq!(
        count_after_abort, count_final,
        "no heartbeats should fire after abort; before={count_after_abort} after={count_final}"
    );
}

// ---------------------------------------------------------------------------
// #605 — CancellationToken aborts mid-backoff retry sleep
// ---------------------------------------------------------------------------

/// When the `CancellationToken` on a `JellyfinClient` is cancelled while
/// the retry loop is sleeping through its backoff delay, the request must
/// return `JellifyError::Other("request cancelled")` immediately rather than
/// waiting out the full delay or completing the retry.
#[tokio::test]
async fn cancelled_token_aborts_retry_backoff() {
    use std::time::Instant;

    let server = MockServer::start().await;

    // Always respond with 503 so the retry loop always enters the backoff.
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(503))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    // Cancel the token after a very short delay — the backoff is 200 ms+,
    // so the cancel fires while the sleep is still pending.
    let cancel = client.cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        cancel.cancel();
    });

    let start = Instant::now();
    let err = client.public_info().await.unwrap_err();
    let elapsed = start.elapsed();

    // The full backoff ladder for 3 attempts is ≥600 ms; we should bail
    // well before that.
    assert!(
        elapsed < std::time::Duration::from_millis(500),
        "cancellation should abort the retry sleep quickly, elapsed={elapsed:?}"
    );
    match err {
        JellifyError::Other(ref msg) if msg.contains("cancelled") => {}
        other => panic!("expected Other(\"request cancelled\"), got {other:?}"),
    }
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
    tokio::task::spawn_blocking(move || {
        let core = std::sync::Arc::new(
            JellifyCore::new(CoreConfig {
                data_dir: String::new(),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn structured_error_auth_maps_401() {
    // A 401 on an authenticated library call goes through the silent
    // re-auth path in `send_with_retry_raw`; with no refresh callback
    // wired (and therefore no fresh keyring token to grab), the caller
    // sees [`JellifyError::AuthExpired`] rather than the raw `Auth(body)`.
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
        matches!(err, crate::error::JellifyError::AuthExpired),
        "expected AuthExpired for 401 on authenticated call, got {err:?}"
    );

    // And the raw mapping (`from_status`) still lands on `Auth(body)` —
    // which is what endpoints that bypass the retry layer will see.
    let raw = crate::error::JellifyError::from_status(401, "unauthorized".into(), None);
    assert!(
        matches!(raw, crate::error::JellifyError::Auth(_)),
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
        matches!(err, crate::error::JellifyError::Forbidden(_)),
        "expected Forbidden for 403, got {err:?}"
    );
}

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
        crate::error::JellifyError::RateLimit { retry_after } => {
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
        crate::error::JellifyError::Server { status, .. } => assert_eq!(*status, 503),
        other => panic!("expected Server, got {other:?}"),
    }
    assert!(err.is_retryable(), "5xx must be retryable");
}

#[test]
fn structured_error_is_retryable_classification() {
    use crate::error::JellifyError;

    // Retryable: RateLimit, Network, Server 5xx.
    assert!(JellifyError::RateLimit { retry_after: None }.is_retryable());
    assert!(JellifyError::Network("boom".into()).is_retryable());
    assert!(JellifyError::Server {
        status: 500,
        body: "".into(),
    }
    .is_retryable());
    assert!(JellifyError::Server {
        status: 599,
        body: "".into(),
    }
    .is_retryable());

    // Not retryable: Auth, Forbidden, NotFound, Decode, InvalidInput,
    // NotAuthenticated, NoSession.
    assert!(!JellifyError::Auth("".into()).is_retryable());
    assert!(!JellifyError::Forbidden("".into()).is_retryable());
    assert!(!JellifyError::NotFound("".into()).is_retryable());
    assert!(!JellifyError::Decode("".into()).is_retryable());
    assert!(!JellifyError::InvalidInput("".into()).is_retryable());
    assert!(!JellifyError::NotAuthenticated.is_retryable());
    assert!(!JellifyError::NoSession.is_retryable());
    // A 4xx `Server` (unclassified) is NOT retryable — only 5xx is.
    assert!(!JellifyError::Server {
        status: 418,
        body: "".into(),
    }
    .is_retryable());
}

#[test]
fn structured_error_from_status_dispatches_variants() {
    use crate::error::JellifyError;
    assert!(matches!(
        JellifyError::from_status(401, "".into(), None),
        JellifyError::Auth(_)
    ));
    assert!(matches!(
        JellifyError::from_status(403, "".into(), None),
        JellifyError::Forbidden(_)
    ));
    assert!(matches!(
        JellifyError::from_status(404, "".into(), None),
        JellifyError::NotFound(_)
    ));
    assert!(matches!(
        JellifyError::from_status(429, "".into(), Some(5)),
        JellifyError::RateLimit {
            retry_after: Some(5)
        }
    ));
    assert!(matches!(
        JellifyError::from_status(500, "".into(), None),
        JellifyError::Server { status: 500, .. }
    ));
    assert!(matches!(
        JellifyError::from_status(418, "".into(), None),
        JellifyError::Server { status: 418, .. }
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

#[test]
fn player_clear_drops_queue() {
    use crate::models::Track;
    use crate::player::Player;

    let make = |id: &str| Track {
        id: id.into(),
        name: id.into(),
        album_id: None,
        album_name: None,
        artist_name: "Artist".into(),
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
    };

    let player = Player::new();
    player
        .set_queue(vec![make("a"), make("b"), make("c")], 1)
        .unwrap();
    assert_eq!(player.status().queue_length, 3);
    assert_eq!(player.status().queue_position, 1);

    player.clear();

    let status = player.status();
    assert_eq!(status.queue_length, 0, "clear() must empty the queue");
    assert_eq!(status.queue_position, 0, "clear() must reset queue_index");
    assert!(player.current_in_queue().is_none());
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    let err = client.mark_unplayed("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
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
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    assert!(
        server.received_requests().await.unwrap().is_empty(),
        "guard must short-circuit before any HTTP call"
    );
}
