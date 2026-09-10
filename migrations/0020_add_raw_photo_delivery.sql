-- Migration number: 0020 	 2026-09-09T12:00:00.000Z
--
-- Storage for the RAW file the iPad delivers once a gallery viewer has
-- requested it (issue #205). Migration 0019 recorded the request; this
-- records what was uploaded to satisfy it.

-- The delivered RAW is per *photo*, not per request: one photo has exactly one
-- original, and every visitor who asks for it is served the same object. So
-- these mirror the final_* columns (migration 0006) rather than hanging off
-- raw_requests, which keeps deletion, storage accounting and the eventual
-- download all working from the same one-key-per-photo shape.
--
-- raw_content_type is stored even though it is always application/octet-stream
-- today, for the same reason final_content_type is: the column is what a
-- download response reads, and guessing it at read time is how the wrong
-- header gets sent once a second RAW format appears.
ALTER TABLE photos ADD COLUMN raw_storage_key TEXT;
ALTER TABLE photos ADD COLUMN raw_original_filename TEXT;
ALTER TABLE photos ADD COLUMN raw_content_type TEXT;
ALTER TABLE photos ADD COLUMN raw_byte_size INTEGER;
ALTER TABLE photos ADD COLUMN raw_sha256 TEXT;
ALTER TABLE photos ADD COLUMN raw_uploaded_at TEXT;

-- Set on every pending request for a photo the moment its RAW lands. Two
-- consumers depend on it: the iPad counts unfulfilled requests to decide what
-- still needs uploading, and the delete-after-download reclaim (#209) needs a
-- point in time to reclaim from. Nullable rather than defaulted, because
-- "never fulfilled" and "fulfilled at some unknown time" are different states.
ALTER TABLE raw_requests ADD COLUMN fulfilled_at TEXT;

-- The iPad polls listPhotos for every photo in an event on each activation
-- sweep, and each row runs the pending-request count as a correlated
-- subquery. Partial, because the count only ever asks for unfulfilled rows and
-- a fulfilled request is dead weight in the index forever after.
CREATE INDEX raw_requests_pending_idx
  ON raw_requests(photo_id)
  WHERE fulfilled_at IS NULL;
