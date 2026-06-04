CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS servers (
    id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    name TEXT NOT NULL,
    last_used_at INTEGER
);

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    name TEXT NOT NULL,
    primary_image_tag TEXT,
    FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE CASCADE
);

-- NOTE: a `play_history` table lived here in earlier builds. It was removed
-- in the audit pass: the server is the authority on play counts (incremented
-- via /Sessions/Playing*), so local play history was write-only dead storage
-- that grew unbounded and ran a synchronous INSERT on the main-thread track
-- load path. Existing installs may still carry an (empty) orphan table; that
-- is harmless and intentionally not migrated away.

CREATE TABLE IF NOT EXISTS track_cache (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS album_cache (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS artist_cache (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
