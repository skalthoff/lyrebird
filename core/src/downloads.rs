//! Offline downloads engine (#819).
//!
//! Keeps tracks available for offline playback by streaming their audio bytes
//! to disk and indexing them in the `downloads` table. The on-disk layout is a
//! flat `downloads/` directory under the configured root, one file per track:
//!
//! ```text
//! <root>/downloads/<track_id>.<ext>
//! ```
//!
//! The engine is deliberately stateless beyond what's in SQLite + on disk: it
//! is a set of free functions over an [`Arc<Database>`] and (for the fetch
//! path) a [`JellyfinClient`]. That mirrors the rest of the core — `lib.rs`
//! clones the `Arc`s under the `Inner` mutex, drops the guard, then calls these
//! on the tokio runtime so a long download never holds the FFI lock.
//!
//! ## Budget
//!
//! A configurable storage budget (bytes; 0 = unlimited) caps total disk used by
//! *completed* downloads. Before a fetch, the budget planner evicts the
//! oldest-completed downloads (LRU on `completed_at`) to make room; if even an
//! empty store can't fit the incoming track the enqueue is refused with
//! [`LyrebirdError::Storage`]. This is the "evict/refuse past budget" contract.

use crate::client::JellyfinClient;
use crate::error::{LyrebirdError, Result};
use crate::models::{DownloadEntry, DownloadState, DownloadStats, Track};
use crate::storage::{Database, DownloadRow};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Settings-table key under which the download root override is persisted.
/// Empty / absent means "use `<data_dir>/downloads`".
pub const DOWNLOAD_DIR_KEY: &str = "downloads_dir";

/// Settings-table key for the storage budget in bytes. Absent / "0" means
/// unlimited.
pub const DOWNLOAD_BUDGET_KEY: &str = "downloads_budget_bytes";

/// Map a raw `state` column string to the typed [`DownloadState`]. Unknown
/// values (only reachable via a hand-edited DB) degrade to `Failed` so the row
/// is never mistaken for a playable `Done`.
fn parse_state(raw: &str) -> DownloadState {
    match raw {
        "queued" => DownloadState::Queued,
        "downloading" => DownloadState::Downloading,
        "done" => DownloadState::Done,
        _ => DownloadState::Failed,
    }
}

/// Convert a stored [`DownloadRow`] into the FFI-facing [`DownloadEntry`].
///
/// The `track_json` snapshot is deserialized back into a [`Track`]; if that
/// fails (an upgrade changed the `Track` shape, say) the row is reported as
/// `Failed` with a decode error rather than being dropped, so the UI can still
/// offer a delete affordance.
fn row_to_entry(row: DownloadRow) -> DownloadEntry {
    match serde_json::from_str::<Track>(&row.track_json) {
        Ok(track) => DownloadEntry {
            track,
            state: parse_state(&row.state),
            local_path: row.local_path,
            size_bytes: row.size_bytes,
            error: row.error,
            created_at: row.created_at,
            completed_at: row.completed_at,
        },
        Err(e) => DownloadEntry {
            // A minimal placeholder track so the row is still addressable.
            track: Track {
                id: row.track_id,
                name: String::new(),
                album_id: None,
                album_name: None,
                artist_name: String::new(),
                artist_id: None,
                index_number: None,
                disc_number: None,
                year: None,
                runtime_ticks: 0,
                is_favorite: false,
                play_count: 0,
                container: row.container,
                bitrate: None,
                image_tag: None,
                playlist_item_id: None,
                user_data: None,
            },
            state: DownloadState::Failed,
            local_path: None,
            size_bytes: 0,
            error: Some(format!("corrupt download record: {e}")),
            created_at: row.created_at,
            completed_at: row.completed_at,
        },
    }
}

/// Resolve the directory offline audio files live in.
///
/// Prefers the persisted [`DOWNLOAD_DIR_KEY`] override; otherwise falls back to
/// `<data_dir>/downloads`. The directory is **not** created here — the fetch
/// path creates it lazily so a read-only query (list / stats) never has a side
/// effect.
pub fn download_dir(db: &Database, data_dir: &Path) -> PathBuf {
    match db.get_setting(DOWNLOAD_DIR_KEY).ok().flatten() {
        Some(custom) if !custom.trim().is_empty() => PathBuf::from(custom),
        _ => data_dir.join("downloads"),
    }
}

/// Read the configured storage budget in bytes. `0` means unlimited.
pub fn budget_bytes(db: &Database) -> u64 {
    db.get_setting(DOWNLOAD_BUDGET_KEY)
        .ok()
        .flatten()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(0)
}

