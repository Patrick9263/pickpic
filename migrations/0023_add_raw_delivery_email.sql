-- Migration number: 0023 	 2026-09-13T22:00:00.000Z
--
-- Moves the entitlement to a delivered RAW off the requesting browser and onto
-- a confirmed email address (issue #224, fixing #222). Migration 0019 recorded
-- the request, 0020 the delivery, 0021 the collection and 0022 the
-- photographer's release; this records *who* asked, in a form that survives
-- them opening the gallery on a different device.
--
-- The problem being fixed: a visitor identity is a randomUUID in one browser's
-- localStorage, so one person collecting a ~120MB RAW on their laptop after
-- requesting it on their phone is two visitors and two raw_requests rows. The
-- phone's row is fulfilled and never downloaded, which makes isRawReclaimable's
-- awaitingCount veto true forever and pins the object for the full
-- RAW_DELIVERY_TTL_MS.

-- Nullable, not NOT NULL, because rows written before this migration have no
-- address and must stay valid -- they remain collectable through the visitor
-- header exactly as before. Every row written from now on carries one.
ALTER TABLE raw_requests ADD COLUMN email TEXT;

-- The per-request download token, stored only as a SHA-256 hash exactly like
-- auth_login_tokens (migration 0015), so a database dump cannot be replayed as
-- a download. A column rather than a table because there is exactly one live
-- token per request and its lifetime is the request's lifetime.
--
-- Deliberately no expiry column. A link's life is the RAW's life, which is
-- already derivable as fulfilled_at + RAW_DELIVERY_TTL_MS -- the same
-- expression toViewerRawDownload shows the viewer. A stored copy would be a
-- second source of truth that could drift away from what the reclaim actually
-- does.
ALTER TABLE raw_requests ADD COLUMN download_token_hash TEXT;

-- When this row last caused mail to be sent, which is what the per-event send
-- caps count. Anyone holding a share link can cause a send, so the caps are the
-- only thing standing between a public gallery and a mail amplifier pointed at
-- the domain every customer's sign-in deliverability depends on.
ALTER TABLE raw_requests ADD COLUMN delivery_email_sent_at TEXT;

-- The identity claim this migration exists to make: one request per address per
-- photo, so the same person asking from a second browser attaches to the row
-- they already have instead of creating the duplicate that strands the reclaim.
--
-- Partial because pre-0023 rows carry NULL here and SQLite would otherwise
-- treat them as distinct-but-present. The surviving PRIMARY KEY (photo_id,
-- visitor_id) still enforces one request per browser, so a request has to
-- satisfy both -- which is why addRawRequest resolves the row by an explicit
-- read rather than a single ON CONFLICT upsert, since ON CONFLICT can only name
-- one of the two indexes and the other raises instead of taking the update arm.
CREATE UNIQUE INDEX raw_requests_photo_email_idx
  ON raw_requests(photo_id, email)
  WHERE email IS NOT NULL;

-- Drives the download route's token lookup, and makes a hash collision across
-- two live requests impossible rather than merely unlikely. Partial for the
-- same reason as above.
CREATE UNIQUE INDEX raw_requests_download_token_idx
  ON raw_requests(download_token_hash)
  WHERE download_token_hash IS NOT NULL;

-- A request whose address has not been proven yet.
--
-- Nothing about the requester is written into raw_requests until they click the
-- link, which is the same rule auth_signup_tokens (migration 0016) follows for
-- the same reason: a row written on the strength of a typed address lets
-- someone claim an address that is not theirs. Here the cost of skipping it is
-- concrete rather than theoretical -- a request nobody can collect is a request
-- whose awaitingCount veto holds ~120MB open for fourteen days, which is
-- exactly the #222 failure this migration is undoing.
--
-- visitor_token and display_name are carried here rather than upserted into
-- gallery_visitors early, so an unconfirmed address leaves no trace in the
-- event at all.
--
-- There is deliberately no table of confirmed addresses: a raw_requests row for
-- an address in an event *is* the record that the address was confirmed there,
-- because nothing else ever writes one. That also self-cleans -- a viewer whose
-- every request was withdrawn or cancelled (#221) leaves no trace and simply
-- confirms again.
CREATE TABLE raw_request_confirmations (
  id TEXT PRIMARY KEY,

  token_hash TEXT NOT NULL UNIQUE,

  event_id TEXT NOT NULL,
  photo_id TEXT NOT NULL,

  email TEXT NOT NULL,

  visitor_token TEXT NOT NULL
    CHECK (length(visitor_token) BETWEEN 20 AND 100),

  display_name TEXT NOT NULL
    CHECK (length(trim(display_name)) BETWEEN 1 AND 80),

  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,

  FOREIGN KEY (event_id)
    REFERENCES events(id)
    ON DELETE CASCADE,

  FOREIGN KEY (photo_id)
    REFERENCES photos(id)
    ON DELETE CASCADE
);

-- Answers "is this address already waiting on a confirmation here", and lets a
-- successful redemption clear the requester's other pending rows in one
-- statement.
CREATE INDEX raw_request_confirmations_event_email_idx
  ON raw_request_confirmations(event_id, email);

-- Answers "is this browser waiting on a confirmation", which is what the
-- gallery listing reads so the pending state survives the viewer leaving to
-- check their mail and coming back.
CREATE INDEX raw_request_confirmations_visitor_idx
  ON raw_request_confirmations(event_id, visitor_token);
