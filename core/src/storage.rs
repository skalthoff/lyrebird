use crate::error::{LyrebirdError, Result};
use crate::player::RepeatMode;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const SCHEMA_VERSION: i32 = 3;

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

        if current < 3 {
            // Library-cache sort keys (#431). Additive: a `sort_key` column +
            // index on each of the three (previously unused) cache tables so
            // the cache-first launch path can serve "first N in display
            // order" without parsing JSON per row.
            tx.execute_batch(include_str!("migrations/003_library_cache_sort.sql"))?;
            tx.execute(
                "INSERT OR IGNORE INTO schema_version (version) VALUES (?1)",
                params![3],
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
    /// Truncates `track_cache`, `album_cache`, and `artist_cache` (plus their
    /// `library_last_sync_*` / `library_cache_user_id` settings — see
    /// [`Self::clear_library_cache`]), and removes the session-identity
    /// settings (`last_server_url`, `last_username`, `last_server_id`,
    /// `last_user_id`) that would cause `resume_session` to succeed on next
    /// launch.
    ///
    /// Preserves: `device_id`, `device_name`, `shuffle_enabled`,
    /// `repeat_mode`, and `schema_version` rows so the login screen
    /// remembers the endpoint and playback preferences survive sign-out.
    pub fn clear_user_data(&self) -> Result<()> {
        let conn = self.conn.lock();
        Self::clear_library_cache_locked(&conn)?;
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

    /// Truncate the three library cache tables and drop the per-user
    /// `library_last_sync_*` checkpoint settings (#431).
    ///
    /// Called from [`Self::clear_user_data`] on logout, and directly when a
    /// *different* user signs in over a session that was merely
    /// token-forgotten (`forget_token` keeps the cache so the common
    /// re-auth-as-the-same-user path stays warm) — cached rows must never
    /// leak across accounts.
    pub fn clear_library_cache(&self) -> Result<()> {
        Self::clear_library_cache_locked(&self.conn.lock())
    }

    fn clear_library_cache_locked(conn: &Connection) -> Result<()> {
        conn.execute_batch(
            "DELETE FROM track_cache;
             DELETE FROM album_cache;
             DELETE FROM artist_cache;
             DELETE FROM settings WHERE key LIKE 'library_last_sync_%';
             DELETE FROM settings WHERE key = 'library_cache_user_id';",
        )?;
        Ok(())
    }

    // ------------------------------------------------------------------------
    // Library cache (#431).
    //
    // Thin CRUD over the `album_cache` / `artist_cache` / `track_cache`
    // tables, mirroring the downloads pattern: the connection lives here, the
    // JSON (de)serialization and sync orchestration live in
    // `crate::library_cache`. Rows are `(id, data, sort_key, updated_at)`
    // where `data` is the serialized model JSON and `sort_key` is the
    // precomputed display-order key (see `library_cache::sort_key`).
    // ------------------------------------------------------------------------

    /// Upsert a batch of cache rows in one transaction, returning the ids
    /// whose stored JSON actually changed (i.e. new rows plus rows whose
    /// `data` differs from what was stored). Rows whose JSON is identical to
    /// the stored copy are left untouched — `updated_at` therefore reads as
    /// "content last changed", and the returned ids are exactly the set the
    /// sync layer should re-emit to the UI.
    pub fn cache_upsert(
        &self,
        kind: CacheKind,
        rows: &[CacheWrite],
        updated_at: i64,
    ) -> Result<Vec<String>> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut changed = Vec::new();
        {
            let table = kind.table();
            let mut select = tx.prepare(&format!("SELECT data FROM {table} WHERE id = ?1"))?;
            let mut upsert = tx.prepare(&format!(
                "INSERT INTO {table} (id, data, sort_key, updated_at) VALUES (?1, ?2, ?3, ?4) \
                 ON CONFLICT(id) DO UPDATE SET data = excluded.data, \
                     sort_key = excluded.sort_key, updated_at = excluded.updated_at"
            ))?;
            for row in rows {
                let existing: Option<String> = match select.query_row(params![row.id], |r| r.get(0))
                {
                    Ok(v) => Some(v),
                    Err(rusqlite::Error::QueryReturnedNoRows) => None,
                    Err(e) => return Err(e.into()),
                };
                if existing.as_deref() == Some(row.data.as_str()) {
                    continue;
                }
                upsert.execute(params![row.id, row.data, row.sort_key, updated_at])?;
                changed.push(row.id.clone());
            }
        }
        tx.commit()?;
        Ok(changed)
    }

    /// First `limit` cached JSON rows in display order (`sort_key` ascending,
    /// id as tiebreaker for stability). This is the warm-launch read path —
    /// the `sort_key` index makes it an index walk that touches only `limit`
    /// rows, never a full-table JSON parse.
    pub fn cache_list(&self, kind: CacheKind, limit: u32) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!(
            "SELECT data FROM {} ORDER BY sort_key ASC, id ASC LIMIT ?1",
            kind.table()
        ))?;
        let rows = stmt
            .query_map(params![limit], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Number of rows in the given cache table. Drives the removal check in
    /// the delta-sync path: `cached != server total` ⇒ something was deleted
    /// server-side and a full reconcile walk is needed.
    pub fn cache_count(&self, kind: CacheKind) -> Result<u32> {
        let conn = self.conn.lock();
        let count: i64 =
            conn.query_row(&format!("SELECT COUNT(*) FROM {}", kind.table()), [], |r| {
                r.get(0)
            })?;
        Ok(count.max(0) as u32)
    }

    /// Every id currently in the given cache table. Used by the full
    /// reconcile walk to compute the removed set (cached ids minus ids seen
    /// on the server).
    pub fn cache_ids(&self, kind: CacheKind) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!("SELECT id FROM {}", kind.table()))?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Delete the given ids from the cache table in one transaction. No-op
    /// for ids that are already gone.
    pub fn cache_delete_ids(&self, kind: CacheKind, ids: &[String]) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare(&format!("DELETE FROM {} WHERE id = ?1", kind.table()))?;
            for id in ids {
                stmt.execute(params![id])?;
            }
        }
        tx.commit()?;
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

    /// Delete every row of the `downloads` table, returning the `local_path`s
    /// that were recorded so the caller can unlink the files on disk. See
    /// [`crate::downloads::clear_all`] — file IO stays out of the storage
    /// layer by contract.
    pub fn downloads_clear(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT local_path FROM downloads WHERE local_path IS NOT NULL")?;
        let paths = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        conn.execute("DELETE FROM downloads", [])?;
        Ok(paths)
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

/// Which of the three library cache tables a cache operation targets (#431).
/// The enum (rather than a raw table-name string) keeps the SQL `format!`
/// calls in the cache CRUD closed over a fixed set of identifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CacheKind {
    Album,
    Artist,
    Track,
}