/// Pick a file extension for the downloaded audio.
///
/// Prefers the track's known `container`; otherwise infers from the server's
/// `Content-Type`. Falls back to `bin` so a file is always written with *some*
/// extension. The extension is cosmetic for AVFoundation (which sniffs the
/// bytes), but a faithful one keeps the cache directory legible.
fn extension_for(container: Option<&str>, content_type: Option<&str>) -> String {
    if let Some(c) = container {
        let c = c.trim().trim_start_matches('.').to_ascii_lowercase();
        if !c.is_empty() {
            // `container` can be a comma list (e.g. "mp3,aac"); take the first.
            if let Some(first) = c.split(',').next() {
                if !first.is_empty() {
                    return first.to_string();
                }
            }
        }
    }
    match content_type.map(|s| {
        s.split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase()
    }) {
        Some(mime) => match mime.as_str() {
            "audio/mpeg" | "audio/mp3" => "mp3",
            "audio/aac" => "aac",
            "audio/mp4" | "audio/m4a" | "audio/x-m4a" => "m4a",
            "audio/flac" | "audio/x-flac" => "flac",
            "audio/ogg" | "application/ogg" => "ogg",
            "audio/opus" => "opus",
            "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
            _ => "bin",
        },
        None => "bin",
    }
    .to_string()
}

/// Current `(used_bytes, item_count)` for completed downloads.
pub fn stats(db: &Database) -> Result<DownloadStats> {
    let (used_bytes, item_count) = db.download_used_bytes()?;
    Ok(DownloadStats {
        used_bytes,
        budget_bytes: budget_bytes(db),
        item_count,
    })
}

/// The typed download state for a single track (`None` when the track has no
/// download row at all). The hot per-track query the UI consults.
pub fn state_for(db: &Database, track_id: &str) -> Result<Option<DownloadState>> {
    Ok(db
        .download_get(track_id)?
        .map(|row| parse_state(&row.state)))
}

/// The absolute on-disk path of a track's completed download, or `None` when
/// the track isn't downloaded, isn't yet `done`, or the file has gone missing.
///
/// The file-existence check is what makes offline playback safe: a stale `done`
/// row whose backing file was deleted out from under us (manual cleanup, macOS
/// cache eviction) reports `None`, so the player falls back to streaming
/// instead of handing AVFoundation a dead path.
pub fn local_path_for(db: &Database, track_id: &str) -> Result<Option<String>> {
    let row = match db.download_get(track_id)? {
        Some(r) => r,
        None => return Ok(None),
    };
    if parse_state(&row.state) != DownloadState::Done {
        return Ok(None);
    }
    match row.local_path {
        Some(p) if Path::new(&p).exists() => Ok(Some(p)),
        _ => Ok(None),
    }
}

/// Every download row as FFI entries, newest-enqueued first.
pub fn list(db: &Database) -> Result<Vec<DownloadEntry>> {
    Ok(db.download_list()?.into_iter().map(row_to_entry).collect())
}

/// Delete a download: remove the DB row and unlink its on-disk file.
///
/// Idempotent — deleting a track that was never downloaded is a successful
/// no-op. The file unlink is best-effort; a missing file (already gone) is not
/// an error.
pub fn delete(db: &Database, track_id: &str) -> Result<()> {
    if let Some(path) = db.download_delete(track_id)? {
        let _ = std::fs::remove_file(&path);
        // Also clean up any leftover `.part` from an interrupted fetch.
        let _ = std::fs::remove_file(Path::new(&path).with_extension("part"));
    }
    Ok(())
}

/// Record an enqueue: snapshot the track into the `downloads` table in the
/// `queued` state. Does not fetch bytes — [`fetch`] does that. Separated so the
/// UI can optimistically show a queued badge the instant the user taps,
/// independent of the network round trip.
pub fn enqueue(db: &Database, track: &Track, now: i64) -> Result<()> {
    let json = serde_json::to_string(track)?;
    db.download_upsert_queued(&track.id, &json, now)
}

/// Evict completed downloads (oldest-first) until `incoming_bytes` would fit
/// within `budget` alongside what remains.
///
/// Returns `Err(Storage)` when `incoming_bytes` alone exceeds a non-zero budget
/// — no amount of eviction can make room, so the caller must refuse the
/// download. A `budget` of 0 (unlimited) short-circuits to `Ok(())`.
///
/// `incoming_bytes` is an *estimate* available before the fetch (from the
/// track's bitrate × duration); the post-fetch true size is reconciled by the
/// caller. Over-eviction from a high estimate is acceptable — it errs toward
/// staying under budget.
fn ensure_budget_for(db: &Database, budget: u64, incoming_bytes: u64) -> Result<()> {
    if budget == 0 {
        return Ok(());
    }
    if incoming_bytes > budget {
        return Err(LyrebirdError::Storage(format!(
            "track ({incoming_bytes} bytes) exceeds the entire download budget ({budget} bytes)"
        )));
    }
    let (mut used, _) = db.download_used_bytes()?;
    if used + incoming_bytes <= budget {
        return Ok(());
    }
    // Evict LRU completed downloads until the incoming track fits.
    for (track_id, path, size) in db.download_completed_lru()? {
        if used + incoming_bytes <= budget {
            break;
        }
        // Remove the row + file; subtract its size from the running total.
        if db.download_delete(&track_id)?.is_some() {
            let _ = std::fs::remove_file(&path);
        }
        used = used.saturating_sub(size);
    }
    Ok(())
}

