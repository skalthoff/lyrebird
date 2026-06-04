use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Server {
    pub url: String,
    pub name: String,
    pub version: Option<String>,
    pub id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct User {
    pub id: String,
    pub name: String,
    pub server_id: Option<String>,
    pub primary_image_tag: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Session {
    pub server: Server,
    pub user: User,
    pub access_token: String,
    pub device_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub album_count: u32,
    pub song_count: u32,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
    /// The server's `UserData` projection for this artist — carries the
    /// favorite flag, play count, last-played date, etc. `None` when the
    /// caller did not request `Fields=UserData` or the server omitted it.
    pub user_data: Option<UserItemData>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Album {
    pub id: String,
    pub name: String,
    pub artist_name: String,
    pub artist_id: Option<String>,
    pub year: Option<i32>,
    pub track_count: u32,
    pub runtime_ticks: u64,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
    /// The server's `UserData` projection for this album — carries the
    /// favorite flag, play count, last-played date, etc. `None` when the
    /// caller did not request `Fields=UserData` or the server omitted it.
    pub user_data: Option<UserItemData>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Track {
    pub id: String,
    pub name: String,
    pub album_id: Option<String>,
    pub album_name: Option<String>,
    pub artist_name: String,
    pub artist_id: Option<String>,
    pub index_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub year: Option<i32>,
    pub runtime_ticks: u64,
    /// Convenience mirror of `user_data.as_ref().map(|u| u.is_favorite)`
    /// for call sites that only need the favorite flag. Kept for backwards
    /// compatibility with pre-[`UserItemData`] code; new code should read
    /// `user_data.is_favorite` so the full payload is available.
    pub is_favorite: bool,
    /// Convenience mirror of `user_data.as_ref().map(|u| u.play_count)`.
    /// See [`Self::is_favorite`].
    pub play_count: u32,
    pub container: Option<String>,
    pub bitrate: Option<i64>,
    pub image_tag: Option<String>,
    /// Jellyfin `PlaylistItemId` — only populated when the track was fetched
    /// as part of a playlist (via `playlist_tracks`). Used by
    /// `reorder_playlist_track` and `remove_from_playlist` to identify the
    /// specific entry rather than the underlying item, so duplicate tracks in
    /// the same playlist can be operated on independently.
    pub playlist_item_id: Option<String>,
    /// The server's `UserData` projection for this track — carries the
    /// favorite flag, play count, playback position, etc. `None` when the
    /// caller did not request `Fields=UserData` or the server omitted it.
    pub user_data: Option<UserItemData>,
}

impl Track {
    pub fn duration_seconds(&self) -> f64 {
        self.runtime_ticks as f64 / 10_000_000.0
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub track_count: u32,
    pub runtime_ticks: u64,
    pub image_tag: Option<String>,
    /// The server's `UserData` projection for this playlist — carries the
    /// favorite flag, play count, last-played date, etc. `None` when the
    /// caller did not request `Fields=UserData` or the server omitted it.
    pub user_data: Option<UserItemData>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchResults {
    pub artists: Vec<Artist>,
    pub albums: Vec<Album>,
    pub tracks: Vec<Track>,
    /// Total number of items (across all item types) the server reports for
    /// this query, as returned in `TotalRecordCount`. When the total is
    /// greater than `artists.len() + albums.len() + tracks.len()`, more
    /// results are available past the current page.
    pub total_record_count: u32,
}

/// Page of albums returned by `albums` and `latest_albums`. `total_count`
/// comes from Jellyfin's `TotalRecordCount`, so callers can detect when more
/// pages exist beyond the current `items.len()` + `offset`. UniFFI doesn't
/// support generics, so there is one of these per item type.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedAlbums {
    pub items: Vec<Album>,
    pub total_count: u32,
}

/// Page of artists returned by `artists`. See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedArtists {
    pub items: Vec<Artist>,
    pub total_count: u32,
}

/// Page of tracks returned by `recently_played` and `playlist_tracks`.
/// See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedTracks {
    pub items: Vec<Track>,
    pub total_count: u32,
}

/// Page of playlists returned by `user_playlists`. `total_count` is the
/// server-reported `TotalRecordCount` for the Playlists library view, so it
/// can drive "N of M" sublines and load-more triggers directly.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedPlaylists {
    pub items: Vec<Playlist>,
    pub total_count: u32,
}

/// A music genre, as returned by `GET /MusicGenres`. Counts come from the
/// server's `ItemCounts` projection — both populate on the same request, so
/// callers can render "42 songs · 6 albums" style sublines without a second
/// round-trip. `image_tag` mirrors Jellyfin's `ImageTags.Primary` and feeds
/// [`crate::JellyfinClient::image_url`] when present.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Genre {
    pub id: String,
    pub name: String,
    pub song_count: u32,
    pub album_count: u32,
    pub image_tag: Option<String>,
}

/// Page of genres returned by `genres`. See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedGenres {
    pub items: Vec<Genre>,
    pub total_count: u32,
}

