CREATE TABLE gallery_visitors (
  id TEXT PRIMARY KEY,

  event_id TEXT NOT NULL,

  visitor_token TEXT NOT NULL
    CHECK (length(visitor_token) BETWEEN 20 AND 100),

  display_name TEXT NOT NULL
    CHECK (length(trim(display_name)) BETWEEN 1 AND 80),

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,

  UNIQUE (event_id, visitor_token),

  FOREIGN KEY (event_id)
    REFERENCES events(id)
    ON DELETE CASCADE
);

CREATE INDEX gallery_visitors_event_id_idx
  ON gallery_visitors(event_id);

CREATE TABLE hearts (
  photo_id TEXT NOT NULL,
  visitor_id TEXT NOT NULL,
  created_at TEXT NOT NULL,

  PRIMARY KEY (photo_id, visitor_id),

  FOREIGN KEY (photo_id)
    REFERENCES photos(id)
    ON DELETE CASCADE,

  FOREIGN KEY (visitor_id)
    REFERENCES gallery_visitors(id)
    ON DELETE CASCADE
);

CREATE INDEX hearts_visitor_id_idx
  ON hearts(visitor_id);