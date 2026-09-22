import { beforeEach, describe, expect, it, afterEach } from "vitest";
import { env } from "cloudflare:test";
import {
  captureEmails,
  clearTestData,
  insertEvent,
  insertPhoto,
  insertRawRequest,
  linkFromEmail,
  type CapturedEmail,
} from "./test-fixtures.ts";
import { expectError, galleryRequest } from "./test-request.ts";

/*
 * #271: multi-select "Request originals (N)". These cover addRawRequestsBatch
 * (worker/index.ts) end to end through the real route, the same way
 * raw-delivery.workers.test.ts covers the single-photo confirmation flow --
 * the parts worth protecting only exist in the chain (the guard, the shared
 * cap, and the one-mail-per-batch behaviour), not in any helper underneath it.
 */

const EVENT_ID = "event-batch";
const SHARE_TOKEN = "share-batch";
const VISITOR_TOKEN = "visitor-token-for-batch-tests";
const GUEST_EMAIL = "batch-guest@example.com";

const BATCH_PATH = `/api/galleries/${SHARE_TOKEN}/raw-requests`;

let mail: ReturnType<typeof captureEmails>;

function photoId(index: number): string {
  return `photo-batch-${index}`;
}

async function seedPhotos(count: number): Promise<string[]> {
  const ids: string[] = [];

  for (let index = 0; index < count; index += 1) {
    const id = photoId(index);

    await insertPhoto({
      id,
      eventId: EVENT_ID,
      originalFilename: `DSC0${index}.ARW`,
    });
    ids.push(id);
  }

  return ids;
}

function requestBatch(
  ids: string[],
  overrides: { email?: string; displayName?: string } = {},
) {
  return galleryRequest<{
    requested: number;
    confirmationPending: boolean;
    email?: string;
    photoIds?: string[];
    error?: string;
  }>("PUT", BATCH_PATH, {
    json: {
      displayName: overrides.displayName ?? "Guest",
      email: overrides.email ?? GUEST_EMAIL,
      photoIds: ids,
    },
    headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
  });
}

function tokenFromEmail(email: CapturedEmail): string {
  const url = new URL(linkFromEmail(email));

  return url.searchParams.get("t") ?? "";
}

function confirmRaw(token: string) {
  return galleryRequest<{ photoId?: string; error?: string }>(
    "POST",
    `/api/galleries/${SHARE_TOKEN}/raw-confirm`,
    { json: { token } },
  );
}

async function countRawRequests(): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS total FROM raw_requests",
  ).first<{ total: number }>();

  return row?.total ?? 0;
}

beforeEach(async () => {
  await clearTestData();
  mail = captureEmails();

  await insertEvent({
    id: EVENT_ID,
    shareToken: SHARE_TOKEN,
    status: "ready",
    rawRequestsEnabled: true,
  });
});

afterEach(() => {
  mail.restore();
});

