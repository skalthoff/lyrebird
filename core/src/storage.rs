use crate::error::{LyrebirdError, Result};
use crate::player::RepeatMode;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: i32 = 2;

pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent).map_err(|e| LyrebirdError::Storage(e.to_string()))?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        let db = Database {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let db = Database {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)",
            [],
        )?;
        // Propagate the read error with `?` rather than `.unwrap_or(0)`: the
        // `schema_version` table was just created in this same transaction, so
        // a successful read is expected. Swallowing a transient failure (e.g.
        // a momentary lock) to `0` would re-enter the `current < 1` branch on
        // an already-migrated DB and crash on the version insert.
        let current: i32 = tx.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_version",
            [],
            |r| r.get(0),
        )?;

        if current < 1 {
            tx.execute_batch(include_str!("migrations/001_initial.sql"))?;
            // `OR IGNORE` keeps the version stamp idempotent so a re-run can't
            // crash on the PRIMARY KEY constraint.
            tx.execute(
                "INSERT OR IGNORE INTO schema_version (version) VALUES (?1)",
                params![1],
            )?;
        }

        if current < 2 {
            // Offline downloads index (#819). Additive: adds the `downloads`
            // table + its LRU index, leaving every v1 table untouched.
            tx.execute_batch(include_str!("migrations/002_downloads.sql"))?;
            tx.execute(
                "INSERT OR IGNORE INTO schema_version (version) VALUES (?1)",
                params![2],
            )?;
        }

        if current < SCHEMA_VERSION {
            // Future migrations inserted here as `if current < N { ... }` blocks.
        }

        tx.commit()?;
        Ok(())
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?1")?;
        // Discriminate "no such key" (a legitimate `Ok(None)`) from a genuine
        // DB fault (locked / I/O / corruption). The old `.ok()` collapsed both
        // into `None`, silently reporting a real fault as "setting absent" —
        // the same NoEntry-vs-error split `CredentialStore::load_token` does.
        match stmt.query_row(params![key], |r| r.get::<_, String>(0)) {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn delete_setting(&self, key: &str) -> Result<()> {
        self.conn
            .lock()
            .execute("DELETE FROM settings WHERE key = ?1", params![key])?;
        Ok(())
    }

    /// Persist the current shuffle flag and repeat mode so they survive an app
    /// restart. Values are stored as two rows in the `settings` table under
    /// `"shuffle_enabled"` and `"repeat_mode"`.
    pub fn save_shuffle_repeat(&self, shuffle: bool, repeat: RepeatMode) -> Result<()> {
        let repeat_str = match repeat {
            RepeatMode::Off => "off",
            RepeatMode::One => "one",
            RepeatMode::All => "all",
        };
        self.set_setting("shuffle_enabled", if shuffle { "true" } else { "false" })?;
        self.set_setting("repeat_mode", repeat_str)?;
        Ok(())
    }

    /// Read back the shuffle flag and repeat mode written by
    /// [`Self::save_shuffle_repeat`]. Returns `(false, RepeatMode::Off)` when
    /// no values have been stored yet (first launch or fresh install).
    pub fn load_shuffle_repeat(&self) -> Result<(bool, RepeatMode)> {
        let shuffle = self
            .get_setting("shuffle_enabled")?
            .map(|v| v == "true")
            .unwrap_or(false);
        let repeat = match self.get_setting("repeat_mode")?.as_deref().unwrap_or("off") {
            "one" => RepeatMode::One,
            "all" => RepeatMode::All,
            _ => RepeatMode::Off,
        };
        Ok((shuffle, repeat))
    }

    /// Clear all user-scoped data after a logout or server switch.
    ///
    /// Truncates `track_cache`, `album_cache`, and `artist_cache`, and removes
    /// the session-identity settings (`last_server_url`, `last_username`,
    /// `last_server_id`, `last_user_id`) that would cause `resume_session` to
    /// succeed on next launch.
    ///
    /// Preserves: `device_id`, `device_name`, `shuffle_enabled`,
    /// `repeat_mode`, and `schema_version` rows so the login screen
    /// remembers the endpoint and playback preferences survive sign-out.
    pub fn clear_user_data(&self) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute_batch(
            "DELETE FROM track_cache;
             DELETE FROM album_cache;
             DELETE FROM artist_cache;",
        )?;
        let session_keys = [
            "last_server_url",
            "last_username",
            "last_server_id",
            "last_user_id",
        ];
        for key in &session_keys {
            conn.execute(
                "DELETE FROM settings WHERE key = ?1",
                rusqlite::params![key],
            )?;
        }
        Ok(())
    }

    // ------------------------------------------------------------------------
    // Offline downloads index (#819).
    //
    // Thin CRUD over the `downloads` table. The connection lives here, so these
    // methods are the single writer/reader; the orchestration (streaming bytes
    // to disk, budget enforcement) lives in `crate::downloads`, which calls
    // through these. Returned shapes are intentionally primitive tuples / the
    // `DownloadRow` struct so `storage.rs` stays free of the FFI-facing
    // `DownloadEntry` mapping (that's `downloads.rs`'s job).
    // ------------------------------------------------------------------------

    /// Insert (or reset) a download row in the `queued` state. `track_json` is
    /// the serialized [`crate::models::Track`] snapshot. Re-enqueuing an
    /// existing row clears any prior `local_path` / `size_bytes` / `error` and
    /// returns it to `queued` so a failed download can be retried cleanly.
    pub fn download_upsert_queued(
        &self,
        track_id: &str,
        track_json: &str,
        created_at: i64,
    ) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO downloads (track_id, track_json, state, created_at) \
             VALUES (?1, ?2, 'queued', ?3) \
             ON CONFLICT(track_id) DO UPDATE SET \
                 track_json = excluded.track_json, \
                 state = 'queued', \
                 local_path = NULL, \
                 size_bytes = 0, \
                 error = NULL, \
                 completed_at = NULL",
            params![track_id, track_json, created_at],
        )?;
        Ok(())
    }

    /// Move a row to the `downloading` state. No-op if the row is gone.
    pub fn download_mark_downloading(&self, track_id: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE downloads SET state = 'downloading', error = NULL WHERE track_id = ?1",
            params![track_id],
        )?;
        Ok(())
    }

    /// Mark a download complete: record its on-disk path, byte size, container,
    /// and completion timestamp, flipping it to `done`.
    pub fn download_mark_done(
        &self,
        track_id: &str,
        local_path: &str,
        size_bytes: u64,
        container: Option<&str>,
        completed_at: i64,
    ) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE downloads SET state = 'done', local_path = ?2, size_bytes = ?3, \
                 container = ?4, error = NULL, completed_at = ?5 WHERE track_id = ?1",
            params![
                track_id,
                local_path,
                size_bytes as i64,
                container,
                completed_at
            ],
        )?;
        Ok(())
    }

    /// Mark a download failed with a human-readable reason. Leaves any prior
    /// `local_path` cleared so a half-written file is never treated as playable.
    pub fn download_mark_failed(&self, track_id: &str, error: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE downloads SET state = 'failed', error = ?2, local_path = NULL, \
                 size_bytes = 0, completed_at = NULL WHERE track_id = ?1",
            params![track_id, error],
        )?;
        Ok(())
    }

    /// Delete a download row. Returns the `local_path` that was recorded (if
    /// any) so the caller can unlink the file on disk. Returns `Ok(None)` when
    /// no such row existed.
    pub fn download_delete(&self, track_id: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let path: Option<String> = match conn.query_row(
            "SELECT local_path FROM downloads WHERE track_id = ?1",
            params![track_id],
            |r| r.get::<_, Option<String>>(0),
        ) {
            Ok(p) => p,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        conn.execute(
            "DELETE FROM downloads WHERE track_id = ?1",
            params![track_id],
        )?;
        Ok(path)
    }

    /// Fetch a single download row by track id, or `None` when absent.
    pub fn download_get(&self, track_id: &str) -> Result<Option<DownloadRow>> {
        let conn = self.conn.lock();
        match conn.query_row(
            "SELECT track_id, track_json, local_path, container, size_bytes, state, \
                    error, created_at, completed_at \
             FROM downloads WHERE track_id = ?1",
            params![track_id],
            DownloadRow::from_sql_row,
        ) {
            Ok(row) => Ok(Some(row)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// All download rows, newest-enqueued first. Drives the Downloads screen.
    pub fn download_list(&self) -> Result<Vec<DownloadRow>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT track_id, track_json, local_path, container, size_bytes, state, \
                    error, created_at, completed_at \
             FROM downloads ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map([], DownloadRow::from_sql_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Sum of `size_bytes` across completed (`done`) downloads, plus the count
    /// of such rows. This is the figure compared against the storage budget.
    pub fn download_used_bytes(&self) -> Result<(u64, u32)> {
        let conn = self.conn.lock();
        let (sum, count): (i64, i64) = conn.query_row(
            "SELECT COALESCE(SUM(size_bytes), 0), COUNT(*) FROM downloads WHERE state = 'done'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok((sum.max(0) as u64, count.max(0) as u32))
    }

    /// Completed downloads ordered oldest-first (LRU). Returns
    /// `(track_id, local_path, size_bytes)` so the budget-eviction loop can
    /// pick victims and unlink their files. Rows missing a `local_path` are
    /// skipped — they can't be evicted by file deletion and don't count toward
    /// used bytes anyway.
    pub fn download_completed_lru(&self) -> Result<Vec<(String, String, u64)>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT track_id, local_path, size_bytes FROM downloads \
             WHERE state = 'done' AND local_path IS NOT NULL \
             ORDER BY completed_at ASC, created_at ASC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?.max(0) as u64,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }
}

/// A raw row of the `downloads` table, as read from SQLite. Lives in
/// `storage.rs` (next to the connection that produces it) and is mapped to the
/// FFI-facing [`crate::models::DownloadEntry`] in `crate::downloads`.
#[derive(Clone, Debug)]
pub struct DownloadRow {
    pub track_id: String,
    pub track_json: String,
    pub local_path: Option<String>,
    pub container: Option<String>,
    pub size_bytes: u64,
    /// Raw `state` column: `"queued" | "downloading" | "done" | "failed"`.
    pub state: String,
    pub error: Option<String>,
    pub created_at: i64,
    pub completed_at: Option<i64>,
}

impl DownloadRow {
    fn from_sql_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(DownloadRow {
            track_id: r.get(0)?,
            track_json: r.get(1)?,
            local_path: r.get(2)?,
            container: r.get(3)?,
            size_bytes: r.get::<_, i64>(4)?.max(0) as u64,
            state: r.get(5)?,
            error: r.get(6)?,
            created_at: r.get(7)?,
            completed_at: r.get(8)?,
        })
    }
}

pub fn default_data_dir() -> PathBuf {
    if let Some(dirs) = dirs_next_like() {
        dirs.join("lyrebird-desktop")
    } else {
        PathBuf::from(".").join(".lyrebird-desktop")
    }
}

fn dirs_next_like() -> Option<PathBuf> {
    // Minimal hand-rolled equivalent of `dirs::data_dir()` so we don't pull
    // another crate just for this. Prefer XDG_DATA_HOME on Unix, APPDATA on
    // Windows, ~/Library/Application Support on macOS.
    if let Ok(val) = std::env::var("XDG_DATA_HOME") {
        if !val.is_empty() {
            return Some(PathBuf::from(val));
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Ok(home) = std::env::var("HOME") {
            return Some(PathBuf::from(home).join("Library/Application Support"));
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Ok(appdata) = std::env::var("APPDATA") {
            return Some(PathBuf::from(appdata));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Ok(home) = std::env::var("HOME") {
            return Some(PathBuf::from(home).join(".local/share"));
        }
    }
    None
}

// ============================================================================
// Credentials — access tokens stored in OS credential store via `keyring`.
// ============================================================================

const SERVICE: &str = "org.lyrebird.desktop";

/// Keyring account under which the (account-independent) ListenBrainz scrobble
/// token is stored. A fixed, non-`{server}/{user}` key because the token is a
/// machine-level preference, not a per-Jellyfin-session credential. Kept in
/// the OS keyring like the Jellyfin access token rather than in plaintext in
/// the settings table.
const SCROBBLE_ACCOUNT: &str = "scrobble/listenbrainz";

pub struct CredentialStore;

impl CredentialStore {
    pub fn save_token(server_id: &str, username: &str, token: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        entry.set_password(token)?;
        Ok(())
    }

    pub fn load_token(server_id: &str, username: &str) -> Result<Option<String>> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        match entry.get_password() {
            Ok(t) => Ok(Some(t)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn delete_token(server_id: &str, username: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, &format!("{server_id}/{username}"))?;
        match entry.delete_credential() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Persist the ListenBrainz scrobble token in the OS keyring (same secure
    /// store as the Jellyfin access token), keyed on `SCROBBLE_ACCOUNT`.
    pub fn save_scrobble_token(token: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, SCROBBLE_ACCOUNT)?;
        entry.set_password(token)?;
        Ok(())
    }

    /// Read the stored ListenBrainz scrobble token, or `None` when none is
    /// stored. Discriminates a missing entry from a real keyring fault.
    pub fn load_scrobble_token() -> Result<Option<String>> {
        let entry = keyring::Entry::new(SERVICE, SCROBBLE_ACCOUNT)?;
        match entry.get_password() {
            Ok(t) => Ok(Some(t)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Remove the stored ListenBrainz scrobble token. A no-op when absent.
    pub fn delete_scrobble_token() -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, SCROBBLE_ACCOUNT)?;
        match entry.delete_credential() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

/// Silent re-auth helper used by the HTTP client's 401 interceptor.
///
/// Re-reads `(last_server_id, last_username)` from `db`, then asks the OS
/// credential store for the token that pair currently maps to. Returns the
/// token string when one is present.
///
/// The design is a "pull latest from the keyring" pattern: when Jellyfin
/// rejects a request with `401`, the in-memory token on the client may be
/// stale relative to what's in the keychain (e.g. another Lyrebird instance
/// refreshed it on this machine, or the user re-authenticated in a parallel
/// window). Re-reading the keyring is the cheap first step — callers that
/// want to force a full `POST /Users/AuthenticateByName` round trip drive
/// that from the UI layer, where the password is still in scope.
///
/// Returns `Ok(None)` when the persisted identifiers are missing or the
/// keyring has no entry for that `(server_id, username)` pair. Callers treat
/// that the same as "user must re-authenticate" and typically raise
/// [`crate::LyrebirdError::AuthExpired`].
pub fn refresh_token_from_keyring(db: &Database) -> Result<Option<String>> {
    let server_id = match db.get_setting("last_server_id")? {
        Some(v) => v,
        None => return Ok(None),
    };
    let username = match db.get_setting("last_username")? {
        Some(v) => v,
        None => return Ok(None),
    };
    CredentialStore::load_token(&server_id, &username)
}