/// A typed reference to a Jellyfin item — minimal shape used by
/// `similar_items`. `kind` carries the server's `Type` field so the UI can
/// dispatch to the right detail screen (`MusicAlbum` → album view,
/// `MusicArtist` → artist view, `Audio` → track row) without a second fetch.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ItemRef {
    pub id: String,
    pub name: String,
    /// Server-supplied `Type` field (e.g. `Audio`, `MusicAlbum`,
    /// `MusicArtist`).
    pub kind: Option<String>,
    pub image_tag: Option<String>,
}

/// An external link on an artist/album record — one entry in Jellyfin's
/// `ExternalUrls` array. Surfaced by [`crate::JellyfinClient::artist_detail`] so the
/// artist page can render MusicBrainz / Last.fm / Discogs shortcut icons.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ExternalUrl {
    pub name: String,
    pub url: String,
}

/// Extended artist record returned by [`crate::JellyfinClient::artist_detail`].
/// Mirrors the base [`Artist`] fields, then layers on biography, backdrops,
/// and external links for the artist detail header. `overview` is returned
/// verbatim from Jellyfin — callers may need to strip HTML if their UI
/// expects plain text.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ArtistDetail {
    pub id: String,
    pub name: String,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
    /// Long-form biography. May contain HTML / Markdown — the UI decides
    /// whether to render inline or plain-text.
    pub overview: Option<String>,
    /// `BackdropImageTags` from the server — one entry per backdrop image.
    /// Pass the index to [`crate::JellyfinClient::image_url_of_type`] with
    /// [`crate::ImageType::Backdrop`] to build per-backdrop URLs.
    pub backdrop_image_tags: Vec<String>,
    /// Parallel to `BackdropImageTags`: the underlying item ids that carry
    /// the backdrop tags. When empty, callers should use `id` directly.
    pub external_urls: Vec<ExternalUrl>,
}

/// One line in a `Lyrics` payload. `time_seconds` is derived from
/// Jellyfin's `Start` field (100-ns ticks) so callers can compare it
/// directly against the platform audio engine's playback position.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct LyricLine {
    pub time_seconds: f64,
    pub text: String,
}

/// Lyrics payload for a track, as returned by `GET /Audio/{id}/Lyrics`.
/// When `is_synced` is `true`, `lines[i].time_seconds` increases
/// monotonically and can drive a karaoke-style highlight; when `false`
/// there is typically a single line with `time_seconds == 0.0`.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Lyrics {
    pub is_synced: bool,
    pub lines: Vec<LyricLine>,
}

/// A lightweight, typed-heterogeneous search result returned by
/// `GET /Search/Hints`. Jellyfin trims its `BaseItemDto` down to just the
/// columns the typeahead UI needs, so `SearchHint` is the preferred shape
/// for debounced omnibox-style search: cheap to fetch, cheap to render.
///
/// `kind` carries the server-supplied `Type` (`Audio`, `MusicAlbum`,
/// `MusicArtist`, `Playlist`, etc.), so a single flat list can be split
/// into typed sections client-side without issuing per-type queries.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchHint {
    pub id: String,
    pub name: String,
    /// Server-supplied `Type` field (e.g. `Audio`, `MusicAlbum`,
    /// `MusicArtist`, `Playlist`). Kept as a raw string so we don't have
    /// to exhaustively enumerate every `BaseItemKind` the server may return.
    pub kind: Option<String>,
    /// The `MediaType` as reported by Jellyfin (`Audio`, `Video`, `Unknown`, ...).
    pub media_type: Option<String>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub album_artist: Option<String>,
    /// The exact substring from the query that matched this hint. Useful for
    /// highlighting the matched portion of `name` in the UI.
    pub matched_term: Option<String>,
    pub primary_image_tag: Option<String>,
    /// Tag for the item's thumbnail image (`ThumbImageTag` in the Jellyfin
    /// DTO). Used to build a `/Items/{id}/Images/Thumb?tag=…` URL.
    #[serde(rename = "ThumbImageTag")]
    pub thumb_image_tag: Option<String>,
    /// Tag for the item's backdrop image (`BackdropImageTag` in the Jellyfin
    /// DTO). Used to build a `/Items/{id}/Images/Backdrop?tag=…` URL.
    #[serde(rename = "BackdropImageTag")]
    pub backdrop_image_tag: Option<String>,
    /// Server-reported aspect ratio for the primary image so the UI can
    /// reserve the correct amount of space before the image loads.
    #[serde(rename = "PrimaryImageAspectRatio")]
    pub primary_image_aspect_ratio: Option<f64>,
    pub production_year: Option<i32>,
    pub index_number: Option<u32>,
    pub parent_index_number: Option<u32>,
    pub runtime_ticks: Option<u64>,
    pub artists: Vec<String>,
    pub is_folder: Option<bool>,
}

