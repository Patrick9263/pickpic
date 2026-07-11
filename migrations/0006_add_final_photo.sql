ALTER TABLE photos
ADD COLUMN final_storage_key TEXT;

ALTER TABLE photos
ADD COLUMN final_original_filename TEXT
  CHECK (
    final_original_filename IS NULL
    OR length(trim(final_original_filename)) BETWEEN 1 AND 255
  );

ALTER TABLE photos
ADD COLUMN final_content_type TEXT
  CHECK (
    final_content_type IS NULL
    OR final_content_type = 'image/jpeg'
  );

ALTER TABLE photos
ADD COLUMN final_byte_size INTEGER
  CHECK (
    final_byte_size IS NULL
    OR final_byte_size > 0
  );

ALTER TABLE photos
ADD COLUMN final_uploaded_at TEXT;

CREATE UNIQUE INDEX photos_final_storage_key_idx
  ON photos(final_storage_key)
  WHERE final_storage_key IS NOT NULL;