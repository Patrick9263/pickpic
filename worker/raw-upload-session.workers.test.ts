import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ACCOUNT_ID } from "./accounts.ts";
import { RAW_UPLOAD_PART_SIZE } from "./index.ts";
import {
  clearTestData,
  insertEvent,
  insertPhoto,
  setAccountStorageCap,
  testSha256,
} from "./test-fixtures.ts";
import {
  adminRequest,
  expectError,
  expectMethodNotAllowed,
} from "./test-request.ts";

/*
 * #367 (design: #362): the worker half of resumable RAW upload. Bodies are
 * built with real byte counts against the fixed part size rather than a
 * mocked-down constant, so these exercise the actual multipart round trip
 * against R2 the same way the iPad's queued part uploads will.
 */

interface StartBody {
  partSize: number;
  partCount: number;
  landedParts: number[];
}

interface PartBody {
  landedParts?: number[];
  photoId?: string;
  pendingRawRequestCount?: number;
  rawPhoto?: { originalFilename: string; byteSize: number } | null;
}

const EVENT_ID = "event-raw-upload";
const PHOTO_ID = "photo-raw-upload";
const SHARE_TOKEN = "share-raw-upload";
const FILENAME = "DSC01015.ARW";
const SECOND_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222";

/*
 * One full part plus a partial second, so a two-part round trip -- including
 * "the last part lands" -- stays small without special-casing the part size
 * itself.
 */
const BYTE_SIZE = RAW_UPLOAD_PART_SIZE + 100;

function startPath(photoId: string = PHOTO_ID): string {
  return `/api/admin/photos/${photoId}/raw/start`;
}

function partPath(partNumber: number, photoId: string = PHOTO_ID): string {
  return `/api/admin/photos/${photoId}/raw/parts/${partNumber}`;
}

function startSession(overrides?: {
  sha256?: string;
  byteSize?: number;
  filename?: string;
  photoId?: string;
}) {
  return adminRequest<StartBody>("POST", startPath(overrides?.photoId), {
    json: {
      filename: overrides?.filename ?? FILENAME,
      sha256: overrides?.sha256 ?? testSha256("raw-a"),
      byteSize: overrides?.byteSize ?? BYTE_SIZE,
    },
  });
}

function uploadPart(
  partNumber: number,
  size: number,
  photoId: string = PHOTO_ID,
) {
  return adminRequest<PartBody>("PUT", partPath(partNumber, photoId), {
    body: new Uint8Array(size),
    headers: { "Content-Type": "application/octet-stream" },
  });
}

async function accountStorageBytes(
  accountId: string = BOOTSTRAP_ACCOUNT_ID,
): Promise<number> {
  const row = await env.DB.prepare(
    `SELECT storage_bytes AS storageBytes FROM accounts WHERE id = ?`,
  )
    .bind(accountId)
    .first<{ storageBytes: number }>();

  return row?.storageBytes ?? 0;
}

/*
 * clearTestData only empties the bootstrap account's rows (see its own
 * comment), so a second account inserted by one test would collide with the
 * next test's insert of the same id -- IGNORE makes this idempotent across
 * the file instead of tracking who ran first.
 */
