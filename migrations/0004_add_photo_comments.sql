CREATE TABLE comments (
  id TEXT PRIMARY KEY,

  photo_id TEXT NOT NULL,
  visitor_id TEXT NOT NULL,

  body TEXT NOT NULL
    CHECK (length(trim(body)) BETWEEN 1 AND 1000),

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  resolved_at TEXT,

  FOREIGN KEY (photo_id)
    REFERENCES photos(id)
    ON DELETE CASCADE,

  FOREIGN KEY (visitor_id)
    REFERENCES gallery_visitors(id)
    ON DELETE CASCADE
);

CREATE INDEX comments_photo_id_created_at_idx
  ON comments(photo_id, created_at ASC);

CREATE INDEX comments_visitor_id_idx
  ON comments(visitor_id);