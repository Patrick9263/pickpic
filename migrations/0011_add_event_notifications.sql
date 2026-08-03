CREATE TABLE event_notifications (
  event_id TEXT NOT NULL,
  notification_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0
    CHECK (attempt_count >= 0),
  last_attempt_at TEXT,
  sent_at TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (event_id, notification_type),
  FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
);

-- Do not send retroactive notifications for events that already had proofs
-- before this feature was deployed.
INSERT INTO event_notifications (
  event_id,
  notification_type,
  status,
  attempt_count,
  last_attempt_at,
  sent_at,
  last_error,
  created_at,
  updated_at
)
SELECT
  event_id,
  'telegram_upload_started',
  'sent',
  0,
  NULL,
  MIN(created_at),
  NULL,
  MIN(created_at),
  MIN(created_at)
FROM photos
GROUP BY event_id;