/// Response envelope for `GET /Search/Hints`:
/// `{ SearchHints: [...], TotalRecordCount }`. The total is the unpaged
/// count so clients can show "Showing X of Y" hints in the typeahead.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchHintResults {
    pub search_hints: Vec<SearchHint>,
    pub total_record_count: u32,
}

/// Subset of Jellyfin's `UserItemDataDto` surfaced by favorite mutations so
/// callers can update UI state without refetching the item. `last_played` is
/// a raw ISO 8601 string as returned by the server (or `null` when the item
/// has never been played).
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct FavoriteState {
    #[serde(rename = "IsFavorite", default)]
    pub is_favorite: bool,
    #[serde(rename = "PlayCount", default)]
    pub play_count: Option<u32>,
    #[serde(rename = "LastPlayedDate", default)]
    pub last_played: Option<String>,
}

/// Full `UserItemData` projection as returned by Jellyfin for each user /
/// item pair. When callers request `Fields=UserData` on a library endpoint,
/// the server embeds this struct on every returned item; [`Album`],
/// [`Artist`], and [`Track`] surface it via their optional `user_data` field.
///
/// `playback_position_ticks` is in Jellyfin's 100-ns tick units
/// (`seconds * 10_000_000`). `last_played_at` is the raw ISO-8601 string the
/// server returns, or `None` when the item has never been played.
///
/// `likes` / `rating` are Jellyfin's optional thumbs / numeric-rating fields;
/// the Jellyfin Web UI surfaces them independently from the star-based
/// `CommunityRating` and they round-trip here so a future ratings UI can
/// read them without another round-trip.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
pub struct UserItemData {
    pub is_favorite: bool,
    pub played: bool,
    pub play_count: u32,
    pub playback_position_ticks: i64,
    pub last_played_at: Option<String>,
    pub likes: Option<bool>,
    pub rating: Option<f64>,
}

#[derive(Clone, Copy, Debug, Default, uniffi::Record)]
pub struct Paging {
    pub offset: u32,
    pub limit: u32,
}

impl Paging {
    pub fn new(offset: u32, limit: u32) -> Self {
        Self { offset, limit }
    }
}

// ============================================================================
// Library resolution
// ============================================================================

/// A single entry in Jellyfin's `GET /UserViews` response. Represents a
/// top-level library the current user can browse (Music, Playlists, Movies,
/// TV Shows, ...). Callers typically filter by `collection_type` to find
/// the music or playlist library.
///
/// `collection_type` is the server's `CollectionType` string (`"music"`,
/// `"playlists"`, etc.). Left as a raw string so we don't have to
/// exhaustively enumerate every possible Jellyfin library kind.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Library {
    pub id: String,
    pub name: String,
    pub collection_type: Option<String>,
}

// ============================================================================
// Device profile — describes what this client can direct-play vs. transcode.
// Shared by `POST /Sessions/Capabilities/Full` and `POST /Items/{id}/PlaybackInfo`.
// ============================================================================

/// A single direct-play container/codec combination the client supports.
/// Corresponds to Jellyfin's `DirectPlayProfile` DTO.
///
/// `kind` is `"Audio"` / `"Video"` — we only emit `Audio` rules here since
/// Lyrebird Desktop is a music app.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct DirectPlayProfile {
    pub container: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
    #[serde(rename = "Type")]
    pub kind: String,
}

/// A single transcoding target the client will accept when the source
/// cannot be direct-played. Corresponds to Jellyfin's `TranscodingProfile`
/// DTO.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct TranscodingProfile {
    pub container: String,
    pub audio_codec: String,
    pub protocol: String,
    pub context: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_audio_channels: Option<String>,
    #[serde(rename = "Type")]
    pub kind: String,
}

