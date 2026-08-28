-- Migration number: 0015 	 2026-08-28T00:00:00.000Z
--
-- Real user authentication, step 1: the two tables a login needs.
--
-- This file only creates new tables and indexes. It alters nothing that exists,
-- so unlike 0013/0014 it needs no trigger gymnastics and cannot lose a row --
-- see 0012 for why a table rebuild inside D1 is the thing being avoided.
--
-- No new table is added for identities. account_users from 0013 already has the
-- right shape: its unique index on (auth_provider, auth_subject) is exactly the
-- key both providers need -- ('email', <normalised address>) for a magic link,
-- ('apple', <Apple sub>) for Sign in with Apple. The subject rather than the
-- email is the key on purpose, because an Apple private-relay address rotates
-- while the sub does not.
--
-- Both foreign keys are ON DELETE RESTRICT, never CASCADE, following the rule
-- 0013 set: a cascade edge pointing at accounts or account_users would make any
-- future rebuild of those tables destructive. The cost is that deleting an
-- account_user has to clear its tokens and sessions in application code first,
-- which is the correct trade -- a refused delete is recoverable, a silent one is
-- not.
--
-- Neither table stores a token. Both store the SHA-256 of one, so a database
-- dump cannot be replayed as a login.

-- ---------------------------------------------------------------------------
-- Magic-link tokens
-- ---------------------------------------------------------------------------
--
-- Short-lived and single-use. A row is created only for an address that already
-- resolves to an account_user; an unknown address produces no row and no email,
-- which is what keeps the request endpoint from confirming whether an account
-- exists.

CREATE TABLE auth_login_tokens (
  id TEXT PRIMARY KEY,

  account_user_id TEXT NOT NULL
    REFERENCES account_users(id) ON DELETE RESTRICT,

  -- Hex SHA-256 of the token that was emailed. The token itself exists only in
  -- the recipient's inbox.
  token_hash TEXT NOT NULL,

  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,

  -- Set the moment the token is redeemed, which is what makes it single-use.
  consumed_at TEXT
);

-- UNIQUE because lookup is by hash and a collision would be an authentication
-- bug rather than a duplicate row.
CREATE UNIQUE INDEX auth_login_tokens_token_hash_idx
  ON auth_login_tokens(token_hash);

-- Drives the per-user rate limit on how many live tokens may exist at once.
CREATE INDEX auth_login_tokens_account_user_id_created_at_idx
  ON auth_login_tokens(account_user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------
--
-- One row per signed-in browser. The account is reached by joining
-- account_users rather than being copied here: a denormalised owner column that
-- can drift from its parent is the bug generator 0014's photos trigger exists to
-- prevent, and unlike photos there is no query here that would benefit from the
-- copy.

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,

  account_user_id TEXT NOT NULL
    REFERENCES account_users(id) ON DELETE RESTRICT,

  -- Hex SHA-256 of the cookie value.
  token_hash TEXT NOT NULL,

  created_at TEXT NOT NULL,

  -- Absolute, not sliding. A session dies thirty days after it was created
  -- however active it has been, so a stolen cookie has a bounded life.
  expires_at TEXT NOT NULL,

  -- Refreshed at most once an hour and off the request path, so that listing
  -- sessions in account settings later can show something useful without
  -- costing a write per request.
  last_used_at TEXT NOT NULL,

  -- Set by sign-out. Revoking rather than deleting keeps the row available for
  -- that same settings screen.
  revoked_at TEXT,

  -- Truncated User-Agent, purely so a human can recognise their own devices.
  user_agent TEXT
);

CREATE UNIQUE INDEX auth_sessions_token_hash_idx
  ON auth_sessions(token_hash);

CREATE INDEX auth_sessions_account_user_id_idx
  ON auth_sessions(account_user_id);
