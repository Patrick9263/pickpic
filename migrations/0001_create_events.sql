-- Migration number: 0001 	 2026-07-10T04:33:08.197Z
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL
    CHECK (length(trim(title)) BETWEEN 1 AND 120),

  share_token TEXT NOT NULL UNIQUE,

  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (
      status IN (
        'draft',
        'uploading',
        'ready',
        'editing',
        'completed',
        'archived'
      )
    ),

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX events_created_at_idx
  ON events(created_at DESC);
