-- Migration number: 0002 	 2026-07-10T04:56:59.681Z
CREATE TABLE photos (
  id TEXT PRIMARY KEY,

  event_id TEXT NOT NULL,

  original_filename TEXT NOT NULL
    CHECK (
      length(trim(original_filename)) BETWEEN 1 AND 255
    ),

  storage_key TEXT NOT NULL UNIQUE,

  content_type TEXT NOT NULL
    CHECK (content_type = 'image/jpeg'),

  byte_size INTEGER NOT NULL
    CHECK (byte_size > 0),

  created_at TEXT NOT NULL,

  FOREIGN KEY (event_id)
    REFERENCES events(id)
    ON DELETE CASCADE
);

CREATE INDEX photos_event_id_created_at_idx
  ON photos(event_id, created_at DESC);