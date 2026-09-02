-- Migration number: 0017 	 2026-09-02T00:00:00.000Z
--
-- Roadmap step 8a: the dashboard storage panel needs a plan name and a byte
-- cap to compare its live GET /api/admin/storage total against. Neither
-- existed before this -- accounts carried no notion of a plan at all.
--
-- Two columns, not one. storage_cap_bytes is what the display meter (and
-- later, enforcement) actually reads; plan is only a label. Per
-- docs/pricing.md's own build list, entitlements belong on per-account
-- columns rather than constants specifically so a single account's cap can
-- be raised without a deployment (e.g. a beta tester) -- storing only a plan
-- name and deriving the cap from it in code would foreclose that.
--
-- plan carries no CHECK, matching the reasoning 0013 already gives for
-- accounts.status: pricing tiers are exactly the kind of value that widens
-- (today's free/solo/studio set is not guaranteed to be next year's), and a
-- CHECK here would make adding a tier a table rebuild -- see 0012 for what a
-- rebuild costs this schema.
--
-- Both columns get a DEFAULT so this is the cheap ADD COLUMN case, not a
-- rebuild.
ALTER TABLE accounts
ADD COLUMN plan TEXT NOT NULL DEFAULT 'free';

ALTER TABLE accounts
ADD COLUMN storage_cap_bytes INTEGER NOT NULL DEFAULT 2000000000
  CHECK (storage_cap_bytes > 0);

-- The bootstrap account (BOOTSTRAP_ACCOUNT_ID in worker/accounts.ts) is
-- Patrick's own production account, not a customer sitting on the free tier
-- -- give it the top tier's cap so the panel doesn't tell its own owner to
-- upgrade.
UPDATE accounts
SET plan = 'studio', storage_cap_bytes = 1000000000000
WHERE id = '00000000-0000-4000-8000-000000000001';
