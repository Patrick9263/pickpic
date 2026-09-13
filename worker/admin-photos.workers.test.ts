import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertHeart,
  insertPhoto,
  insertRawRequest,
  readRawPhotoState,
  setAccountStorageCap,
  testSha256,
} from "./test-fixtures.ts";
import {
  adminRequest,
  expectError,
  expectMethodNotAllowed,
} from "./test-request.ts";

interface PhotoListBody {
  photos: {
    id: string;
    heartCount: number;
    pendingRawRequestCount: number;
    awaitingCollectionCount: number;
    rawPhoto: {
      originalFilename: string;
      contentType: string;
      byteSize: number;
      uploadedAt: string;
    } | null;
  }[];
}

interface RawUploadBody {
  photoId: string;
  pendingRawRequestCount: number;
  rawPhoto: { originalFilename: string; byteSize: number } | null;
}

const RAW_HEADERS = {
  "Content-Type": "application/octet-stream",
  "X-File-Name": "DSC01015.ARW",
  "X-File-SHA256": testSha256("raw"),
};

function photoById(body: PhotoListBody, id: string) {
  const photo = body.photos.find((candidate) => candidate.id === id);

  if (!photo) {
    throw new Error(`The list response is missing ${id}.`);
  }

  return photo;
}

const EVENT_ID = "event-photos";

beforeEach(async () => {
  await clearTestData();
  await insertEvent({ id: EVENT_ID, shareToken: "share-photos" });
});

describe("GET /api/admin/events/:id/photos", () => {
  it("lists the event's photos", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });
    await insertPhoto({ id: "photo-b", eventId: EVENT_ID });

    const result = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(result.status).toBe(200);
    expect(result.body.photos.map((photo) => photo.id).sort()).toEqual([
      "photo-a",
      "photo-b",
    ]);
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "GET",
      "/api/admin/events/no-such-event/photos",
    );

    expectError(result, 404, "Event not found.");
  });

  it("counts pending RAW requests without disturbing heartCount", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });

    await insertHeart({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-one____",
    });

    await insertHeart({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-two____",
    });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-one____",
    });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-two____",
    });

    const result = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    const photo = photoById(result.body, "photo-a");

    /*
     * The regression the correlated subquery exists to prevent: joining
     * raw_requests beside hearts would report 4 hearts here, not 2.
     */
    expect(photo.heartCount).toBe(2);
    expect(photo.pendingRawRequestCount).toBe(2);
    expect(photo.rawPhoto).toBeNull();
  });

  it("stops counting a RAW request once it has been fulfilled", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-one____",
      fulfilledAt: "2026-09-09T00:00:00.000Z",
    });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-two____",
    });

    const result = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(photoById(result.body, "photo-a").pendingRawRequestCount).toBe(1);
  });

  it("counts a fulfilled request as awaiting collection until it is downloaded", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-one____",
      fulfilledAt: "2026-09-09T00:00:00.000Z",
    });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-two____",
      fulfilledAt: "2026-09-09T00:00:00.000Z",
      downloadedAt: "2026-09-09T01:00:00.000Z",
    });

    const result = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(photoById(result.body, "photo-a").awaitingCollectionCount).toBe(1);
  });

  it("reports a photo with no RAW requests as zero rather than absent", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });

    const result = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(photoById(result.body, "photo-a").pendingRawRequestCount).toBe(0);
  });
});