/// Estimate a track's on-disk size from its bitrate and duration. Used only for
/// pre-fetch budget planning; falls back to a conservative 0 (which makes the
/// budget check a no-op until the true size is known post-fetch) when the track
/// carries no bitrate.
fn estimate_bytes(track: &Track) -> u64 {
    match track.bitrate {
        Some(bps) if bps > 0 => {
            let secs = track.duration_seconds();
            if secs.is_finite() && secs > 0.0 {
                ((bps as f64) * secs / 8.0) as u64
            } else {
                0
            }
        }
        _ => 0,
    }
}

/// Download a queued track's audio to disk and mark it `done`.
///
/// The full pipeline for one track:
/// 1. Enforce the budget (evict LRU / refuse) using a pre-fetch size estimate.
/// 2. Mark the row `downloading`.
/// 3. Stream bytes to `<dir>/<track_id>.<ext>` via [`JellyfinClient::download_to_file`].
/// 4. Re-check the budget against the *true* byte size; if the real file blew
///    past the budget, evict to make room (keeping this download).
/// 5. Mark the row `done` with its path + size.
///
/// On any failure the row is flipped to `failed` with the error recorded, and
/// the error is returned so the caller (UI) can surface it. The partial file is
/// cleaned up by `download_to_file` itself.
///
/// `now` is the completion timestamp the caller passes (Unix seconds) so tests
/// can pin it.
pub async fn fetch(
    db: &Arc<Database>,
    client: &JellyfinClient,
    data_dir: &Path,
    track: &Track,
    now: i64,
) -> Result<DownloadEntry> {
    let dir = download_dir(db, data_dir);
    let budget = budget_bytes(db);

    // 1. Pre-fetch budget planning against an estimate.
    if let Err(e) = ensure_budget_for(db, budget, estimate_bytes(track)) {
        let _ = db.download_mark_failed(&track.id, &e.to_string());
        return Err(e);
    }

    // 2. In-progress marker so the UI shows a spinner.
    db.download_mark_downloading(&track.id)?;

    // 3. Stream to disk. We don't yet know the real extension until the
    //    response arrives, but the destination path must be fixed up front; use
    //    the track's container hint, then settle the file's final name after we
    //    learn the content-type. To keep it simple and avoid a rename dance, we
    //    pick the extension from the container hint when present, else `bin`,
    //    download, then (if the content-type disagrees) the file already plays
    //    via byte-sniffing regardless. Most Jellyfin music carries a container.
    let provisional_ext = extension_for(track.container.as_deref(), None);
    let dest = dir.join(format!("{}.{provisional_ext}", track.id));

    let (size, content_type) = match client.download_to_file(&track.id, &dest).await {
        Ok(v) => v,
        Err(e) => {
            let _ = db.download_mark_failed(&track.id, &e.to_string());
            return Err(e);
        }
    };

    // 4. Reconcile against the true size. If the real file pushed us over a
    //    non-zero budget, evict *other* completed downloads to make room;
    //    never delete the file we just fetched.
    if budget > 0 {
        let (used, _) = db.download_used_bytes()?;
        if used + size > budget {
            // Evict LRU (excluding this track, which isn't `done` yet) until it
            // fits. If it still can't fit even an otherwise-empty store, fail
            // the download and remove the file.
            if let Err(e) = ensure_budget_for(db, budget, size) {
                let _ = std::fs::remove_file(&dest);
                let _ = db.download_mark_failed(&track.id, &e.to_string());
                return Err(e);
            }
        }
    }

    // 5. Commit.
    let final_container = track
        .container
        .clone()
        .or_else(|| Some(extension_for(None, content_type.as_deref())));
    let path_str = dest.to_string_lossy().to_string();
    db.download_mark_done(&track.id, &path_str, size, final_container.as_deref(), now)?;

    match db.download_get(&track.id)? {
        Some(row) => Ok(row_to_entry(row)),
        // Shouldn't happen — we just wrote it — but don't panic across FFI.
        None => Err(LyrebirdError::Storage(
            "download row vanished after completion".into(),
        )),
    }
}

#[cfg(test)]
mod unit {
    use super::*;

    #[test]
    fn extension_prefers_container_then_content_type() {
        assert_eq!(extension_for(Some("flac"), None), "flac");
        assert_eq!(extension_for(Some(".MP3"), None), "mp3");
        assert_eq!(extension_for(Some("mp3,aac"), None), "mp3");
        assert_eq!(extension_for(None, Some("audio/mpeg")), "mp3");
        assert_eq!(
            extension_for(None, Some("audio/flac; charset=binary")),
            "flac"
        );
        assert_eq!(extension_for(None, None), "bin");
        assert_eq!(extension_for(Some(""), Some("audio/aac")), "aac");
    }

    #[test]
    fn parse_state_unknown_is_failed() {
        assert_eq!(parse_state("queued"), DownloadState::Queued);
        assert_eq!(parse_state("done"), DownloadState::Done);
        assert_eq!(parse_state("garbage"), DownloadState::Failed);
    }
}