async function insertSecondAccount(): Promise<void> {
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT OR IGNORE INTO accounts (id, name, status, database_id, created_at, updated_at)
      VALUES (?, ?, 'active', NULL, ?, ?)
    `,
  )
    .bind(SECOND_ACCOUNT_ID, "Other Studio", now, now)
    .run();
}

beforeEach(async () => {
  await clearTestData();
  await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });
  await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });
});

describe("POST /api/admin/photos/:id/raw/start", () => {
  it("starts a new session with the full part count and no landed parts", async () => {
    const result = await startSession();

    expect(result.status).toBe(200);
    expect(result.body).toEqual({
      partSize: RAW_UPLOAD_PART_SIZE,
      partCount: 2,
      landedParts: [],
    });
  });

  it("resumes and returns the landed parts when sha256 and byteSize match", async () => {
    await startSession();
    await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    const result = await startSession();

    expect(result.status).toBe(200);
    expect(result.body).toEqual({
      partSize: RAW_UPLOAD_PART_SIZE,
      partCount: 2,
      landedParts: [1],
    });
  });

  /*
   * A source file re-saved in Affinity has a new hash (#362), so a start
   * carrying it must discard whatever parts landed against the old one
   * rather than resume into them.
   */
  it("restarts the upload when the sha256 changes", async () => {
    await startSession({ sha256: testSha256("raw-a") });
    await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    const restarted = await startSession({ sha256: testSha256("raw-b") });

    expect(restarted.body.landedParts).toEqual([]);

    /*
     * The original hash no longer matches the active session either -- it
     * was discarded, not kept around as a second resumable attempt.
     */
    const resumedOriginal = await startSession({ sha256: testSha256("raw-a") });

    expect(resumedOriginal.body.landedParts).toEqual([]);
  });

  it("enforces the storage cap at start, without creating a session", async () => {
    const previousCap = await setAccountStorageCap(1024);

    try {
      const result = await startSession();

      expectError(
        result,
        403,
        "This account's storage limit has been reached.",
      );

      const session = await env.DB.prepare(
        `SELECT id FROM raw_upload_sessions WHERE photo_id = ?`,
      )
        .bind(PHOTO_ID)
        .first();

      expect(session).toBeNull();
    } finally {
      await setAccountStorageCap(previousCap);
    }
  });

  it("404s for a photo belonging to another account", async () => {
    await insertSecondAccount();

    const otherEventId = "event-raw-upload-other";
    const otherPhotoId = "photo-raw-upload-other";

    await insertEvent({
      id: otherEventId,
      shareToken: "share-raw-upload-other",
      accountId: SECOND_ACCOUNT_ID,
    });
    await insertPhoto({
      id: otherPhotoId,
      eventId: otherEventId,
      accountId: SECOND_ACCOUNT_ID,
    });

    const result = await startSession({ photoId: otherPhotoId });

    expectError(result, 404, "Photo not found.");
  });

  it("405s on a non-POST method", async () => {
    expectMethodNotAllowed(await adminRequest("GET", startPath()));
  });
});

describe("PUT /api/admin/photos/:id/raw/parts/:n", () => {
  it("404s when there is no active upload for the photo", async () => {
    const result = await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    expectError(result, 404, "No active upload for this photo.");
  });

  it("rejects a part that is not the expected size", async () => {
    await startSession();

    const result = await uploadPart(1, RAW_UPLOAD_PART_SIZE - 1);

    expectError(result, 400);
  });

  it("rejects the last part when it isn't exactly the remainder", async () => {
    await startSession();
    await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    const result = await uploadPart(2, 99);

    expectError(result, 400);
  });

  it("rejects an out-of-range part number", async () => {
    await startSession();

    const result = await uploadPart(3, 100);

    expectError(result, 400);
  });

  it("stores a re-sent part idempotently rather than erroring", async () => {
    await startSession();

    const first = await uploadPart(1, RAW_UPLOAD_PART_SIZE);
    const second = await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    expect(first.body.landedParts).toEqual([1]);
    expect(second.body.landedParts).toEqual([1]);
  });

  it("completes the upload when the last part lands, running uploadRawPhoto's finishing tail", async () => {
    await startSession();
    await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    const result = await uploadPart(2, 100);

    expect(result.status).toBe(200);
    expect(result.body.rawPhoto).toMatchObject({
      originalFilename: FILENAME,
      byteSize: BYTE_SIZE,
    });

    const stored = await env.DB.prepare(
      `
        SELECT
          raw_storage_key AS rawStorageKey,
          raw_byte_size AS rawByteSize
        FROM photos
        WHERE id = ?
      `,
    )
      .bind(PHOTO_ID)
      .first<{ rawStorageKey: string | null; rawByteSize: number | null }>();

    expect(stored?.rawByteSize).toBe(BYTE_SIZE);

    const object = await env.pickpic_photos.get(stored?.rawStorageKey ?? "");

    expect(object?.size).toBe(BYTE_SIZE);

    const session = await env.DB.prepare(
      `SELECT id FROM raw_upload_sessions WHERE photo_id = ?`,
    )
      .bind(PHOTO_ID)
      .first();

    expect(session).toBeNull();

    expect(await accountStorageBytes()).toBe(BYTE_SIZE);
  });

  /*
   * The atomic completing_at claim (#362) exists for exactly this: whichever
   * part's landing leaves none missing must be the only one that completes
   * the upload, however the two requests interleave.
   */
  it("completes exactly once when the last two parts land together", async () => {
    await startSession();

    const [first, second] = await Promise.all([
      uploadPart(1, RAW_UPLOAD_PART_SIZE),
      uploadPart(2, 100),
    ]);

    const completions = [first, second].filter(
      (result) => result.body.rawPhoto,
    );

    expect(completions).toHaveLength(1);
    expect(await accountStorageBytes()).toBe(BYTE_SIZE);

    const requests = await env.DB.prepare(
      `SELECT COUNT(*) AS count FROM raw_upload_sessions WHERE photo_id = ?`,
    )
      .bind(PHOTO_ID)
      .first<{ count: number }>();

    expect(requests?.count).toBe(0);
  });

  it("enforces the storage cap at completion, freeing the object and the session", async () => {
    await startSession();
    await uploadPart(1, RAW_UPLOAD_PART_SIZE);

    const previousCap = await setAccountStorageCap(1024);

    try {
      const result = await uploadPart(2, 100);

      expectError(
        result,
        403,
        "This account's storage limit has been reached.",
      );

      const stored = await env.DB.prepare(
        `SELECT raw_storage_key AS rawStorageKey FROM photos WHERE id = ?`,
      )
        .bind(PHOTO_ID)
        .first<{ rawStorageKey: string | null }>();

      expect(stored?.rawStorageKey).toBeNull();

      const session = await env.DB.prepare(
        `SELECT id FROM raw_upload_sessions WHERE photo_id = ?`,
      )
        .bind(PHOTO_ID)
        .first();

      expect(session).toBeNull();
    } finally {
      await setAccountStorageCap(previousCap);
    }
  });

  it("404s for a photo belonging to another account", async () => {
    await insertSecondAccount();

    const otherEventId = "event-raw-upload-part-other";
    const otherPhotoId = "photo-raw-upload-part-other";

    await insertEvent({
      id: otherEventId,
      shareToken: "share-raw-upload-part-other",
      accountId: SECOND_ACCOUNT_ID,
    });
    await insertPhoto({
      id: otherPhotoId,
      eventId: otherEventId,
      accountId: SECOND_ACCOUNT_ID,
    });

    const result = await uploadPart(1, RAW_UPLOAD_PART_SIZE, otherPhotoId);

    expectError(result, 404, "No active upload for this photo.");
  });

  it("405s on a non-PUT method", async () => {
    await startSession();

    expectMethodNotAllowed(await adminRequest("GET", partPath(1)));
  });
});