impl CacheKind {
    fn table(self) -> &'static str {
        match self {
            CacheKind::Album => "album_cache",
            CacheKind::Artist => "artist_cache",
            CacheKind::Track => "track_cache",
        }
    }
}

/// One library-cache row to write: the item id, its serialized model JSON,
/// and the precomputed display-order key. Produced by
/// `crate::library_cache`'s serializers and consumed by
/// [`Database::cache_upsert`].
#[derive(Clone, Debug)]
pub struct CacheWrite {
    pub id: String,
    pub data: String,
    pub sort_key: String,
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

/// Which backing store [`CredentialStore`] routes secrets through.
///
/// `Native` is the production path: the OS credential store via the `keyring`
/// crate (macOS Keychain / Windows Credential Manager). `Memory` is a
/// process-local map for development and live-e2e runs, where each freshly
/// compiled (and therefore unsigned) test binary would otherwise trip the
/// macOS Keychain ACL prompt when persisting the session token. The memory
/// arm makes zero Security-framework calls — it never constructs a
/// `keyring::Entry`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CredentialBackend {
    Native,
    Memory,
}

/// Map the raw `LYREBIRD_CREDENTIAL_STORE` value to a backend.
///
/// Pure (no environment read) so the decision matrix is unit-testable without
/// process-global env mutation. Exactly `Some("memory")` selects the
/// in-memory store; absent, empty, or any other spelling (including case
/// variants) selects the native keyring.
pub(crate) fn resolve_backend(env_value: Option<&str>) -> CredentialBackend {
    match env_value {
        Some("memory") => CredentialBackend::Memory,
        _ => CredentialBackend::Native,
    }
}

