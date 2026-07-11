ALTER TABLE photos
ADD COLUMN captured_at TEXT
  CHECK (
    captured_at IS NULL
    OR length(captured_at) = 19
  );

ALTER TABLE photos
ADD COLUMN latitude REAL
  CHECK (
    latitude IS NULL
    OR latitude BETWEEN -90 AND 90
  );

ALTER TABLE photos
ADD COLUMN longitude REAL
  CHECK (
    longitude IS NULL
    OR longitude BETWEEN -180 AND 180
  );

CREATE INDEX photos_event_captured_at_idx
  ON photos(event_id, captured_at);