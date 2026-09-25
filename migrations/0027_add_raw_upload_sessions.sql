-- Migration number: 0027 	 2026-09-25T00:00:00.000Z
--
-- #367 (design: #362): server-side state for resumable RAW multipart
-- uploads.
--
-- The Workers R2 binding cannot list a multipart upload's parts -- there is
-- no equivalent of S3's ListParts -- so the etags an eventual complete()
-- needs have to be tracked here. One active upload per photo (photo_id
-- UNIQUE) on purpose: two overlapping uploads racing the same photo_id is
-- exactly the bug #362 found in the original single-PUT path, and the new
-- path refuses to repeat it.
--
-- completing_at is an atomic completion claim. The request whose landed
-- part leaves none missing does
--   UPDATE raw_upload_sessions SET completing_at = ? WHERE id = ? AND completing_at IS NULL
-- and only calls R2's complete() if that changed a row, so two parts
-- landing together still finish the upload exactly once.
--
-- ON DELETE CASCADE from photos, so deleting a photo takes its in-progress
-- upload state with it. That only cleans up D1 -- the R2 side has no
-- cascade, so worker/index.ts aborts the R2 multipart upload itself before
-- a photo or event delete removes the row it needs to do that.
--
-- account_id is denormalised the same way photos.account_id is (0013):
-- ON DELETE RESTRICT, never CASCADE (see 0013's comment on why), and every
-- query against this table goes through AccountScope.prepare()'s
-- :accountId marker.

CREATE TABLE raw_upload_sessions (
  id TEXT PRIMARY KEY,

  photo_id TEXT NOT NULL UNIQUE
    REFERENCES photos(id) ON DELETE CASCADE,

  account_id TEXT NOT NULL
    REFERENCES accounts(id) ON DELETE RESTRICT,

  original_filename TEXT NOT NULL
    CHECK (length(trim(original_filename)) BETWEEN 1 AND 255),

  sha256 TEXT NOT NULL,

  byte_size INTEGER NOT NULL
    CHECK (byte_size > 0),

  part_size INTEGER NOT NULL
    CHECK (part_size > 0),

  r2_upload_id TEXT NOT NULL,

  storage_key TEXT NOT NULL,

  created_at TEXT NOT NULL,

  -- NULL until the last part lands and a request claims completion. See the
  -- header comment above for the exactly-once protocol this implements.
  completing_at TEXT
);

CREATE INDEX raw_upload_sessions_account_id_idx
  ON raw_upload_sessions(account_id);

-- No account_id column: every access goes through a session row already
-- looked up by (photo_id, account_id) above -- the same pattern
-- photo_variants uses against an already-verified photo id (see
-- deletePhoto in worker/index.ts).
CREATE TABLE raw_upload_parts (
  session_id TEXT NOT NULL
    REFERENCES raw_upload_sessions(id) ON DELETE CASCADE,

  part_number INTEGER NOT NULL
    CHECK (part_number > 0),

  etag TEXT NOT NULL,

  PRIMARY KEY (session_id, part_number)
);
