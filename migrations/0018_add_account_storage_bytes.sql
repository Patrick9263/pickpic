-- Migration number: 0018 	 2026-09-03T00:00:00.000Z
--
-- Roadmap step 8b: docs/pricing.md's "what has to be built first" list names
-- a SUM(byte_size) per upload as too expensive on D1 to run on every write,
-- so enforcement needs a maintained running counter rather than the live
-- query 0017/getStorageUsage already has. This is that counter -- storage_bytes
-- is incremented on upload and decremented on delete, and periodically
-- reconciled against the true sum (getStorageUsage now does this on every
-- read) so drift from a missed decrement self-heals rather than compounding.
--
-- Backfilled from today's true totals across photos, final images, and
-- variants, matching exactly what getStorageUsage already sums.
ALTER TABLE accounts
ADD COLUMN storage_bytes INTEGER NOT NULL DEFAULT 0
  CHECK (storage_bytes >= 0);

UPDATE accounts
SET storage_bytes = (
  SELECT
    COALESCE(SUM(p.byte_size), 0)
    + COALESCE(SUM(p.final_byte_size), 0)
    + COALESCE((
      SELECT SUM(v.byte_size)
      FROM photo_variants v
      INNER JOIN photos vp ON vp.id = v.photo_id
      WHERE vp.account_id = accounts.id
    ), 0)
  FROM photos p
  WHERE p.account_id = accounts.id
);
