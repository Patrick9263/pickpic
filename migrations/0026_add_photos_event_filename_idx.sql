-- Migration number: 0026 	 2026-09-22T00:00:00.000Z
--
-- #328: preflightPhotos queries `WHERE event_id = ? AND original_filename IN
-- (...)`, but the only existing index on photos is
-- photos_event_id_created_at_idx (event_id, created_at). Without a covering
-- index, SQLite walks that index for the whole event and fetches every row
-- to compare original_filename -- on the hot path of every shoot, this is
-- roughly 25,000 D1 rows read per 1500-frame preflight (17 chunks x ~1500
-- rows), growing quadratically as the event fills.
--
-- This index turns each chunk into ~90 seeks instead of a full event scan.

CREATE INDEX photos_event_filename_idx ON photos(event_id, original_filename);