describe("PUT /api/galleries/:shareToken/raw-requests", () => {
  it("404s when the event has not opted in to RAW requests", async () => {
    await env.DB.prepare(
      "UPDATE events SET raw_requests_enabled = 0 WHERE id = ?",
    )
      .bind(EVENT_ID)
      .run();
    const ids = await seedPhotos(2);

    const result = await requestBatch(ids);

    expectError(
      result,
      404,
      "None of the selected photos can be requested right now.",
    );
  });

  it("rejects an empty selection", async () => {
    const result = await requestBatch([]);

    expectError(result, 400, "Select at least one photo to request.");
  });

  it("rejects a missing display name", async () => {
    const ids = await seedPhotos(1);

    const result = await requestBatch(ids, { displayName: "" });

    expectError(result, 400, "Your name must be between 1 and 80 characters.");
  });

  it("rejects an invalid email address", async () => {
    const ids = await seedPhotos(1);

    const result = await requestBatch(ids, { email: "not-an-email" });

    expectError(
      result,
      400,
      "Enter a valid email address to request the original files.",
    );
  });

  it("rejects a batch larger than the sanity bound", async () => {
    const ids = Array.from({ length: 201 }, (_, index) => photoId(index));

    const result = await requestBatch(ids);

    expect(result.status).toBe(400);
  });

  it("silently drops ids that don't belong to this gallery", async () => {
    const ids = await seedPhotos(2);

    await insertEvent({
      id: "event-elsewhere",
      shareToken: "share-elsewhere",
      status: "ready",
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: "photo-elsewhere", eventId: "event-elsewhere" });

    const result = await requestBatch([
      ...ids,
      "photo-elsewhere",
      "no-such-id",
    ]);

    expect(result.body.photoIds).toEqual(ids);
  });

  /*
   * The common case: an address that already has a request anywhere in this
   * event needs no further confirmation, so a batch just writes every row
   * directly and sends no mail at all.
   */
  it("writes every row and sends no mail once the address is confirmed", async () => {
    await insertPhoto({ id: "photo-batch-confirmed", eventId: EVENT_ID });
    await insertRawRequest({
      photoId: "photo-batch-confirmed",
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: GUEST_EMAIL,
    });
    const ids = await seedPhotos(3);

    const result = await requestBatch(ids);

    expect(result.body).toMatchObject({
      requested: 3,
      confirmationPending: false,
      email: GUEST_EMAIL,
    });
    expect(mail.sent).toHaveLength(0);
    // The pre-seeded confirmed row plus the three just requested.
    expect(await countRawRequests()).toBe(4);
  });

  /*
   * The behaviour #271's design exists for: N photos, one confirmation mail,
   * not N.
   */
  it("sends exactly one confirmation mail for an unconfirmed address", async () => {
    const ids = await seedPhotos(5);

    const result = await requestBatch(ids);

    expect(result.body).toMatchObject({
      requested: 0,
      confirmationPending: true,
      email: GUEST_EMAIL,
    });
    expect(result.body.photoIds).toEqual(ids);
    expect(mail.sent).toHaveLength(1);
    expect(mail.sent[0].subject).toContain("5 original files");
    expect(await countRawRequests()).toBe(0);
  });

  it("uses the single filename, not a count, when the batch is one photo", async () => {
    const ids = await seedPhotos(1);

    await requestBatch(ids);

    expect(mail.sent[0].subject).toContain("DSC00.ARW");
  });

  /*
   * Confirming the mailed link only ever writes the anchor photo's row --
   * see queueRawRequestConfirmation's comment. The rest of the batch is a
   * client-side follow-up (RawConfirmPage), which this exercises directly
   * against the same route it would call: once the anchor is confirmed the
   * address is proven, so resubmitting the remaining ids goes straight
   * through with no further mail.
   */
  it("only requests the anchor photo on confirmation, and the rest via a follow-up batch call", async () => {
    const ids = await seedPhotos(3);

    await requestBatch(ids);
    const confirmed = await confirmRaw(tokenFromEmail(mail.sent[0]));

    expect(confirmed.body.photoId).toBe(ids[0]);
    expect(await countRawRequests()).toBe(1);

    const followUp = await requestBatch(ids.slice(1));

    expect(followUp.body).toMatchObject({
      requested: 2,
      confirmationPending: false,
    });
    expect(mail.sent).toHaveLength(1);
    expect(await countRawRequests()).toBe(3);
  });

  describe("the in-flight cap", () => {
    /*
     * Seeds 25 already-in-flight (undelivered, uncollected) requests under
     * the same confirmed address -- the state a viewer sits in after their
     * requests have accumulated to the cap.
     */
    async function seedInFlightRequests(count: number): Promise<void> {
      for (let index = 0; index < count; index += 1) {
        const id = `photo-cap-seed-${index}`;

        await insertPhoto({ id, eventId: EVENT_ID });
        await insertRawRequest({
          photoId: id,
          eventId: EVENT_ID,
          visitorToken: `visitor-token-for-cap-seed-${index}`,
          email: GUEST_EMAIL,
        });
      }
    }

    it("refuses a batch that would push a confirmed address over the cap", async () => {
      await seedInFlightRequests(24);
      const ids = await seedPhotos(2);

      const result = await requestBatch(ids);

      expect(result.status).toBe(409);
      expect(result.body.error).toContain("1 more original file");
      expect(await countRawRequests()).toBe(24);
    });

    it("allows a batch that lands exactly on the cap", async () => {
      await seedInFlightRequests(24);
      const ids = await seedPhotos(1);

      const result = await requestBatch(ids);

      expect(result.body).toMatchObject({ requested: 1 });
      expect(await countRawRequests()).toBe(25);
    });

    it("does not count a downloaded request against the cap", async () => {
      await seedInFlightRequests(24);
      // A 25th request that has already been collected -- not in flight.
      await insertPhoto({ id: "photo-cap-collected", eventId: EVENT_ID });
      await insertRawRequest({
        photoId: "photo-cap-collected",
        eventId: EVENT_ID,
        visitorToken: "visitor-cap-collected",
        email: GUEST_EMAIL,
        fulfilledAt: new Date().toISOString(),
        downloadedAt: new Date().toISOString(),
      });
      const ids = await seedPhotos(1);

      const result = await requestBatch(ids);

      expect(result.body).toMatchObject({ requested: 1 });
    });

    /*
     * The single-photo route shares writeRawRequest's own cap check, so the
     * cap holds there too -- not just for the batch endpoint this file is
     * mainly about.
     */
    it("also refuses a single-photo request once the cap is reached", async () => {
      await seedInFlightRequests(25);
      await insertPhoto({ id: "photo-single-over-cap", eventId: EVENT_ID });

      const result = await galleryRequest<{ error?: string }>(
        "PUT",
        `/api/galleries/${SHARE_TOKEN}/photos/photo-single-over-cap/raw-request`,
        {
          json: { displayName: "Guest", email: GUEST_EMAIL },
          headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
        },
      );

      expect(result.status).toBe(409);
    });
  });
});

describe("the requireOpenGallery guard on the batch route", () => {
  it("blocks the batch route with 409 once the gallery is completed", async () => {
    await env.DB.prepare("UPDATE events SET status = 'completed' WHERE id = ?")
      .bind(EVENT_ID)
      .run();
    const ids = await seedPhotos(1);

    const result = await requestBatch(ids);

    expectError(
      result,
      409,
      "This gallery is closed and no longer accepts edit requests or comments.",
    );
  });
});
