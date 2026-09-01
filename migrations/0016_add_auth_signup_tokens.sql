-- Migration number: 0016 	 2026-09-01T00:00:00.000Z
--
-- Self-serve signup, step 1: the one table an unverified signup needs.
--
-- Creates-only, like 0015. It alters nothing that exists, so it cannot lose a
-- row -- see 0012 for the full account of why a table rebuild inside D1 is the
-- thing being avoided.
--
-- Why a second token table rather than reusing auth_login_tokens: that table's
-- account_user_id is NOT NULL REFERENCES account_users(id), and a signup token
-- by definition has no user to point at. Relaxing that column to nullable is
-- exactly the SQLite table rebuild this schema refuses to perform, and it would
-- weaken a constraint that is correct for every row auth_login_tokens will ever
-- hold.
--
-- Why no account exists until the link is clicked. account_users has a UNIQUE
-- index on (auth_provider, auth_subject), so a row written before the address
-- is proven would let anyone who can reach the form permanently claim somebody
-- else's email. Undoing that would mean a delete path through account_users and
-- accounts, both of which every foreign key reaches ON DELETE RESTRICT by the
-- rule 0013 set -- a destructive code path guarded by a flag. A row here is
-- disposable instead: nothing references it, so deleting one is free and
-- abandoning one costs a few hundred bytes until it expires.
--
-- Like 0015, no token is stored. Only the SHA-256 of one.

CREATE TABLE auth_signup_tokens (
  id TEXT PRIMARY KEY,

  -- The address the confirmation link was sent to, normalised the way
  -- normalizeEmail in worker/auth.ts normalises it: trimmed and lowercased. On
  -- consume this becomes both account_users.auth_subject and
  -- account_users.email.
  --
  -- Deliberately NOT unique. More than one live token per address is ordinary
  -- -- somebody submits the form twice because the first mail was slow -- and a
  -- unique index would turn that into an upsert. How many may be live at once
  -- is capped in application code, the same way MAX_LIVE_LOGIN_TOKENS caps
  -- sign-in links.
  email TEXT NOT NULL,

  -- The studio name the form collected, held until there is an accounts row to
  -- put it in.
  --
  -- 0013 argues against CHECK constraints, but that argument is about enum
  -- columns that will need widening. This is a length bound copied verbatim
  -- from accounts.name, the column this value is destined for; it cannot drift
  -- on its own, and it makes an over-long name a failure when it is typed
  -- rather than half an hour later when the link is clicked.
  account_name TEXT NOT NULL
    CHECK (length(trim(account_name)) BETWEEN 1 AND 120),

  -- Hex SHA-256 of the token that was emailed. The token itself exists only in
  -- the recipient's inbox.
  token_hash TEXT NOT NULL,

  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,

  -- Set the moment the token is redeemed, and set before the account is
  -- created, which is what stops two simultaneous clicks producing two
  -- accounts.
  consumed_at TEXT
);

-- The invite code that authorised the signup is deliberately not recorded, not
-- even as a hash. It is one shared secret rather than a per-recipient one, so
-- it identifies nobody; the row is deleted as soon as the account exists, so it
-- would never survive to be audited anyway; and a stored hash of a live secret
-- is a confirmation oracle for anyone holding a database dump. If which code
-- created which account ever matters, the honest home for it is a column on
-- accounts, not a column on a row that lives half an hour.

-- UNIQUE because lookup is by hash and a collision would be an authentication
-- bug rather than a duplicate row.
CREATE UNIQUE INDEX auth_signup_tokens_token_hash_idx
  ON auth_signup_tokens(token_hash);

-- Drives the per-address cap on live tokens and the address-scoped cleanup that
-- runs when someone signs up again or finishes signing up.
CREATE INDEX auth_signup_tokens_email_created_at_idx
  ON auth_signup_tokens(email, created_at DESC);

-- Drives the global cap on live tokens, which is what actually bounds a leaked
-- invite code sprayed at thousands of distinct addresses -- a per-address cap
-- does nothing there. Partial, because the only rows that query cares about are
-- the unconsumed ones and every row leaves that set permanently the moment it
-- is redeemed. 0007 already uses a partial index for the same reason.
--
-- Note that nothing sweeps this table on a schedule: there is no cron in this
-- worker, and cleanup is address-scoped, so expired rows for addresses that
-- never come back accumulate. The global cap bounds the rate at which that can
-- happen, not the total. At signup volumes that is a sentence in a migration
-- rather than a problem.
CREATE INDEX auth_signup_tokens_live_expires_at_idx
  ON auth_signup_tokens(expires_at)
  WHERE consumed_at IS NULL;
