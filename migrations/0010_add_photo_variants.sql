CREATE TABLE photo_variants (
  photo_id TEXT NOT NULL,

  source_kind TEXT NOT NULL
    CHECK (source_kind IN ('original', 'final')),

  variant_kind TEXT NOT NULL
    CHECK (variant_kind IN ('thumbnail', 'preview')),

  storage_key TEXT NOT NULL UNIQUE,

  content_type TEXT NOT NULL
    CHECK (content_type = 'image/jpeg'),

  byte_size INTEGER NOT NULL
    CHECK (byte_size > 0),

  width INTEGER NOT NULL
    CHECK (width > 0),

  height INTEGER NOT NULL
    CHECK (height > 0),

  created_at TEXT NOT NULL,

  PRIMARY KEY (
    photo_id,
    source_kind,
    variant_kind
  ),

  FOREIGN KEY (photo_id)
    REFERENCES photos(id)
    ON DELETE CASCADE
);

CREATE INDEX photo_variants_photo_id_idx
  ON photo_variants(photo_id);