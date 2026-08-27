-- Migration number: 0014 	 2026-08-27T00:00:00.000Z
--
-- Multi-tenancy, step 2 of 2: make account_id mandatory.
--
-- Apply this only AFTER the worker that writes account_id is deployed. Until
-- then the previous worker is still inserting rows without one and these
-- triggers would abort its writes. CI deploys on push to main while migrations
-- are applied by hand, so the order is: apply 0013, merge and let the deploy
-- land, then apply this file.
--
-- SQLite cannot add NOT NULL to an existing column without rebuilding the
-- table, and a rebuild in D1 fires every ON DELETE CASCADE (see 0012 for the
-- full account of why the usual PRAGMA workarounds do not help). These triggers
-- enforce the same rule while touching no rows and dropping no table, so this
-- migration cannot lose data.

-- ---------------------------------------------------------------------------
-- Catch anything the previous worker created between 0013 and the deploy
-- ---------------------------------------------------------------------------
--
-- Rows left NULL would be invisible to the now account-scoped queries, which
-- would look exactly like data loss from the dashboard even though the rows are
-- still present. Re-running the backfill closes that window rather than
-- assuming it was empty.

UPDATE events
SET account_id = '00000000-0000-4000-8000-000000000001'
WHERE account_id IS NULL;

UPDATE photos
SET account_id = (
  SELECT e.account_id
  FROM events e
  WHERE e.id = photos.event_id
)
WHERE account_id IS NULL;

-- ---------------------------------------------------------------------------
-- events.account_id is required
-- ---------------------------------------------------------------------------

CREATE TRIGGER events_account_id_insert_guard
BEFORE INSERT ON events
FOR EACH ROW
WHEN NEW.account_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'events.account_id is required');
END;

CREATE TRIGGER events_account_id_update_guard
BEFORE UPDATE OF account_id ON events
FOR EACH ROW
WHEN NEW.account_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'events.account_id is required');
END;

-- ---------------------------------------------------------------------------
-- photos.account_id must match its parent event
-- ---------------------------------------------------------------------------
--
-- Stronger than NOT NULL: a denormalised owner column that can drift from its
-- parent is a tenancy bug generator, so the invariant enforced here is equality
-- with the parent event, not mere presence. 'IS NOT' is SQLite's null-safe
-- inequality, so a NULL on either side aborts -- including the case where
-- NEW.event_id names an event that does not exist and the subquery yields NULL.

CREATE TRIGGER photos_account_id_insert_guard
BEFORE INSERT ON photos
FOR EACH ROW
WHEN NEW.account_id IS NOT (
  SELECT e.account_id
  FROM events e
  WHERE e.id = NEW.event_id
)
BEGIN
  SELECT RAISE(ABORT, 'photos.account_id must equal the parent event account_id');
END;

CREATE TRIGGER photos_account_id_update_guard
BEFORE UPDATE OF account_id, event_id ON photos
FOR EACH ROW
WHEN NEW.account_id IS NOT (
  SELECT e.account_id
  FROM events e
  WHERE e.id = NEW.event_id
)
BEGIN
  SELECT RAISE(ABORT, 'photos.account_id must equal the parent event account_id');
END;
