ALTER TABLE photos
ADD COLUMN final_sha256 TEXT
  CHECK (
    final_sha256 IS NULL
    OR (
      length(final_sha256) = 64
      AND final_sha256 NOT GLOB '*[^0-9a-f]*'
    )
  );

CREATE INDEX photos_event_final_sha256_idx
  ON photos(event_id, final_sha256)
  WHERE final_sha256 IS NOT NULL;