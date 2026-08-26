-- Migration number: 0012 	 2026-08-26T00:00:00.000Z
--
-- The 'uploading' and 'editing' event statuses were never written by any
-- code path (worker's isGalleryStatus guard already rejected them), so this
-- only tightens the CHECK constraint to match reality. SQLite can't alter a
-- CHECK constraint in place, so the table is recreated.
PRAGMA foreign_keys=OFF;

CREATE TABLE events_new (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL
    CHECK (length(trim(title)) BETWEEN 1 AND 120),

  share_token TEXT NOT NULL UNIQUE,

  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (
      status IN (
        'draft',
        'ready',
        'completed',
        'archived'
      )
    ),

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT INTO events_new SELECT * FROM events;

DROP TABLE events;

ALTER TABLE events_new RENAME TO events;

CREATE INDEX events_created_at_idx
  ON events(created_at DESC);

PRAGMA foreign_keys=ON;
