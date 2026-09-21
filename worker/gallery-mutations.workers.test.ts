import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertPhoto,
  insertRawRequest,
  readRawPhotoState,
  setRawDeliveryTtlMs,
} from "./test-fixtures.ts";
import { expectError, galleryRequest } from "./test-request.ts";

/*
 * requireOpenGallery (worker/index.ts:4027-4045) has to sit ahead of every
 * route its regex covers in routeRequest's ordered chain -- a matching
 * route declared above it never reaches the check. That's exactly how
 * hearts once escaped it and kept accepting edit requests on a `completed`
 * gallery the UI had already told the viewer was closed (#124). Driving
 * these through fetch, rather than calling addHeart/addComment directly, is
 * what makes a future ordering regression here visible again.
 */

const EVENT_ID = "event-guard";
const PHOTO_ID = "photo-guard";
const OTHER_PHOTO_ID = "photo-guard-other";
const SHARE_TOKEN = "share-guard";
const VISITOR_TOKEN = "visitor-token-for-guard-tests";
const GUEST_EMAIL = "guest@example.com";

const CLOSED_GALLERY_ERROR =
  "This gallery is closed and no longer accepts edit requests or comments.";

async function seedGallery(status: string): Promise<void> {
  await insertEvent({
    id: EVENT_ID,
    shareToken: SHARE_TOKEN,
    status,
    rawRequestsEnabled: true,
  });
  await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });
  await insertPhoto({ id: OTHER_PHOTO_ID, eventId: EVENT_ID });
}

beforeEach(async () => {
  await clearTestData();
});

describe("the requireOpenGallery guard on gallery mutation routes", () => {
  it.each([
    {
      label: "PUT .../heart",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/heart`,
      json: { displayName: "Guest" },
    },
    {
      label: "PUT .../raw-request",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`,
      json: { displayName: "Guest", email: "guest@example.com" },
    },
    {
      label: "POST .../comments",
      method: "POST",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/comments`,
      json: { displayName: "Guest", body: "Lovely shot" },
    },
  ])(
    "blocks $label with 409 once the gallery is completed",
    async ({ method, path, json }) => {
      await seedGallery("completed");

      const result = await galleryRequest(method, path, {
        json,
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      });

      expectError(result, 409, CLOSED_GALLERY_ERROR);
    },
  );

  it.each([
    {
      label: "PUT .../heart",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/heart`,
      json: { displayName: "Guest" },
    },
    {
      label: "PUT .../raw-request",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`,
      json: { displayName: "Guest", email: "guest@example.com" },
    },
    {
      label: "POST .../comments",
      method: "POST",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/comments`,
      json: { displayName: "Guest", body: "Lovely shot" },
    },
  ])(
    "allows $label once the gallery is ready",
    async ({ method, path, json }) => {
      await seedGallery("ready");

      const result = await galleryRequest(method, path, {
        json,
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      });

      expect([200, 201]).toContain(result.status);
    },
  );

  it("404s a mutation against an unknown share token before touching the photo", async () => {
    const result = await galleryRequest(
      "PUT",
      `/api/galleries/no-such-token/photos/${PHOTO_ID}/heart`,
      {
        json: { displayName: "Guest" },
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      },
    );

    expectError(result, 404, "Gallery not found.");
  });

  it("does not guard a GET on the same photo path", async () => {
    await seedGallery("completed");

    /*
     * The heart route itself only handles PUT/DELETE, so a GET here should
     * fall through to its own 405 -- not the guard's 409 -- confirming the
     * guard's `request.method !== "GET"` condition is what's doing the
     * gating, not the path match alone.
     */
    const result = await galleryRequest(
      "GET",
      `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/heart`,
    );

    expectError(result, 405, "Method not allowed.");
  });
});

/*
 * JSON.parse("null") does not throw, so a literal `null` body used to clear
 * the try/catch around request.json() and crash on the first property read
 * (500) instead of returning the 400 every other malformed body gets (#325).
 * These routes are reachable with no credential at all, so a null body is a
 * public, unauthenticated way to have hit that crash.
 */
