-- Migration number: 0005 	 2026-07-11T04:29:24.285Z
ALTER TABLE photos
ADD COLUMN workflow_status TEXT NOT NULL DEFAULT 'idle'
  CHECK (
    workflow_status IN (
      'idle',
      'editing',
      'final'
    )
  );