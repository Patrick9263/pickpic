import { env } from "cloudflare:test";
import { BOOTSTRAP_ACCOUNT_ID, type AccountRecord } from "./accounts.ts";
import { createAccountScope, type AccountScope } from "./tenancy.ts";

/*
 * Seeding helpers for the Workers-pool suite.
 *
 * Rows go in through plain SQL rather than through the upload handlers on
 * purpose: a fixture that had to satisfy createPhoto would need R2, a multipart
 * body and a storage cap, and a failure anywhere in that chain would look like a
 * failure of whatever is actually under test.
 */

interface EventSeed {
  id: string;
  shareToken: string;
  title?: string;
  status?: string;
  createdAt?: string;
  rawRequestsEnabled?: boolean;
}

interface PhotoSeed {
  id: string;
  eventId: string;
  originalFilename?: string;
  sourceSha256?: string | null;
  finalSha256?: string | null;
  capturedAt?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  createdAt?: string;
}

/*
 * The pool gives the whole run one D1 database, and cloudflare:test's reset()
 * would take the migrated schema down with the rows. Emptying the tables these
 * tests write keeps the schema -- and the bootstrap account migration 0013
 * seeds -- in place. Children first, because whether D1 enforces the ON DELETE
 * CASCADE edges here is not something a test should have to depend on.
 */
export async function clearTestData(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM hearts"),
    env.DB.prepare("DELETE FROM raw_requests"),
    env.DB.prepare("DELETE FROM comments"),
    env.DB.prepare("DELETE FROM photo_variants"),
    env.DB.prepare("DELETE FROM gallery_visitors"),
    env.DB.prepare("DELETE FROM event_notifications"),
    env.DB.prepare("DELETE FROM photos"),
    env.DB.prepare("DELETE FROM events"),
  ]);
}

/*
 * The scope an admin request would be handed, built from the real bootstrap
 * account row so plan and storage cap come from the migrations rather than from
 * a hand-written object that could drift from them.
 */
export async function bootstrapScope(): Promise<AccountScope> {
  const account = await env.DB.prepare(
    `
      SELECT
        id,
        name,
        status,
        plan,
        storage_cap_bytes AS storageCapBytes,
        storage_bytes AS storageBytes,
        database_id AS databaseId
      FROM accounts
      WHERE id = ?
    `,
  )
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .first<AccountRecord>();

  if (!account) {
    throw new Error(
      "The bootstrap account is missing -- migrations did not apply.",
    );
  }

  return createAccountScope(account, env.DB);
}

export async function insertEvent(seed: EventSeed): Promise<void> {
  const createdAt = seed.createdAt ?? new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO events (
        id,
        title,
        share_token,
        status,
        created_at,
        updated_at,
        account_id,
        raw_requests_enabled
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `,
  )
    .bind(
      seed.id,
      seed.title ?? "Test event",
      seed.shareToken,
      seed.status ?? "ready",
      createdAt,
      createdAt,
      BOOTSTRAP_ACCOUNT_ID,
      seed.rawRequestsEnabled ? 1 : 0,
    )
    .run();
}

export async function insertPhoto(seed: PhotoSeed): Promise<void> {
  await env.DB.prepare(
    `
      INSERT INTO photos (
        id,
        event_id,
        original_filename,
        storage_key,
        content_type,
        byte_size,
        workflow_status,
        source_sha256,
        final_sha256,
        captured_at,
        latitude,
        longitude,
        created_at,
        account_id
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `,
  )
    .bind(
      seed.id,
      seed.eventId,
      seed.originalFilename ?? `${seed.id}.ARW`,

      /* UNIQUE, so it has to vary with the photo. */
      `events/${seed.eventId}/photos/${seed.id}.jpg`,
      "image/jpeg",
      1024,
      "idle",
      seed.sourceSha256 ?? null,
      seed.finalSha256 ?? null,
      seed.capturedAt ?? null,
      seed.latitude ?? null,
      seed.longitude ?? null,
      seed.createdAt ?? new Date().toISOString(),
      BOOTSTRAP_ACCOUNT_ID,
    )
    .run();
}

/*
 * A heart needs a gallery_visitors row to hang off, so seeding one means two
 * inserts. The visitor token is padded to the 20-character minimum the CHECK on
 * gallery_visitors imposes.
 */
export async function insertHeart(seed: {
  photoId: string;
  eventId: string;
  visitorToken: string;
}): Promise<void> {
  const visitorId = `visitor-${seed.eventId}-${seed.visitorToken}`;
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO gallery_visitors (
        id,
        event_id,
        visitor_token,
        display_name,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (event_id, visitor_token) DO NOTHING
    `,
  )
    .bind(visitorId, seed.eventId, seed.visitorToken, "Test visitor", now, now)
    .run();

  await env.DB.prepare(
    `
      INSERT INTO hearts (photo_id, visitor_id, created_at)
      VALUES (?, ?, ?)
    `,
  )
    .bind(seed.photoId, visitorId, now)
    .run();
}

/*
 * Mirrors insertHeart: a RAW request needs the same gallery_visitors row to
 * hang off.
 */
export async function insertRawRequest(seed: {
  photoId: string;
  eventId: string;
  visitorToken: string;
}): Promise<void> {
  const visitorId = `visitor-${seed.eventId}-${seed.visitorToken}`;
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO gallery_visitors (
        id,
        event_id,
        visitor_token,
        display_name,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (event_id, visitor_token) DO NOTHING
    `,
  )
    .bind(visitorId, seed.eventId, seed.visitorToken, "Test visitor", now, now)
    .run();

  await env.DB.prepare(
    `
      INSERT INTO raw_requests (photo_id, visitor_id, created_at)
      VALUES (?, ?, ?)
    `,
  )
    .bind(seed.photoId, visitorId, now)
    .run();
}

/*
 * A distinct but readable 64-character lowercase hex string, which is the shape
 * the CHECK on source_sha256 / final_sha256 enforces. Hex-encoding the seed
 * rather than padding it means any seed string produces a legal hash, so a test
 * can name its hashes after what they stand for.
 */
export function testSha256(seed: string): string {
  const hex = Array.from(seed, (character) =>
    character.charCodeAt(0).toString(16).padStart(2, "0"),
  ).join("");

  return hex.padEnd(64, "0").slice(0, 64);
}
