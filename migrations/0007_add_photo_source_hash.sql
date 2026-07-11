ALTER TABLE photos
ADD COLUMN source_sha256 TEXT
  CHECK (
    source_sha256 IS NULL
    OR (
      length(source_sha256) = 64
      AND source_sha256 NOT GLOB '*[^0-9a-f]*'
    )
  );

CREATE UNIQUE INDEX photos_event_source_sha256_idx
  ON photos(event_id, source_sha256)
  WHERE source_sha256 IS NOT NULL;