/// Jellyfin's `DeviceProfile` DTO. Describes which containers/codecs the
/// client can direct-play and which it needs transcoded, plus bitrate
/// caps. Sent on every `POST /Items/{id}/PlaybackInfo` and
/// `POST /Sessions/Capabilities/Full` call.
///
/// Only the fields a music client needs are included here — Lyrebird Desktop
/// never touches video, subtitles, or DLNA codec profiles, so those array
/// fields are simply omitted from the payload (Jellyfin treats a missing
/// key the same as an empty array).
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct DeviceProfile {
    pub name: String,
    pub max_streaming_bitrate: u32,
    pub max_static_bitrate: u32,
    pub music_streaming_transcoding_bitrate: u32,
    pub direct_play_profiles: Vec<DirectPlayProfile>,
    pub transcoding_profiles: Vec<TranscodingProfile>,
}

impl DeviceProfile {
    /// AVFoundation / CoreAudio on macOS natively plays FLAC, ALAC (in m4a),
    /// MP3, AAC (in m4a/aac), Opus/OGG, and WAV — so we advertise those as
    /// direct-play containers. Anything else falls back to a 320 kbps MP3
    /// transcode, which is the universally-safe audio codec Jellyfin will
    /// emit when asked.
    ///
    /// The bitrate caps are music-centric: ~320 kbps for typical streaming
    /// and a generous `max_static_bitrate` so high-resolution direct plays
    /// (24-bit FLAC etc.) are not clamped by a too-low cap. Tweak the cap
    /// later if users ask for a lower ceiling in settings.
    pub fn default_macos_profile() -> Self {
        const AUDIO: &str = "Audio";
        let direct = |container: &str, codec: Option<&str>| DirectPlayProfile {
            container: container.to_string(),
            audio_codec: codec.map(|s| s.to_string()),
            kind: AUDIO.to_string(),
        };
        DeviceProfile {
            name: "Lyrebird Desktop (macOS)".to_string(),
            // 320 kbps ceiling for transcoded music; headroom for direct
            // plays to stream the original file at full fidelity.
            max_streaming_bitrate: 320_000,
            max_static_bitrate: 100_000_000,
            music_streaming_transcoding_bitrate: 320_000,
            direct_play_profiles: vec![
                direct("flac", None),
                direct("alac", None),
                direct("m4a", Some("alac")),
                direct("mp3", None),
                direct("aac", None),
                direct("m4a", Some("aac")),
                direct("opus", None),
                direct("ogg", Some("opus")),
                direct("ogg", Some("vorbis")),
                direct("wav", None),
            ],
            transcoding_profiles: vec![TranscodingProfile {
                container: "mp3".to_string(),
                audio_codec: "mp3".to_string(),
                protocol: "http".to_string(),
                context: "Streaming".to_string(),
                max_audio_channels: Some("2".to_string()),
                kind: AUDIO.to_string(),
            }],
        }
    }
}

// ============================================================================
// Capabilities — sent once post-auth so the server knows we're a playback
// target and can offer "Play on macOS" from Jellyfin Web.
// ============================================================================

/// The body for `POST /Sessions/Capabilities/Full`. Sent after auth so the
/// server registers this session as a music playback target.
///
/// `playable_media_types` / `supported_commands` are left as PascalCase
/// strings the server parses (e.g. `"Audio"`, `"VolumeUp"`, `"Pause"`).
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct ClientCapabilities {
    pub playable_media_types: Vec<String>,
    pub supported_commands: Vec<String>,
    pub supports_media_control: bool,
    pub supports_persistent_identifier: bool,
    pub device_profile: DeviceProfile,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_store_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_url: Option<String>,
}

// ============================================================================
// PlaybackInfo — resolves the right media source + transcode url before
// every stream.
// ============================================================================

/// Optional overrides for `POST /Items/{id}/PlaybackInfo`. All fields map
/// 1:1 onto Jellyfin's `PlaybackInfoDto`. `device_profile` is the only
/// field callers will almost always populate — the rest default to the
/// server's preferred behaviour when omitted.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackInfoOpts {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_time_ticks: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_source_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_streaming_bitrate: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enable_direct_play: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enable_direct_stream: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enable_transcoding: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auto_open_live_stream: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_profile: Option<DeviceProfile>,
}