describe("PUT /api/admin/photos/:id/raw", () => {
  beforeEach(async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });
  });

  it("stores the RAW and fulfils every pending request for the photo", async () => {
    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-one____",
    });

    await insertRawRequest({
      photoId: "photo-a",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-two____",
    });

    const result = await adminRequest<RawUploadBody>(
      "PUT",
      "/api/admin/photos/photo-a/raw",
      { body: new Uint8Array(2048), headers: RAW_HEADERS },
    );

    expect(result.status).toBe(200);
    expect(result.body.rawPhoto).toMatchObject({
      originalFilename: "DSC01015.ARW",
      byteSize: 2048,
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
      .bind("photo-a")
      .first<{ rawStorageKey: string | null; rawByteSize: number | null }>();

    expect(stored?.rawByteSize).toBe(2048);
    expect(stored?.rawStorageKey).toContain(
      `events/${EVENT_ID}/photos/photo-a/raw/`,
    );

    const object = await env.pickpic_photos.get(stored?.rawStorageKey ?? "");
    expect(object?.size).toBe(2048);

    const pending = await env.DB.prepare(
      `
        SELECT COUNT(*) AS count
        FROM raw_requests
        WHERE
          photo_id = ?
          AND fulfilled_at IS NULL
      `,
    )
      .bind("photo-a")
      .first<{ count: number }>();

    /*
     * Both, not just one: a photo has a single original, so delivering it
     * satisfies everyone who asked.
     */
    expect(pending?.count).toBe(0);
  });

  it("counts the delivered RAW against the account's storage", async () => {
    await adminRequest("PUT", "/api/admin/photos/photo-a/raw", {
      body: new Uint8Array(4096),
      headers: RAW_HEADERS,
    });

    const account = await env.DB.prepare(
      `
        SELECT storage_bytes AS storageBytes
        FROM accounts
        WHERE id = (SELECT account_id FROM photos WHERE id = ?)
      `,
    )
      .bind("photo-a")
      .first<{ storageBytes: number }>();

    expect(account?.storageBytes).toBe(4096);
  });

  it("rejects a declared size over the RAW limit", async () => {
    const result = await adminRequest("PUT", "/api/admin/photos/photo-a/raw", {
      body: new Uint8Array(16),
      headers: {
        ...RAW_HEADERS,
        "Content-Length": String(101 * 1024 * 1024),
      },
    });

    expectError(result, 413, "The RAW file must be 100 MB or smaller.");
  });

  it("rejects a RAW that would take the account over its cap", async () => {
    const previousCap = await setAccountStorageCap(1024);

    try {
      const result = await adminRequest(
        "PUT",
        "/api/admin/photos/photo-a/raw",
        { body: new Uint8Array(4096), headers: RAW_HEADERS },
      );

      expectError(
        result,
        403,
        "This account's storage limit has been reached.",
      );

      const stored = await env.DB.prepare(
        `
          SELECT raw_storage_key AS rawStorageKey
          FROM photos
          WHERE id = ?
        `,
      )
        .bind("photo-a")
        .first<{ rawStorageKey: string | null }>();

      expect(stored?.rawStorageKey).toBeNull();
    } finally {
      await setAccountStorageCap(previousCap);
    }
  });

  it("rejects a body that isn't sent as opaque bytes", async () => {
    const result = await adminRequest("PUT", "/api/admin/photos/photo-a/raw", {
      body: new Uint8Array(16),
      headers: { ...RAW_HEADERS, "Content-Type": "image/jpeg" },
    });

    expectError(result, 415);
  });

  it("404s for a photo that doesn't exist", async () => {
    const result = await adminRequest(
      "PUT",
      "/api/admin/photos/no-such-photo/raw",
      { body: new Uint8Array(16), headers: RAW_HEADERS },
    );

    expectError(result, 404, "Photo not found.");
  });

  it("405s on a non-PUT method", async () => {
    expectMethodNotAllowed(
      await adminRequest("GET", "/api/admin/photos/photo-a/raw"),
    );
  });
});

