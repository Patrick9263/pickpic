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

    /*
     * The running counter the upload paths maintain incrementally. Deleting
     * the photos does not touch it, so a test that actually uploads would
     * otherwise leave every later test's cap check starting from its bytes.
     */
    env.DB.prepare("UPDATE accounts SET storage_bytes = 0"),
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

  /*
   * Seeds a request that has already been satisfied, which is what
   * uploadRawPhoto stamps and what the iPad's pending count must exclude.
   */
  fulfilledAt?: string;

  /*
   * Seeds a request whose RAW has already been collected. Both this and
   * fulfilledAt are passed as literal timestamps rather than offsets so a
   * reclaim test can backdate them past RAW_DOWNLOAD_GRACE_MS or
   * RAW_DELIVERY_TTL_MS without waiting or faking a clock.
   */
  downloadedAt?: string;
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
      INSERT INTO raw_requests (
        photo_id,
        visitor_id,
        created_at,
        fulfilled_at,
        downloaded_at
      )
      VALUES (?, ?, ?, ?, ?)
    `,
  )
    .bind(
      seed.photoId,
      visitorId,
      now,
      seed.fulfilledAt ?? null,
      seed.downloadedAt ?? null,
    )
    .run();
}

/*
 * Puts a delivered RAW where uploadRawPhoto would have left one: bytes in R2,
 * the six raw_* columns on the photo, and the account's running storage
 * counter moved. Going through the real upload route instead would need a
 * ~120 MB body and an admin principal, which is exactly the chain the header
 * comment above warns against making a test depend on.
 */
export async function deliverRawPhoto(seed: {
  photoId: string;
  eventId: string;
  originalFilename?: string;
  uploadedAt?: string;
  bytes?: Uint8Array;
}): Promise<string> {
  const bytes = seed.bytes ?? new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  /*
   * Unique per delivery, matching uploadRawPhoto's own uuid-based key. Test
   * files share one R2 bucket for the whole run with no reset between them, so
   * a deterministic key would let a previous test's object answer a later
   * test's "was this reclaimed?" with a false yes.
   */
  const storageKey =
    `events/${seed.eventId}/photos/${seed.photoId}` +
    `/raw/${crypto.randomUUID()}.raw`;
  const originalFilename = seed.originalFilename ?? `${seed.photoId}.ARW`;

  await env.pickpic_photos.put(storageKey, bytes, {
    httpMetadata: { contentType: "application/octet-stream" },
  });

  await env.DB.batch([
    env.DB.prepare(
      `
        UPDATE photos
        SET
          raw_storage_key = ?,
          raw_original_filename = ?,
          raw_content_type = 'application/octet-stream',
          raw_byte_size = ?,
          raw_sha256 = ?,
          raw_uploaded_at = ?
        WHERE id = ?
      `,
    ).bind(
      storageKey,
      originalFilename,
      bytes.byteLength,
      testSha256(seed.photoId),
      seed.uploadedAt ?? new Date().toISOString(),
      seed.photoId,
    ),

    env.DB.prepare(
      `
        UPDATE accounts
        SET storage_bytes = storage_bytes + ?
        WHERE id = ?
      `,
    ).bind(bytes.byteLength, BOOTSTRAP_ACCOUNT_ID),
  ]);

  return storageKey;
}

/*
 * What the reclaim is asserted against: whether the object is still in R2 and
 * whether the photo row still claims it. The two can only disagree if a
 * reclaim half-failed, which is itself worth failing a test over.
 */
export async function readRawPhotoState(
  photoId: string,
  storageKey: string,
): Promise<{
  rawStorageKey: string | null;
  rawByteSize: number | null;
  rawUploadedAt: string | null;
  objectExists: boolean;
  accountStorageBytes: number;
}> {
  const photo = await env.DB.prepare(
    `
      SELECT
        raw_storage_key AS rawStorageKey,
        raw_byte_size AS rawByteSize,
        raw_uploaded_at AS rawUploadedAt
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<{
      rawStorageKey: string | null;
      rawByteSize: number | null;
      rawUploadedAt: string | null;
    }>();

  const account = await env.DB.prepare(
    `
      SELECT storage_bytes AS storageBytes
      FROM accounts
      WHERE id = ?
    `,
  )
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .first<{ storageBytes: number }>();

  return {
    rawStorageKey: photo?.rawStorageKey ?? null,
    rawByteSize: photo?.rawByteSize ?? null,
    rawUploadedAt: photo?.rawUploadedAt ?? null,
    objectExists: (await env.pickpic_photos.head(storageKey)) !== null,
    accountStorageBytes: account?.storageBytes ?? 0,
  };
}

/*
 * Points the bootstrap account's cap at a chosen value, for the upload paths
 * that reject against it. The cap migrations set is 1 TB, which no test can
 * realistically fill with a body it has to construct in memory.
 *
 * clearTestData resets storage_bytes but deliberately not the cap, so a test
 * that lowers it has to put it back -- which is why this returns the previous
 * value rather than making the caller go and read it.
 */
export async function setAccountStorageCap(capBytes: number): Promise<number> {
  const previous = await env.DB.prepare(
    `
      SELECT storage_cap_bytes AS storageCapBytes
      FROM accounts
      WHERE id = ?
    `,
  )
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .first<{ storageCapBytes: number }>();

  await env.DB.prepare(
    `
      UPDATE accounts
      SET storage_cap_bytes = ?
      WHERE id = ?
    `,
  )
    .bind(capBytes, BOOTSTRAP_ACCOUNT_ID)
    .run();

  return previous?.storageCapBytes ?? 0;
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
