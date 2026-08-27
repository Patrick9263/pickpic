-- Migration number: 0013 	 2026-08-27T00:00:00.000Z
--
-- Multi-tenancy, step 1 of 2: give every row an owner without rebuilding a
-- table.
--
-- Following the rule 0012 established: SQLite cannot alter a CHECK constraint
-- or add a NOT NULL column in place, and a table rebuild inside D1 fires every
-- ON DELETE CASCADE (PRAGMA foreign_keys is a no-op inside the implicit
-- migration transaction; defer_foreign_keys and legacy_alter_table rebuilds
-- were both tested and both destroyed every child row). This file therefore
-- contains only CREATE TABLE, ALTER TABLE ADD COLUMN, INSERT, UPDATE and
-- CREATE INDEX. It drops nothing and rebuilds nothing, so it cannot lose a row.
--
-- Three consequences of that rule shape the schema below:
--
--   * The new ownership columns are nullable. NOT NULL is enforced by BEFORE
--     INSERT / BEFORE UPDATE triggers in 0014 instead. That is exactly as
--     strong for anything the application writes, and unlike a real NOT NULL it
--     can be changed later without touching a row.
--
--   * The new enum-ish columns (accounts.status, account_users.role,
--     account_users.auth_provider) carry NO CHECK constraint. Widening a CHECK
--     is a rebuild in SQLite just as much as tightening one, and these are
--     precisely the values that will need widening: a second identity provider,
--     a 'viewer' role, a 'past_due' status. Where those need enforcement it
--     goes in a trigger, because a trigger can be dropped and recreated for
--     free. (event_notifications.status from 0011 is the cautionary example --
--     its CHECK cannot gain a 'bounced' state without a rebuild.)
--
--   * This migration deliberately stops short of the triggers so that the
--     worker currently in production keeps working after it is applied. The
--     triggers land in 0014, after the new worker is deployed.

-- ---------------------------------------------------------------------------
-- Tenancy tables
-- ---------------------------------------------------------------------------

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,

  name TEXT NOT NULL
    CHECK (length(trim(name)) BETWEEN 1 AND 120),

  status TEXT NOT NULL DEFAULT 'active',

  -- NULL means "this account's rows live in the primary D1 database".
  --
  -- D1 caps a database at 10 GB, which at roughly 2 KB of metadata per photo
  -- is a few hundred photographers. A future shard split sets this to a
  -- wrangler d1_databases binding name; resolveAccountDatabase() in
  -- worker/accounts.ts is the only reader, so moving an account becomes a data
  -- move plus one row update rather than a rewrite of every query site.
  database_id TEXT,

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Maps an external auth subject to an account. Deliberately left empty by this
-- migration: the only subjects that exist today are the Cloudflare Access SSO
-- identity and the iPad's service token, neither of whose identifiers belong in
-- this repository. The worker resolves the bootstrap account directly for now;
-- the table exists so the shape is settled and adopting real user auth is a
-- query change rather than a migration.
CREATE TABLE account_users (
  id TEXT PRIMARY KEY,

  account_id TEXT NOT NULL
    REFERENCES accounts(id) ON DELETE RESTRICT,

  -- 'cloudflare_access' for an SSO identity,
  -- 'cloudflare_access_service_token' for a machine identity.
  auth_provider TEXT NOT NULL,

  -- The Access JWT 'sub' for an SSO identity, or 'common_name' (the service
  -- token's client id) for a service token. Those two namespaces cannot
  -- collide because auth_provider distinguishes them.
  auth_subject TEXT NOT NULL,

  email TEXT,

  role TEXT NOT NULL DEFAULT 'owner',

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX account_users_provider_subject_idx
  ON account_users(auth_provider, auth_subject);

CREATE INDEX account_users_account_id_idx
  ON account_users(account_id);

-- ---------------------------------------------------------------------------
-- The bootstrap account
-- ---------------------------------------------------------------------------
--
-- A fixed UUID rather than a generated one so that worker/accounts.ts can name
-- it as a constant and so that this row is unmistakable in a table dump. The
-- format matches every other id in the database, so nothing has to special-case
-- it. strftime here produces exactly the format the worker writes via
-- new Date().toISOString().
INSERT INTO accounts (
  id,
  name,
  status,
  database_id,
  created_at,
  updated_at
)
VALUES (
  '00000000-0000-4000-8000-000000000001',
  'PickPic',
  'active',
  NULL,
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

-- ---------------------------------------------------------------------------
-- Ownership columns
-- ---------------------------------------------------------------------------
--
-- ON DELETE RESTRICT, never CASCADE. A new cascade edge pointing at accounts
-- would be exactly the landmine 0012 documents: it would make any future
-- rebuild of accounts destructive. RESTRICT refuses the delete instead, which
-- is also the correct semantic -- an account is never silently deletable.
--
-- SQLite permits a REFERENCES clause on ADD COLUMN when the default is NULL,
-- which is the case here.
--
-- photos.account_id is denormalised rather than reached through events on
-- purpose. Five admin handlers (deletePhoto, clearPhotoHearts,
-- setPhotoWorkflowStatus, uploadFinalPhoto, uploadPhotoVariants) and all three
-- image routes take a bare photo id, and this column turns their tenancy check
-- into an extra WHERE rather than a rewritten query. 0014 adds a trigger that
-- makes drift from the parent event impossible.
ALTER TABLE events
ADD COLUMN account_id TEXT
  REFERENCES accounts(id) ON DELETE RESTRICT;

ALTER TABLE photos
ADD COLUMN account_id TEXT
  REFERENCES accounts(id) ON DELETE RESTRICT;

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------

UPDATE events
SET account_id = '00000000-0000-4000-8000-000000000001'
WHERE account_id IS NULL;

-- Derived from the parent rather than assumed, so this statement stays correct
-- if it is ever re-run when more than one account exists.
UPDATE photos
SET account_id = (
  SELECT e.account_id
  FROM events e
  WHERE e.id = photos.event_id
)
WHERE account_id IS NULL;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
--
-- Leading with account_id so the scoped event listing and the scoped storage
-- rollup are both index-driven.
--
-- photos_event_source_sha256_idx (0007) is untouched and stays correct: event
-- ids are globally unique, so duplicate detection does not need account_id in
-- the key.
CREATE INDEX events_account_id_created_at_idx
  ON events(account_id, created_at DESC);

CREATE INDEX photos_account_id_event_id_idx
  ON photos(account_id, event_id);