describe("a null JSON body on gallery mutation routes", () => {
  it.each([
    {
      label: "PUT .../heart",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/heart`,
    },
    {
      label: "PUT .../raw-request",
      method: "PUT",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`,
    },
    {
      label: "POST .../comments",
      method: "POST",
      path: `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/comments`,
    },
  ])("rejects $label with 400, not 500", async ({ method, path }) => {
    await seedGallery("ready");

    const result = await galleryRequest(method, path, {
      json: null,
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expectError(result, 400, "The request body must be valid JSON.");
  });
});

describe("PUT/DELETE .../raw-request", () => {
  const RAW_REQUEST_PATH = `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`;

  it("404s when the event has not opted in to RAW requests", async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      status: "ready",
      rawRequestsEnabled: false,
    });
    await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });

    const result = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest", email: GUEST_EMAIL },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expectError(result, 404, "RAW requests are not enabled for this gallery.");
  });

  it("is idempotent and can be undone once enabled", async () => {
    await seedGallery("ready");
    /*
     * Seeded rather than requested, so this test stays about idempotency. The
     * row makes the address already-confirmed for the event, which is the state
     * a viewer is in from their second request onwards.
     */
    await insertRawRequest({
      photoId: OTHER_PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: GUEST_EMAIL,
    });

    const first = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest", email: GUEST_EMAIL },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(first.body).toEqual({
      requested: true,
      confirmationPending: false,
      email: GUEST_EMAIL,
      rawDownload: null,
      rawDownloadedAt: null,
    });

    const second = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest", email: GUEST_EMAIL },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(second.body).toEqual({
      requested: true,
      confirmationPending: false,
      email: GUEST_EMAIL,
      rawDownload: null,
      rawDownloadedAt: null,
    });

    const removed = await galleryRequest("DELETE", RAW_REQUEST_PATH, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(removed.body).toEqual({ requested: false });
  });

  /*
   * The bug #210 left behind. The RAW object is per photo, so a second visitor
   * asking for one that has already been delivered has nothing to wait for --
   * but the insert always wrote fulfilled_at NULL, which left listPhotos
   * reporting a pending request the iPad could never satisfy and the visitor
   * with a download that could never arrive.
   */
  it("fulfils a request immediately when the RAW is already delivered", async () => {
    await seedGallery("ready");
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });
    await insertRawRequest({
      photoId: OTHER_PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: "visitor-token-for-second-guest",
      email: "second@example.com",
    });

    const result = await galleryRequest<{
      requested: boolean;
      rawDownload: { filename: string; byteSize: number } | null;
    }>("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Second guest", email: "second@example.com" },
      headers: { "X-PickPic-Visitor": "visitor-token-for-second-guest" },
    });

    expect(result.body.requested).toBe(true);
    expect(result.body.rawDownload).toMatchObject({
      filename: "DSC01015.ARW",
      byteSize: 8,
    });
  });

  /*
   * Withdrawing after the RAW has landed is the one path that can leave the
   * object with nobody left to serve it -- the row is DELETEd outright, so
   * without a reclaim here the bytes would sit against the account's cap with
   * no request anywhere pointing at them.
   */
  it("reclaims the RAW when the last requester withdraws after delivery", async () => {
    await seedGallery("ready");
    const storageKey = await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
    });
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt: new Date().toISOString(),
    });

    const removed = await galleryRequest("DELETE", RAW_REQUEST_PATH, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(removed.body).toEqual({ requested: false });

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.rawStorageKey).toBeNull();
    expect(state.rawUploadedAt).toBeNull();
    expect(state.objectExists).toBe(false);
    expect(state.accountStorageBytes).toBe(0);
  });

  it("keeps the RAW when one of two requesters withdraws", async () => {
    await seedGallery("ready");
    const storageKey = await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
    });

    for (const visitorToken of [VISITOR_TOKEN, "visitor-token-for-the-other"]) {
      await insertRawRequest({
        photoId: PHOTO_ID,
        eventId: EVENT_ID,
        visitorToken,
        fulfilledAt: new Date().toISOString(),
      });
    }

    await galleryRequest("DELETE", RAW_REQUEST_PATH, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.rawStorageKey).toBe(storageKey);
    expect(state.objectExists).toBe(true);
  });

  /*
   * #225: the TTL half of isRawReclaimable now reads the account's own
   * raw_delivery_ttl_ms rather than a fixed constant, and it is checked
   * unconditionally ahead of the awaiting-requester veto -- so an account that
   * has lowered its retention reclaims a RAW even with a second live,
   * uncollected requester still attached, which the default-TTL sibling test
   * above ("keeps the RAW when one of two requesters withdraws") shows does
   * *not* happen at the 14-day default.
   */
  it("reclaims despite a second live requester once the account's shorter TTL has passed", async () => {
    await seedGallery("ready");
    const storageKey = await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
    });

    const dayMs = 24 * 60 * 60 * 1000;
    const previousTtlMs = await setRawDeliveryTtlMs(3 * dayMs);
    const oldFulfilledAt = new Date(Date.now() - 4 * dayMs).toISOString();

    for (const visitorToken of [VISITOR_TOKEN, "visitor-token-for-the-other"]) {
      await insertRawRequest({
        photoId: PHOTO_ID,
        eventId: EVENT_ID,
        visitorToken,
        fulfilledAt: oldFulfilledAt,
      });
    }

    try {
      await galleryRequest("DELETE", RAW_REQUEST_PATH, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      });

      const state = await readRawPhotoState(PHOTO_ID, storageKey);
      expect(state.rawStorageKey).toBeNull();
      expect(state.objectExists).toBe(false);
    } finally {
      await setRawDeliveryTtlMs(previousTtlMs);
    }
  });

  /*
   * "Ask again" after the RAW has been reclaimed. The row already exists, so
   * this has to go through the ON CONFLICT arm -- and it has to clear the
   * notification lease as well, or notifyRawRequested's early return on a
   * 'sent' row means the photographer never hears that it is wanted again.
   */
  it("re-arms a collected request once the RAW has been reclaimed", async () => {
    await seedGallery("ready");
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt: "2026-01-01T00:00:00.000Z",
      downloadedAt: "2026-01-02T00:00:00.000Z",
      email: GUEST_EMAIL,
      downloadTokenHash: "hash-of-the-link-already-emailed",
    });

    const result = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest", email: GUEST_EMAIL },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expect(result.body).toEqual({
      requested: true,
      confirmationPending: false,
      email: GUEST_EMAIL,
      rawDownload: null,
      rawDownloadedAt: null,
    });

    const row = await env.DB.prepare(
      `
        SELECT
          r.fulfilled_at AS fulfilledAt,
          r.downloaded_at AS downloadedAt,
          r.download_token_hash AS downloadTokenHash,
          r.notification_status AS notificationStatus
        FROM raw_requests r
        WHERE r.photo_id = ?
      `,
    )
      .bind(PHOTO_ID)
      .first<{
        fulfilledAt: string | null;
        downloadedAt: string | null;
        downloadTokenHash: string | null;
        notificationStatus: string;
      }>();

    /*
     * The token has to go with the rest of it. The link in the previous
     * delivery email described a copy that has since been reclaimed, and
     * leaving the hash standing would make that old mail a live credential
     * again the moment the replacement RAW lands.
     */
    expect(row).toMatchObject({
      fulfilledAt: null,
      downloadedAt: null,
      downloadTokenHash: null,
      notificationStatus: "pending",
    });
  });
});
