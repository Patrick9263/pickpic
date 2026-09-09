-- Migration number: 0019 	 2026-09-09T00:00:00.000Z
--
-- Event-level opt-in for gallery viewers to request the original RAW file for
-- a photo (issue #180), distinct from hearting it for an edit.

ALTER TABLE events
ADD COLUMN raw_requests_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (raw_requests_enabled IN (0, 1));

-- Mirrors hearts (migration 0003): same composite PK doubling as the
-- idempotency key for "has this visitor already requested this photo's RAW".
--
-- The notification lease/retry state lives on this row rather than in
-- event_notifications, because that table's PRIMARY KEY (event_id,
-- notification_type) is a one-row-per-event singleton (migration 0011) -- it
-- can represent "upload started" once per event but not many independent RAW
-- requests per event. Reusing (photo_id, visitor_id) as both the request
-- identity and the notification lease key avoids a second table.
CREATE TABLE raw_requests (
  photo_id TEXT NOT NULL,
  visitor_id TEXT NOT NULL,
  created_at TEXT NOT NULL,

  notification_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (notification_status IN ('pending', 'sending', 'sent', 'failed')),
  notification_attempt_count INTEGER NOT NULL DEFAULT 0
    CHECK (notification_attempt_count >= 0),
  notification_last_attempt_at TEXT,
  notification_sent_at TEXT,
  notification_last_error TEXT,

  PRIMARY KEY (photo_id, visitor_id),

  FOREIGN KEY (photo_id)
    REFERENCES photos(id)
    ON DELETE CASCADE,

  FOREIGN KEY (visitor_id)
    REFERENCES gallery_visitors(id)
    ON DELETE CASCADE
);

CREATE INDEX raw_requests_visitor_id_idx
  ON raw_requests(visitor_id);
