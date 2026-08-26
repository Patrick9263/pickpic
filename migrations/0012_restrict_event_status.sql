-- Migration number: 0012 	 2026-08-26T00:00:00.000Z
--
-- Narrow the allowed values of events.status to the four the application
-- actually writes (the worker's isGalleryStatus guard already rejects
-- 'uploading' and 'editing' with a 400).
--
-- This is deliberately NOT done by tightening the CHECK constraint. SQLite
-- cannot alter a CHECK constraint in place, so that would mean recreating the
-- events table -- and photos, gallery_visitors and event_notifications all
-- declare ON DELETE CASCADE against events(id). In SQLite a DROP TABLE fires
-- those cascades, and the usual PRAGMA foreign_keys=OFF guard does not help
-- here: D1 runs a migration's statements as one implicit transaction, and
-- PRAGMA foreign_keys is a documented no-op inside a transaction. Neither
-- PRAGMA defer_foreign_keys nor a legacy_alter_table rename-first rebuild
-- rescues it (both were tested and both still destroyed every child row).
--
-- Triggers enforce the same rule while touching no rows and dropping no table,
-- so this migration cannot lose data. The original six-value CHECK constraint
-- stays on the table; because the trigger's set is a subset of it, the
-- effective constraint is the four values below.
CREATE TRIGGER events_status_insert_guard
BEFORE INSERT ON events
FOR EACH ROW
WHEN NEW.status NOT IN ('draft', 'ready', 'completed', 'archived')
BEGIN
  SELECT RAISE(ABORT, 'events.status must be draft, ready, completed or archived');
END;

CREATE TRIGGER events_status_update_guard
BEFORE UPDATE OF status ON events
FOR EACH ROW
WHEN NEW.status NOT IN ('draft', 'ready', 'completed', 'archived')
BEGIN
  SELECT RAISE(ABORT, 'events.status must be draft, ready, completed or archived');
END;
