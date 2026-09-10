import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertPhoto,
  insertRawRequest,
  readRawPhotoState,
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
const SHARE_TOKEN = "share-guard";
const VISITOR_TOKEN = "visitor-token-for-guard-tests";

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
      json: { displayName: "Guest" },
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
      json: { displayName: "Guest" },
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
      json: { displayName: "Guest" },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expectError(result, 404, "RAW requests are not enabled for this gallery.");
  });

  it("is idempotent and can be undone once enabled", async () => {
    await seedGallery("ready");

    const first = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest" },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(first.body).toEqual({
      requested: true,
      rawDownload: null,
      rawDownloadedAt: null,
    });

    const second = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest" },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    expect(second.body).toEqual({
      requested: true,
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

    const result = await galleryRequest<{
      requested: boolean;
      rawDownload: { filename: string; byteSize: number } | null;
    }>("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Second guest" },
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
    });

    const result = await galleryRequest("PUT", RAW_REQUEST_PATH, {
      json: { displayName: "Guest" },
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expect(result.body).toEqual({
      requested: true,
      rawDownload: null,
      rawDownloadedAt: null,
    });

    const row = await env.DB.prepare(
      `
        SELECT
          r.fulfilled_at AS fulfilledAt,
          r.downloaded_at AS downloadedAt,
          r.notification_status AS notificationStatus
        FROM raw_requests r
        WHERE r.photo_id = ?
      `,
    )
      .bind(PHOTO_ID)
      .first<{
        fulfilledAt: string | null;
        downloadedAt: string | null;
        notificationStatus: string;
      }>();

    expect(row).toMatchObject({
      fulfilledAt: null,
      downloadedAt: null,
      notificationStatus: "pending",
    });
  });
});
