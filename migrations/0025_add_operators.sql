-- Migration number: 0025 	 2026-09-21T00:00:00.000Z
--
-- #195: the first permission in this schema that is not account-scoped.
--
-- `owner` on account_users means "top of one account". Nothing has ever meant
-- "across all accounts", which is what the operator console needs in order to
-- answer "how many beta testers are there, and are they actually uploading?"
-- without a laptop and a D1 console.
--
-- Keyed on (auth_provider, auth_subject) rather than on account_users.id, for
-- two reasons that both follow from what an operator is:
--
--   * An operator need not be a member of any account. Every identity shape
--     this worker can verify fits here -- ('email', <address>) and
--     ('apple', <Apple sub>) from account_users, and
--     ('cloudflare_access', <Access JWT sub>) from the admin worker, which has
--     no account_users row at all.
--
--   * The flag must not move when a membership does. A column on account_users
--     is per (account, user), so a flag there would say "this membership is
--     operator" -- which is a different statement from the one we need.
--
-- THE RULE THAT MAKES THIS TABLE SAFE: no route in worker/ ever INSERTs into
-- it. Rows are added by hand with `wrangler d1 execute`. That preserves the one
-- real advantage a config allowlist would have had -- operator status cannot be
-- granted from inside the app -- while still scaling past a single operator
-- without handing out deploy credentials. It is grep-checkable the same way
-- `scope.database` is the tenancy review checklist:
--
--     grep -rn "INSERT INTO operators" worker/
--
-- must stay empty.
--
-- No CHECK on auth_provider, following the rule 0013 sets out: widening a CHECK
-- is a full table rebuild in SQLite, and a new identity provider is precisely
-- what would widen this column.
--
-- Deliberately minimal. Capability columns (can_write, expires_at) belong here
-- once operator *actions* exist; today requireOperatorPrincipal refuses every
-- non-GET, so there is nothing for them to describe yet.

CREATE TABLE operators (
  id TEXT PRIMARY KEY,

  auth_provider TEXT NOT NULL,

  auth_subject TEXT NOT NULL,

  -- Who this is, for whoever reads a table dump a year from now. Never shown
  -- in the app and never matched against.
  note TEXT,

  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX operators_provider_subject_idx
  ON operators(auth_provider, auth_subject);