describe("DELETE /api/admin/events/:id/photos", () => {
  it("deletes every photo on the event and reports the count", async () => {
    await insertPhoto({ id: "photo-a", eventId: EVENT_ID });
    await insertPhoto({ id: "photo-b", eventId: EVENT_ID });

    const result = await adminRequest<{
      eventId: string;
      deletedPhotoCount: number;
    }>("DELETE", `/api/admin/events/${EVENT_ID}/photos`);

    expect(result.status).toBe(200);
    expect(result.body.deletedPhotoCount).toBe(2);

    const listed = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(listed.body.photos).toEqual([]);
  });

  it("reports zero deleted when the event has no photos", async () => {
    const result = await adminRequest<{ deletedPhotoCount: number }>(
      "DELETE",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(result.status).toBe(200);
    expect(result.body.deletedPhotoCount).toBe(0);
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "DELETE",
      "/api/admin/events/no-such-event/photos",
    );

    expectError(result, 404, "Event not found.");
  });

  it("405s on a non-GET/POST/DELETE method", async () => {
    const result = await adminRequest(
      "PATCH",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expectMethodNotAllowed(result);
  });
});

describe("DELETE /api/admin/photos/:id", () => {
  it("deletes a single photo", async () => {
    await insertPhoto({ id: "photo-solo", eventId: EVENT_ID });

    const result = await adminRequest<{ deletedPhotoId: string }>(
      "DELETE",
      "/api/admin/photos/photo-solo",
    );

    expect(result.status).toBe(200);
    expect(result.body.deletedPhotoId).toBe("photo-solo");

    const listed = await adminRequest<PhotoListBody>(
      "GET",
      `/api/admin/events/${EVENT_ID}/photos`,
    );

    expect(listed.body.photos).toEqual([]);
  });

  it("404s for a photo that doesn't exist", async () => {
    const result = await adminRequest(
      "DELETE",
      "/api/admin/photos/no-such-photo",
    );

    expectError(result, 404, "Photo not found.");
  });

  it("405s on a non-DELETE method", async () => {
    await insertPhoto({ id: "photo-solo", eventId: EVENT_ID });

    const result = await adminRequest("GET", "/api/admin/photos/photo-solo");

    expectMethodNotAllowed(result);
  });
});

describe("DELETE /api/admin/photos/:id/raw-requests", () => {
  interface CancelBody {
    photoId: string;
    cancelledRequestCount: number;
  }

  function agoIso(milliseconds: number): string {
    return new Date(Date.now() - milliseconds).toISOString();
  }

  it("cancels an undownloaded delivery and frees its bytes in the same request", async () => {
    await insertPhoto({ id: "photo-undelivered", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-undelivered",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-undelivered",
      eventId: EVENT_ID,
      visitorToken: "visitor-undelivered___",
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<CancelBody>(
      "DELETE",
      "/api/admin/photos/photo-undelivered/raw-requests",
    );

    expect(result.status).toBe(200);
    expect(result.body).toEqual({
      photoId: "photo-undelivered",
      cancelledRequestCount: 1,
    });

    const state = await readRawPhotoState("photo-undelivered", storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();

    const remaining = await env.DB.prepare(
      `
        SELECT COUNT(*) AS count
        FROM raw_requests
        WHERE photo_id = ?
      `,
    )
      .bind("photo-undelivered")
      .first<{ count: number }>();

    expect(remaining?.count).toBe(0);
  });

  /*
   * Cancelling an unfulfilled request would be declining it outright, which
   * is a different action this route doesn't cover -- only a delivery that
   * has actually landed can be cancelled.
   */
  it("leaves an unfulfilled request alone", async () => {
    await insertPhoto({ id: "photo-unfulfilled", eventId: EVENT_ID });

    await insertRawRequest({
      photoId: "photo-unfulfilled",
      eventId: EVENT_ID,
      visitorToken: "visitor-unfulfilled__",
    });

    const result = await adminRequest<CancelBody>(
      "DELETE",
      "/api/admin/photos/photo-unfulfilled/raw-requests",
    );

    expect(result.body.cancelledRequestCount).toBe(0);

    const remaining = await env.DB.prepare(
      `
        SELECT COUNT(*) AS count
        FROM raw_requests
        WHERE photo_id = ?
      `,
    )
      .bind("photo-unfulfilled")
      .first<{ count: number }>();

    expect(remaining?.count).toBe(1);
  });

  /*
   * Releasing (#219) already covers a request somebody has collected --
   * cancelling must not reach past it and take back a download that already
   * succeeded.
   */
  it("leaves an already-downloaded request alone", async () => {
    await insertPhoto({ id: "photo-downloaded", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-downloaded",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-downloaded",
      eventId: EVENT_ID,
      visitorToken: "visitor-downloaded___",
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });

    const result = await adminRequest<CancelBody>(
      "DELETE",
      "/api/admin/photos/photo-downloaded/raw-requests",
    );

    expect(result.body.cancelledRequestCount).toBe(0);
    expect(
      (await readRawPhotoState("photo-downloaded", storageKey)).objectExists,
    ).toBe(true);
  });

  /*
   * One visitor already has the file and is inside their release/grace
   * window; a second visitor's stale, uncollected request must not be able
   * to pull the object out from under them.
   */
  it("keeps the RAW while another requester still has a live, collected request", async () => {
    await insertPhoto({ id: "photo-two-visitors", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
      visitorToken: "visitor-collected____",
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });
    await insertRawRequest({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
      visitorToken: "visitor-uncollected__",
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<CancelBody>(
      "DELETE",
      "/api/admin/photos/photo-two-visitors/raw-requests",
    );

    expect(result.body.cancelledRequestCount).toBe(1);
    expect(
      (await readRawPhotoState("photo-two-visitors", storageKey)).objectExists,
    ).toBe(true);

    const remaining = await env.DB.prepare(
      `
        SELECT visitor_id AS visitorId
        FROM raw_requests
        WHERE photo_id = ?
      `,
    )
      .bind("photo-two-visitors")
      .all<{ visitorId: string }>();

    expect(remaining.results).toHaveLength(1);
  });

  it("404s for a photo that doesn't exist", async () => {
    const result = await adminRequest(
      "DELETE",
      "/api/admin/photos/no-such-photo/raw-requests",
    );

    expectError(result, 404, "Photo not found.");
  });

  it("405s on a non-DELETE method", async () => {
    await insertPhoto({ id: "photo-solo", eventId: EVENT_ID });

    const result = await adminRequest(
      "GET",
      "/api/admin/photos/photo-solo/raw-requests",
    );

    expectMethodNotAllowed(result);
  });
});
