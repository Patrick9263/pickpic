-- Migration number: 0024 	 2026-09-15T00:00:00.000Z
--
-- #225: how long an uncollected, delivered RAW is kept before reclaim was a
-- fixed 14-day constant (RAW_DELIVERY_TTL_MS) for every account. Retention
-- trades directly against the storage cap, and the cap is per account, so the
-- knob belongs here rather than in code -- same reasoning 0017 already gives
-- for storage_cap_bytes.
--
-- The default is 7 days, not a straight port of the old 14-day constant --
-- product decision, made when this migration was written. Applying this to a
-- database with existing accounts is itself the same retroactive shortening
-- the photographer-facing setting can do: eligibility is evaluated against
-- fulfilled_at at sweep time, so any RAW already delivered 7-14 days ago
-- becomes immediately eligible for reclaim on the account's next iPad sync.
--
-- Bounds: the minimum must stay strictly above RAW_DOWNLOAD_GRACE_MS (1 day,
-- worker/index.ts), or a TTL shorter than the grace period would always win
-- and the grace period would stop existing -- 2 days leaves a full day of
-- margin. The maximum (90 days) keeps the storage-cap argument the setting
-- rests on from being defeated by an effectively-unbounded value.
ALTER TABLE accounts
ADD COLUMN raw_delivery_ttl_ms INTEGER NOT NULL DEFAULT 604800000
  CHECK (raw_delivery_ttl_ms BETWEEN 172800000 AND 7776000000);
