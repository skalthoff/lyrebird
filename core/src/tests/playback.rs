use super::*;

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
        crate::error::LyrebirdError::Server { status, .. } => assert_eq!(status, 500),
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
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
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
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
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
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
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
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
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
        matches!(err, crate::error::LyrebirdError::NotAuthenticated),
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
// stream_url — quality / MaxStreamingBitrate cap (#260)
// ---------------------------------------------------------------------------

#[test]
fn stream_url_defaults_to_320kbps_cap() {
    // The convenience `stream_url` preserves the long-standing 320 kbps ceiling
    // so existing internal callers are byte-for-byte unchanged.
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client.stream_url("track-abc", None, None).unwrap();
    assert!(
        url.as_str().contains("MaxStreamingBitrate=320000"),
        "default cap should be 320000: {url}"
    );
}

#[test]
fn stream_url_with_bitrate_sets_requested_cap() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client
        .stream_url_with_bitrate("track-abc", None, None, Some(96_000))
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("MaxStreamingBitrate=96000"),
        "expected the requested 96k cap: {s}"
    );
    assert!(s.contains("/Audio/track-abc/universal"), "url: {s}");
}

#[test]
fn stream_url_with_bitrate_none_omits_cap_for_original() {
    // The "Original" tier passes None, which must omit MaxStreamingBitrate so
    // the server returns the source unbounded rather than capping at a default.
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("tok".into(), "u1".into());
    let url = client
        .stream_url_with_bitrate("track-abc", None, None, None)
        .unwrap();
    assert!(
        !url.as_str().contains("MaxStreamingBitrate"),
        "Original (None) must omit the bitrate cap entirely: {url}"
    );
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

// ---------------------------------------------------------------------------
// #594 — heartbeat scheduler fires at the expected cadence
// ---------------------------------------------------------------------------

/// Build a `LyrebirdCore` logged in against `server`, with the player primed
/// to a Playing track at `position_secs`, so the production heartbeat
/// scheduler (`start_heartbeat`) has live state to report. Runs the
/// `block_on`-using setup off the async runtime via the caller's
/// `spawn_blocking`. Returns the `Arc<LyrebirdCore>`.
fn heartbeat_core_logged_in(
    server_url: String,
    data_dir: String,
    position_secs: f64,
    paused: bool,
) -> std::sync::Arc<LyrebirdCore> {
    install_mock_keyring();
    let core = LyrebirdCore::new(CoreConfig {
        data_dir,
        device_name: "Test".into(),
    })
    .expect("core init");
    core.login(server_url, "hbuser".into(), "pw".into())
        .expect("login");
    let track = crate::models::Track {
        id: "hb-track-1".into(),
        name: "Heartbeat".into(),
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
    core.set_queue(vec![track], 0).expect("set_queue");
    core.mark_position(position_secs);
    core.mark_state(if paused {
        crate::player::PlaybackState::Paused
    } else {
        crate::player::PlaybackState::Playing
    });
    core
}

/// Count the `/Sessions/Playing/Progress` POSTs wiremock has seen.
async fn heartbeat_hits(server: &MockServer) -> usize {
    server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/Sessions/Playing/Progress")
        .count()
}

/// The production heartbeat scheduler (`LyrebirdCore::start_heartbeat`) must
/// POST `/Sessions/Playing/Progress` at the clamped cadence, forwarding the
/// real player pause state, and `stop_heartbeat` must take the handle out of
/// the `self.heartbeat` Mutex and halt further reports.
///
/// This drives the *shipping* scheduler end-to-end (not a test-only re-
/// implementation), against a mock server, with real time — the interval is
/// clamped to a 1s floor so the test only needs a couple of seconds.
#[tokio::test]
async fn heartbeat_fires_at_clamped_cadence_and_forwards_pause_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "hb-token",
            "ServerId": "hb-server-cadence",
            "ServerName": "HB",
            "User": { "Id": "hb-user", "Name": "hbuser", "ServerId": "hb-server-cadence", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();

    // Drive the production scheduler. `start_heartbeat(0, ..)` exercises the
    // `interval_secs.clamp(1, 10)` floor — a naive impl would divide-by-zero
    // or never fire; the clamp turns it into a 1s cadence.
    tokio::task::spawn_blocking(move || {
        let core = heartbeat_core_logged_in(server_url, tmp_path, 42.0, /* paused */ true);
        core.start_heartbeat(0, Some("sess-abc".into()));
        // ~2.6s real: heartbeats at ~1s and ~2s after the consumed first tick.
        std::thread::sleep(std::time::Duration::from_millis(2600));
        core.stop_heartbeat();
    })
    .await
    .expect("spawn_blocking panicked");

    let hits = heartbeat_hits(&server).await;
    assert!(
        hits >= 2,
        "clamped (0 -> 1s) cadence must fire at least twice in ~2.6s, got {hits}"
    );

    // The captured progress bodies must carry the *real* pause state we set on
    // the player (is_paused=true), not a hard-coded false.
    let reqs = server.received_requests().await.unwrap();
    let progress: Vec<_> = reqs
        .iter()
        .filter(|r| r.url.path() == "/Sessions/Playing/Progress")
        .collect();
    assert!(!progress.is_empty());
    for r in &progress {
        let body: serde_json::Value =
            serde_json::from_slice(&r.body).expect("progress body is JSON");
        assert_eq!(
            body["IsPaused"].as_bool(),
            Some(true),
            "heartbeat must forward the player's real pause state, got: {body}"
        );
        // The PlaySessionId passed to start_heartbeat must be echoed.
        assert_eq!(
            body["PlaySessionId"].as_str(),
            Some("sess-abc"),
            "heartbeat must echo the play_session_id, got: {body}"
        );
    }
}

/// `stop_heartbeat` (production) must halt the scheduler — no further POSTs
/// after it returns. Exercises the `self.heartbeat` Mutex take/None-guard that
/// the old raw-`AbortHandle` test bypassed. See issue #594.
#[tokio::test]
async fn heartbeat_stops_after_stop_heartbeat() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok2",
            "ServerId": "hb-server-stop",
            "ServerName": "S2",
            "User": { "Id": "hb-user", "Name": "hbuser", "ServerId": "hb-server-stop", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();

    // Phase 1: run for ~1.6s (>= 1 heartbeat), then stop.
    tokio::task::spawn_blocking(move || {
        let core = heartbeat_core_logged_in(server_url, tmp_path, 10.0, /* paused */ false);
        core.start_heartbeat(1, None);
        std::thread::sleep(std::time::Duration::from_millis(1600));
        core.stop_heartbeat();
        // Give any in-flight request a moment to land before we snapshot.
        std::thread::sleep(std::time::Duration::from_millis(100));
    })
    .await
    .expect("spawn_blocking panicked");

    let count_at_stop = heartbeat_hits(&server).await;
    assert!(
        count_at_stop >= 1,
        "expected >= 1 heartbeat before stop, got {count_at_stop}"
    );

    // Phase 2: wait well past two more intervals — count must not grow.
    tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
    let count_final = heartbeat_hits(&server).await;
    assert_eq!(
        count_at_stop, count_final,
        "no heartbeats may fire after stop_heartbeat; before={count_at_stop} after={count_final}"
    );
}

/// Calling `start_heartbeat` twice must abort the first task (the new handle
/// replaces the old in the `self.heartbeat` Mutex) so there are never two
/// schedulers POSTing in parallel — i.e. no doubled cadence.
#[tokio::test]
async fn start_heartbeat_twice_does_not_double_cadence() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok3",
            "ServerId": "hb-server-twice",
            "ServerName": "S3",
            "User": { "Id": "hb-user", "Name": "hbuser", "ServerId": "hb-server-twice", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();

    tokio::task::spawn_blocking(move || {
        let core = heartbeat_core_logged_in(server_url, tmp_path, 5.0, /* paused */ false);
        // Start, then immediately restart. The first task must be aborted by
        // the second `start_heartbeat`, leaving exactly one scheduler.
        core.start_heartbeat(1, None);
        core.start_heartbeat(1, None);
        std::thread::sleep(std::time::Duration::from_millis(2600));
        core.stop_heartbeat();
    })
    .await
    .expect("spawn_blocking panicked");

    // With a single ~1s scheduler over ~2.6s we expect ~2 heartbeats. Two
    // overlapping schedulers would roughly double that. Allow generous CI
    // slack but cap below the doubled count.
    let hits = heartbeat_hits(&server).await;
    assert!(
        (2..=4).contains(&hits),
        "double-start must not double the cadence: expected ~2 heartbeats (<=4), got {hits}"
    );
}

/// When playback ends, the heartbeat must STOP POSTing even though
/// `current_track` is still set — otherwise the server (and other Jellyfin
/// clients) show a frozen ghost "Now Playing". Pins the Ended/Stopped/Idle
/// guard in the heartbeat loop (lib.rs).
#[tokio::test]
async fn heartbeat_skips_when_playback_ended() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "tok4",
            "ServerId": "hb-server-ended",
            "ServerName": "S4",
            "User": { "Id": "hb-user", "Name": "hbuser", "ServerId": "hb-server-ended", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let server_url = server.uri();
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().to_string_lossy().to_string();

    tokio::task::spawn_blocking(move || {
        // Prime a track but immediately mark playback Ended (current_track
        // stays Some). The heartbeat must treat this as "nothing to report".
        let core = heartbeat_core_logged_in(server_url, tmp_path, 180.0, /* paused */ false);
        core.mark_state(crate::player::PlaybackState::Ended);
        core.start_heartbeat(1, Some("sess-ended".into()));
        std::thread::sleep(std::time::Duration::from_millis(2600));
        core.stop_heartbeat();
    })
    .await
    .expect("spawn_blocking panicked");

    let hits = heartbeat_hits(&server).await;
    assert_eq!(
        hits, 0,
        "heartbeat must not POST progress for an Ended track (ghost now-playing), got {hits}"
    );
}

// ---------------------------------------------------------------------------
// #605 — CancellationToken aborts mid-backoff retry sleep
// ---------------------------------------------------------------------------

/// When the `CancellationToken` on a `JellyfinClient` is cancelled while
/// the retry loop is sleeping through its backoff delay, the request must
/// return `LyrebirdError::Other("request cancelled")` immediately rather than
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
        LyrebirdError::Other(ref msg) if msg.contains("cancelled") => {}
        other => panic!("expected Other(\"request cancelled\"), got {other:?}"),
    }
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

#[tokio::test]
async fn playback_info_parses_negative_bitrate_sentinel() {
    use crate::models::PlaybackInfoOpts;

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
        .and(path("/Items/flac-xyz/PlaybackInfo"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "MediaSources": [
                {
                    "Id": "src-1",
                    "Container": "flac",
                    "Bitrate": -1000,
                    "SupportsDirectPlay": true
                }
            ],
            "PlaySessionId": "play-session-flac"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let resp = client
        .playback_info("flac-xyz", PlaybackInfoOpts::default())
        .await
        .unwrap();

    assert_eq!(resp.play_session_id.as_deref(), Some("play-session-flac"));
    assert_eq!(resp.media_sources.len(), 1);
    assert_eq!(resp.media_sources[0].bitrate, Some(-1000));
}
