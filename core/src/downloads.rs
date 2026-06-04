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

/// Validate a track id as a filename stem.
///
/// The id is server-supplied and flows straight into the on-disk path
/// (`<dir>/<id>.<ext>`), so an id containing path separators or `..` could
/// escape the downloads directory on write — and, because the same id is later
/// used to locate the file for deletion, on delete too. Jellyfin item ids are
/// GUIDs rendered as 32 lowercase hex chars (some deployments dash-group them),
/// so we accept only ASCII alphanumerics and `-`. Anything else (a separator,
/// `.`, NUL, whitespace, a leading dot) is rejected. An empty id is rejected.
///
/// Returns the id unchanged when valid, or [`LyrebirdError::InvalidInput`] when
/// it is not safe to use as a filename stem.
fn safe_filename_stem(track_id: &str) -> Result<&str> {
    let ok = !track_id.is_empty()
        && track_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-');
    if ok {
        Ok(track_id)
    } else {
        Err(LyrebirdError::InvalidInput(format!(
            "refusing to download track with unsafe id: {track_id:?}"
        )))
    }
}

/// Build the on-disk destination for a track's audio and assert it stays inside
/// `dir`.
///
/// Defence in depth over [`safe_filename_stem`]: even with a sanitized stem we
/// normalise the joined path and require it to remain a child of `dir`, so a
/// future change to the naming scheme can't silently reintroduce a traversal.
/// `dir` itself isn't required to exist yet (the fetch path creates it lazily),
/// so we compare against `dir` lexically rather than canonicalising it.
fn dest_within_dir(dir: &Path, stem: &str, ext: &str) -> Result<PathBuf> {
    let dest = dir.join(format!("{stem}.{ext}"));
    // The joined path must have `dir` as a prefix and contribute exactly one
    // additional, normal path component (the file name). `Path::join` on an
    // absolute / separator-bearing component would replace or escape `dir`;
    // `safe_filename_stem` already forbids those, this is the belt-and-braces.
    let within = dest.starts_with(dir)
        && dest.file_name().is_some()
        && dest
            .strip_prefix(dir)
            .map(|rest| rest.components().count() == 1)
            == Ok(true);
    if within {
        Ok(dest)
    } else {
        Err(LyrebirdError::Storage(format!(
            "computed download path {dest:?} escapes the downloads directory {dir:?}"
        )))
    }
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
    // `estimate_bytes` is derived from unvalidated server-supplied
    // bitrate × duration, so a pathological estimate (or a corrupt `used`
    // sum) could wrap a plain `used + incoming_bytes` and slip past the
    // `<= budget` check. Saturate so an overflow can never *pass* the gate.
    if used.saturating_add(incoming_bytes) <= budget {
        return Ok(());
    }
    // Evict LRU completed downloads until the incoming track fits.
    for (track_id, path, size) in db.download_completed_lru()? {
        if used.saturating_add(incoming_bytes) <= budget {
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
/// 1. Acquire a transfer permit (caps parallel fetches per #819 — default 2).
/// 2. Under the budget lock: enforce the budget (evict LRU / refuse) using a
///    pre-fetch size estimate, then mark the row `downloading`.
/// 3. Stream bytes to `<dir>/<sanitized_track_id>.<ext>` via
///    [`JellyfinClient::download_to_file`] (lock released — only the cap bounds
///    concurrency here).
/// 4. Under the budget lock again: re-check the budget against the *true* byte
///    size (now reflecting any sibling that committed while we streamed); if the
///    real file blew past the budget, evict to make room, then mark the row
///    `done`. Doing the final size check + commit under the lock is what closes
///    the check-then-act race between concurrent fetches.
///
/// On any failure the row is flipped to `failed` with the error recorded, and
/// the error is returned so the caller (UI) can surface it. The partial file is
/// cleaned up by `download_to_file` itself.
///
/// `budget_lock` serialises budget planning + the size-checked commit so two
/// concurrent fetches can't each pass the budget check and collectively exceed
/// it. `permits` bounds how many transfers stream at once. Both are owned by
/// `LyrebirdCore` and shared across all `download_track` calls.
///
/// `now` is the completion timestamp the caller passes (Unix seconds) so tests
/// can pin it.
pub async fn fetch(
    db: &Arc<Database>,
    client: &JellyfinClient,
    data_dir: &Path,
    track: &Track,
    now: i64,
    permits: &tokio::sync::Semaphore,
    budget_lock: &tokio::sync::Mutex<()>,
) -> Result<DownloadEntry> {
    let dir = download_dir(db, data_dir);
    let budget = budget_bytes(db);

    // Validate the server-supplied id before it ever touches the filesystem,
    // and fix the destination up front so a single sanitized path is used for
    // both the write here and any later delete. `?` here propagates the error
    // without writing a row, mirroring `enqueue`'s up-front validation; mark the
    // row failed too so an already-queued retry doesn't spin forever.
    let stem = match safe_filename_stem(&track.id) {
        Ok(s) => s,
        Err(e) => {
            let _ = db.download_mark_failed(&track.id, &e.to_string());
            return Err(e);
        }
    };
    let provisional_ext = extension_for(track.container.as_deref(), None);
    let dest = match dest_within_dir(&dir, stem, &provisional_ext) {
        Ok(d) => d,
        Err(e) => {
            let _ = db.download_mark_failed(&track.id, &e.to_string());
            return Err(e);
        }
    };

    // 1. Cap parallel transfers. The permit is held for the whole fetch; the
    //    semaphore is never closed, so acquire only fails on a poisoned runtime,
    //    which we surface rather than unwrap.
    let _permit = permits
        .acquire()
        .await
        .map_err(|e| LyrebirdError::Other(format!("download semaphore closed: {e}")))?;

    // 2. Pre-fetch budget planning against an estimate + in-progress marker,
    //    serialised against other fetches' planning/commit.
    {
        let _budget = budget_lock.lock().await;
        if let Err(e) = ensure_budget_for(db, budget, estimate_bytes(track)) {
            let _ = db.download_mark_failed(&track.id, &e.to_string());
            return Err(e);
        }
        db.download_mark_downloading(&track.id)?;
    }

    // 3. Stream to disk. We don't yet know the real extension until the
    //    response arrives, but the destination path must be fixed up front; we
    //    pick the extension from the container hint when present, else `bin`.
    //    If the content-type later disagrees, the file still plays via
    //    AVFoundation byte-sniffing. Most Jellyfin music carries a container.
    //    The budget lock is intentionally NOT held across this network I/O —
    //    only the transfer permit bounds concurrency here.
    let (size, content_type) = match client.download_to_file(&track.id, &dest).await {
        Ok(v) => v,
        Err(e) => {
            let _ = db.download_mark_failed(&track.id, &e.to_string());
            return Err(e);
        }
    };

    // 4. Reconcile against the true size and commit, under the budget lock so a
    //    sibling that committed while we streamed is reflected in `used` and we
    //    can't collectively overshoot the budget. If the real file pushed us
    //    over a non-zero budget, evict *other* completed downloads to make room;
    //    never delete the file we just fetched.
    let _budget = budget_lock.lock().await;
    if budget > 0 {
        let (used, _) = db.download_used_bytes()?;
        if used.saturating_add(size) > budget {
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

    #[test]
    fn safe_filename_stem_accepts_guid_shapes() {
        // 32-hex GUID (Jellyfin's usual rendering) and the dash-grouped form.
        assert!(safe_filename_stem("0f8fad5bd9cb469fa16570867728950e").is_ok());
        assert!(safe_filename_stem("0f8fad5b-d9cb-469f-a165-70867728950e").is_ok());
        assert!(safe_filename_stem("Track123").is_ok());
    }

    #[test]
    fn safe_filename_stem_rejects_traversal_and_separators() {
        for bad in [
            "",
            "..",
            "../../etc/passwd",
            "a/b",
            "a\\b",
            "a.b", // a dot would split the extension / hide a second ext
            "with space",
            ".hidden",
            "a\0b",
            "abc/../def",
        ] {
            assert!(
                matches!(safe_filename_stem(bad), Err(LyrebirdError::InvalidInput(_))),
                "expected {bad:?} to be rejected"
            );
        }
    }

    #[test]
    fn dest_within_dir_keeps_path_inside() {
        let dir = Path::new("/var/data/downloads");
        let dest = dest_within_dir(dir, "abc123", "mp3").unwrap();
        assert_eq!(dest, Path::new("/var/data/downloads/abc123.mp3"));
        assert!(dest.starts_with(dir));
    }

    #[test]
    fn dest_within_dir_rejects_escape() {
        let dir = Path::new("/var/data/downloads");
        // A stem with a separator would `join` to escape `dir`. (Such stems are
        // already blocked by `safe_filename_stem`; this is the second gate.)
        assert!(matches!(
            dest_within_dir(dir, "../evil", "mp3"),
            Err(LyrebirdError::Storage(_))
        ));
        // An absolute "stem" replaces `dir` entirely under `Path::join`.
        assert!(matches!(
            dest_within_dir(dir, "/etc/cron.d/evil", "mp3"),
            Err(LyrebirdError::Storage(_))
        ));
    }
}
