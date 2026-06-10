-- Library cache sort keys (#431).
--
-- The v1 cache tables store opaque JSON in `data`, which leaves SQLite unable
-- to ORDER BY the item name without parsing JSON per row. The cache-first
-- launch path wants "first N rows in display order" in single-digit
-- milliseconds, so we add a precomputed `sort_key` column (article-stripped,
-- casefolded name — see `library_cache::sort_key`) plus an index over it.
--
-- Safe on existing installs: the three tables have been empty since their
-- introduction (nothing wrote to them before #431), so no backfill is needed;
-- the DEFAULT '' only ever applies to pre-existing rows, of which there are
-- none in practice.
ALTER TABLE track_cache ADD COLUMN sort_key TEXT NOT NULL DEFAULT '';
ALTER TABLE album_cache ADD COLUMN sort_key TEXT NOT NULL DEFAULT '';
ALTER TABLE artist_cache ADD COLUMN sort_key TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_track_cache_sort ON track_cache(sort_key);
CREATE INDEX IF NOT EXISTS idx_album_cache_sort ON album_cache(sort_key);
CREATE INDEX IF NOT EXISTS idx_artist_cache_sort ON artist_cache(sort_key);