/// The backend every [`CredentialStore`] call routes through.
///
/// Debug builds (excluding the unit-test harness — see below) read
/// `LYREBIRD_CREDENTIAL_STORE` exactly once and cache the decision for the
/// life of the process. Release builds never read the environment at all: the
/// `cfg` structure compiles this function down to a constant
/// [`CredentialBackend::Native`], so production keychain behavior cannot be
/// downgraded via the environment.
///
/// The unit-test harness (`cfg(test)`) is likewise pinned to `Native` so the
/// suite always exercises the `keyring` code path through the process-wide
/// mock builder its fixtures install (`install_mock_keyring`), regardless of
/// what a developer's shell happens to export. The live e2e integration
/// target (`core/tests/e2e_live.rs`) links the library *without* `cfg(test)`,
/// so it honors the variable — that is the path `Scripts/smoke-test.sh`
/// relies on.
pub(crate) fn credential_backend() -> CredentialBackend {
    #[cfg(all(debug_assertions, not(test)))]
    {
        static BACKEND: OnceLock<CredentialBackend> = OnceLock::new();
        *BACKEND.get_or_init(|| {
            resolve_backend(std::env::var("LYREBIRD_CREDENTIAL_STORE").ok().as_deref())
        })
    }
    #[cfg(not(all(debug_assertions, not(test))))]
    {
        // Release and unit-test builds: constant `Native`, environment never
        // consulted.
        resolve_backend(None)
    }
}

/// Process-local secret map backing [`CredentialBackend::Memory`], keyed on
/// the keyring account string (the service is the fixed `SERVICE` constant).
/// Never persisted — secrets vanish with the process.
fn memory_store() -> &'static Mutex<HashMap<String, String>> {
    static STORE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub struct CredentialStore;

impl CredentialStore {
    pub fn save_token(server_id: &str, username: &str, token: &str) -> Result<()> {
        Self::save_secret(
            credential_backend(),
            &format!("{server_id}/{username}"),
            token,
        )
    }

    pub fn load_token(server_id: &str, username: &str) -> Result<Option<String>> {
        Self::load_secret(credential_backend(), &format!("{server_id}/{username}"))
    }

    pub fn delete_token(server_id: &str, username: &str) -> Result<()> {
        Self::delete_secret(credential_backend(), &format!("{server_id}/{username}"))
    }

    /// Persist the ListenBrainz scrobble token in the OS keyring (same secure
    /// store as the Jellyfin access token), keyed on `SCROBBLE_ACCOUNT`.
    pub fn save_scrobble_token(token: &str) -> Result<()> {
        Self::save_secret(credential_backend(), SCROBBLE_ACCOUNT, token)
    }

    /// Read the stored ListenBrainz scrobble token, or `None` when none is
    /// stored. Discriminates a missing entry from a real keyring fault.
    pub fn load_scrobble_token() -> Result<Option<String>> {
        Self::load_secret(credential_backend(), SCROBBLE_ACCOUNT)
    }

    /// Remove the stored ListenBrainz scrobble token. A no-op when absent.
    pub fn delete_scrobble_token() -> Result<()> {
        Self::delete_secret(credential_backend(), SCROBBLE_ACCOUNT)
    }

    // Backend-explicit primitives. The public API above always passes
    // `credential_backend()`; unit tests drive the `Memory` arm directly so
    // the in-memory semantics stay covered even though the test harness pins
    // the resolver to `Native` (see `credential_backend`).

    pub(crate) fn save_secret(
        backend: CredentialBackend,
        account: &str,
        secret: &str,
    ) -> Result<()> {
        match backend {
            CredentialBackend::Memory => {
                memory_store()
                    .lock()
                    .insert(account.to_owned(), secret.to_owned());
                Ok(())
            }
            CredentialBackend::Native => {
                let entry = keyring::Entry::new(SERVICE, account)?;
                entry.set_password(secret)?;
                Ok(())
            }
        }
    }

    pub(crate) fn load_secret(backend: CredentialBackend, account: &str) -> Result<Option<String>> {
        match backend {
            CredentialBackend::Memory => Ok(memory_store().lock().get(account).cloned()),
            CredentialBackend::Native => {
                let entry = keyring::Entry::new(SERVICE, account)?;
                match entry.get_password() {
                    Ok(t) => Ok(Some(t)),
                    Err(keyring::Error::NoEntry) => Ok(None),
                    Err(e) => Err(e.into()),
                }
            }
        }
    }

    pub(crate) fn delete_secret(backend: CredentialBackend, account: &str) -> Result<()> {
        match backend {
            CredentialBackend::Memory => {
                memory_store().lock().remove(account);
                Ok(())
            }
            CredentialBackend::Native => {
                let entry = keyring::Entry::new(SERVICE, account)?;
                match entry.delete_credential() {
                    Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
                    Err(e) => Err(e.into()),
                }
            }
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