/// A playable media source returned by `PlaybackInfo`. Mirrors the subset
/// of `MediaSourceInfo` a music client needs to decide between direct play
/// and transcoding. Anything video/subtitle-related is elided.
///
/// `transcoding_url` is the path the client should hit when direct play
/// is not viable — it's already annotated with the caller's `PlaySessionId`
/// so callers should pass it through verbatim rather than re-building it.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct MediaSourceInfo {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub container: Option<String>,
    #[serde(default)]
    pub bitrate: Option<i64>,
    #[serde(default)]
    pub size: Option<i64>,
    #[serde(default)]
    pub run_time_ticks: Option<i64>,
    #[serde(default)]
    pub supports_direct_play: bool,
    #[serde(default)]
    pub supports_direct_stream: bool,
    #[serde(default)]
    pub supports_transcoding: bool,
    #[serde(default)]
    pub transcoding_url: Option<String>,
    #[serde(default)]
    pub transcoding_sub_protocol: Option<String>,
    #[serde(default)]
    pub transcoding_container: Option<String>,
}

/// Response body for `POST /Items/{id}/PlaybackInfo`. Carries every
/// playable media source for the item plus the `PlaySessionId` the
/// caller must echo back on subsequent `/Sessions/Playing` reports so
/// the server can correlate them.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackInfoResponse {
    #[serde(default)]
    pub media_sources: Vec<MediaSourceInfo>,
    #[serde(default)]
    pub play_session_id: Option<String>,
    #[serde(default)]
    pub error_code: Option<String>,
}

// ============================================================================
// Playback start report — sent to `POST /Sessions/Playing` on track load so
// Jellyfin shows "Now playing on macOS" for this device.
// ============================================================================

/// The body for `POST /Sessions/Playing`. Mirrors Jellyfin's
/// `PlaybackStartInfo`, which is itself a subset of `PlaybackProgressInfo`
/// — everything optional is skipped when `None` to keep the wire payload
/// small.
///
/// `position_ticks` / `playback_start_time_ticks` are in Jellyfin's 100-ns
/// tick units (`seconds * 10_000_000`).
///
/// `play_method` is one of `"DirectPlay"`, `"DirectStream"`, `"Transcode"`
/// — left as a raw string so callers forward whatever the `/PlaybackInfo`
/// response implied without a round-trip through a local enum.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackStartInfo {
    pub item_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_source_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_stream_index: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position_ticks: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playback_start_time_ticks: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume_level: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playlist_index: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playlist_length: Option<i32>,
    pub can_seek: bool,
    pub is_paused: bool,
    pub is_muted: bool,
}

// ============================================================================
// Playback progress report — sent to `POST /Sessions/Playing/Progress`
// periodically during playback and on pause/resume/seek transitions.
// ============================================================================

/// The body for `POST /Sessions/Playing/Progress`. Mirrors Jellyfin's
/// `PlaybackProgressInfo` DTO.
///
/// `Failed` must always be sent (Jellyfin 10.9+ validates its presence).
/// `PlayMethod` is one of `"DirectPlay"`, `"DirectStream"`, `"Transcode"`.
/// `PlaybackRate` is `1.0` during normal playback; set to the actual
/// speed when the user changes playback rate. All tick fields are in
/// Jellyfin's 100-ns tick units (`seconds * 10_000_000`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackProgressInfo {
    pub item_id: String,
    /// Whether playback failed. Must be sent; typically `false`.
    pub failed: bool,
    pub is_paused: bool,
    pub is_muted: bool,
    pub position_ticks: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_source_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume_level: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playback_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_stream_index: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

// ============================================================================
// Playback stopped report — sent to `POST /Sessions/Playing/Stopped`.
// ============================================================================

/// The body for `POST /Sessions/Playing/Stopped`. Mirrors Jellyfin's
/// `PlaybackStopInfo` DTO.
///
/// `Failed` must always be sent; set to `true` if playback ended due to
/// an error. `MediaSourceId` must match the value returned by
/// `/PlaybackInfo` so the server can clean up the transcode job.
/// `PositionTicks` near `RunTimeTicks` signals a completed play and
/// triggers the server-side play-count increment.
#[derive(Clone, Debug, Default, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "PascalCase")]
pub struct PlaybackStopInfo {
    pub item_id: String,
    /// Whether playback ended due to an error. Must be sent; typically `false`.
    pub failed: bool,
    pub position_ticks: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_source_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

// `ImageType` now lives in `crate::enums` alongside the other typed query
// enums (`ItemKind`, `ItemSortBy`, `SortOrder`, `ItemField`). It is
// re-exported from the crate root for backwards-compatible imports.
