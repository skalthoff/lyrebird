-- Offline downloads (#819).
--
-- One row per track the user has asked to keep available offline. The audio
-- bytes themselves live on disk under the configurable downloads directory
-- (see `downloads.rs`); this table is the index the UI and the offline-playback
-- path consult. `track_json` snapshots the full `Track` record at enqueue time
-- so the Downloads screen can render rows (title / artist / artwork tag) and
-- offline playback can reconstruct a queue without a live server.
--
-- `state` is the lifecycle marker: 'queued' | 'downloading' | 'done' |
-- 'failed'. Only a 'done' row with a present `local_path` + non-zero
-- `size_bytes` counts toward the storage budget and is eligible for offline
-- playback. `created_at` / `completed_at` are Unix seconds; `completed_at` is
-- NULL until the download finishes (used as the LRU key for budget eviction —
-- oldest completed download evicts first).
CREATE TABLE IF NOT EXISTS downloads (
    track_id TEXT PRIMARY KEY,
    track_json TEXT NOT NULL,
    local_path TEXT,
    container TEXT,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'queued',
    error TEXT,
    created_at INTEGER NOT NULL,
    completed_at INTEGER
);

-- Budget eviction scans completed rows oldest-first; index the LRU key so that
-- scan stays cheap as the offline library grows.
CREATE INDEX IF NOT EXISTS idx_downloads_completed_at
    ON downloads (completed_at)
    WHERE state = 'done';
