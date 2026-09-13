import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "./index.ts";
import {
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertHeart,
  insertPhoto,
  insertRawRequest,
  readRawPhotoState,
} from "./test-fixtures.ts";
import {
  adminRequest,
  expectError,
  expectMethodNotAllowed,
  galleryRequest,
} from "./test-request.ts";

/*
 * The public gallery read, driven through the worker's own fetch handler so the
 * routing chain in routeRequest is part of what is under test -- ordering
 * mistakes in that chain are how a closed gallery kept accepting hearts once
 * before.
 */

/*
 * An exported handler is typed against an *incoming* request, which carries a
 * populated `cf` object a plain `new Request()` does not. This instantiation
 * expression is Cloudflare's documented way to get a constructor with that
 * signature; it is a type-level narrowing only, with no runtime effect.
 */
const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

const ORIGIN = "https://pickpic.photos";
const EVENT_ID = "event-gallery";
const SHARE_TOKEN = "share-gallery";
const VISITOR_TOKEN = "visitor-token-for-tests";
const PHOTO_ID = "photo-raw-delivery";

async function fetchGallery(
  shareToken: string,
  init?: RequestInit<IncomingRequestCfProperties>,
): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new IncomingRequest(
      `${ORIGIN}/api/galleries/${encodeURIComponent(shareToken)}`,
      init,
    ),
    env,
    ctx,
  );

  await waitOnExecutionContext(ctx);

  return response;
}

beforeEach(async () => {
  await clearTestData();
});

describe("GET /api/galleries/:shareToken", () => {
  it("404s on an unknown share token", async () => {
    const response = await fetchGallery("no-such-token");

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({
      error: "Gallery not found.",
    });
  });

  /*
   * The status gate is the whole of the gallery's access control: a share token
   * is permanent, so `draft` and `archived` answering 404 is what keeps an
   * unfinished shoot private and makes archiving actually withdraw a gallery
   * rather than only hiding its link.
   */
  it.each(["draft", "archived"])(
    "404s while the event is %s",
    async (status) => {
      await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN, status });

      const response = await fetchGallery(SHARE_TOKEN);

      expect(response.status).toBe(404);
    },
  );

  it.each(["ready", "completed"])("serves a %s gallery", async (status) => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      status,
      title: "Harbour wedding",
    });

    const response = await fetchGallery(SHARE_TOKEN);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      event: { title: "Harbour wedding", status },
      photos: [],
    });
  });

  it("orders photos by capture time and counts hearts", async () => {
    await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });

    /* Inserted out of order so a pass would have to come from the ORDER BY. */
    await insertPhoto({
      id: "photo-late",
      eventId: EVENT_ID,
      capturedAt: "2026-08-01T12:30:00",
    });
    await insertPhoto({
      id: "photo-early",
      eventId: EVENT_ID,
      capturedAt: "2026-08-01T09:15:00",
    });

    await insertHeart({
      photoId: "photo-early",
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
    });

    const response = await fetchGallery(SHARE_TOKEN);
    const body = (await response.json()) as {
      photos: { id: string; heartCount: number; imageUrl: string }[];
    };

    expect(body.photos.map((photo) => photo.id)).toEqual([
      "photo-early",
      "photo-late",
    ]);
    expect(body.photos[0].heartCount).toBe(1);
    expect(body.photos[1].heartCount).toBe(0);
    expect(body.photos[0].imageUrl).toBe(
      `/api/galleries/${SHARE_TOKEN}/photos/photo-early/image`,
    );
  });

  /*
   * Exact coordinates identify a private venue, so the public response rounds
   * them while the dashboard keeps the stored values. Asserting it here rather
   * than only on roundPublicCoordinate covers the wiring, which is the half that
   * can silently be dropped.
   */
  it("rounds coordinates for public viewers", async () => {
    await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });
    await insertPhoto({
      id: "photo-located",
      eventId: EVENT_ID,
      latitude: 40.712776,
      longitude: -74.005974,
    });

    const response = await fetchGallery(SHARE_TOKEN);
    const body = (await response.json()) as {
      photos: { latitude: number; longitude: number }[];
    };

    expect(body.photos[0].latitude).toBe(40.71);
    expect(body.photos[0].longitude).toBe(-74.01);
  });

  it("reports the viewer's own hearts only for their visitor token", async () => {
    await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });
    await insertPhoto({ id: "photo-hearted", eventId: EVENT_ID });
    await insertHeart({
      photoId: "photo-hearted",
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
    });

    const asVisitor = (await (
      await fetchGallery(SHARE_TOKEN, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      })
    ).json()) as { photos: { viewerHearted: boolean }[] };

    const asStranger = (await (await fetchGallery(SHARE_TOKEN)).json()) as {
      photos: { viewerHearted: boolean; heartCount: number }[];
    };

    expect(asVisitor.photos[0].viewerHearted).toBe(true);
    expect(asStranger.photos[0].viewerHearted).toBe(false);
    expect(asStranger.photos[0].heartCount).toBe(1);
  });

  it("omits rawRequestsEnabled photos and viewerRequestedRaw when the event has not opted in", async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: false,
    });
    await insertPhoto({ id: "photo-plain", eventId: EVENT_ID });

    const response = await fetchGallery(SHARE_TOKEN, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });
    const body = (await response.json()) as {
      event: { rawRequestsEnabled: boolean };
      photos: { viewerRequestedRaw: boolean }[];
    };

    expect(body.event.rawRequestsEnabled).toBe(false);
    expect(body.photos[0].viewerRequestedRaw).toBe(false);
  });

  it("reports the viewer's own RAW requests only for their visitor token, when enabled", async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: "photo-raw-requested", eventId: EVENT_ID });
    await insertRawRequest({
      photoId: "photo-raw-requested",
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
    });

    const asVisitor = (await (
      await fetchGallery(SHARE_TOKEN, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      })
    ).json()) as {
      event: { rawRequestsEnabled: boolean };
      photos: { viewerRequestedRaw: boolean }[];
    };

    const asStranger = (await (await fetchGallery(SHARE_TOKEN)).json()) as {
      photos: { viewerRequestedRaw: boolean }[];
    };

    expect(asVisitor.event.rawRequestsEnabled).toBe(true);
    expect(asVisitor.photos[0].viewerRequestedRaw).toBe(true);
    expect(asStranger.photos[0].viewerRequestedRaw).toBe(false);
  });

  /*
   * #237: disabling RAW requests must stop new asks (addRawRequest's own
   * gate), not blind a visitor to a request they already made. Before the
   * fix, the whole per-visitor raw_requests query was skipped once the event
   * flag went false, so this visitor's fulfilled download would have vanished
   * from the response along with it.
   */
  it("keeps reporting a visitor's own RAW request after the event disables new requests", async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt: "2026-02-01T00:00:00.000Z",
    });

    /*
     * A direct UPDATE rather than a second insertEvent call, which would
     * violate the primary key -- this is meant to simulate the photographer
     * flipping the dashboard toggle on an event that already has state.
     */
    await env.DB.prepare(
      "UPDATE events SET raw_requests_enabled = 0 WHERE id = ?",
    )
      .bind(EVENT_ID)
      .run();

    const body = (await (
      await fetchGallery(SHARE_TOKEN, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      })
    ).json()) as {
      event: { rawRequestsEnabled: boolean };
      photos: {
        viewerRequestedRaw: boolean;
        viewerRawDownload: { filename: string } | null;
      }[];
    };

    expect(body.event.rawRequestsEnabled).toBe(false);
    expect(body.photos[0].viewerRequestedRaw).toBe(true);
    expect(body.photos[0].viewerRawDownload).toMatchObject({
      filename: "DSC01015.ARW",
    });
  });

  it("405s on a non-GET method", async () => {
    await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });

    const response = await fetchGallery(SHARE_TOKEN, { method: "DELETE" });

    expect(response.status).toBe(405);
  });

  it("exposes the RAW download only to the visitor whose request was fulfilled", async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt: "2026-02-01T00:00:00.000Z",
    });

    /*
     * A second visitor who asked but whose request has not been stamped
     * fulfilled is the case that proves this is read per request rather than
     * per photo: the object is right there, and they still must not see a
     * download.
     */
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: "visitor-token-still-waiting",
    });

    const asRequester = (await (
      await fetchGallery(SHARE_TOKEN, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      })
    ).json()) as {
      photos: {
        viewerRawDownload: { filename: string; byteSize: number } | null;
        viewerRawDownloadedAt: string | null;
      }[];
    };

    const asWaiter = (await (
      await fetchGallery(SHARE_TOKEN, {
        headers: { "X-PickPic-Visitor": "visitor-token-still-waiting" },
      })
    ).json()) as { photos: { viewerRawDownload: unknown }[] };

    const asStranger = (await (await fetchGallery(SHARE_TOKEN)).json()) as {
      photos: { viewerRawDownload: unknown; viewerRawDownloadedAt: unknown }[];
    };

    expect(asRequester.photos[0].viewerRawDownload).toMatchObject({
      filename: "DSC01015.ARW",
      byteSize: 8,
    });
    expect(asRequester.photos[0].viewerRawDownloadedAt).toBeNull();
    expect(asWaiter.photos[0].viewerRawDownload).toBeNull();
    expect(asStranger.photos[0].viewerRawDownload).toBeNull();
    expect(asStranger.photos[0].viewerRawDownloadedAt).toBeNull();
  });
});

describe("GET /api/galleries/:shareToken/photos/:photoId/raw", () => {
  const RAW_PATH = `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw`;

  /*
   * Drives this one route directly instead of through galleryRequest, because
   * the downloaded_at stamp now rides on a waitUntil that only settles once
   * the body has drained (see getGalleryRawPhoto). The shared helper awaits
   * waitOnExecutionContext before the caller can touch the response, so there
   * is no reader attached when the stamp is being waited on -- fine for eight
   * bytes, a deadlock for anything past the stream's internal buffer. Reading
   * or cancelling first is the order this route actually needs, and it is also
   * how a real client behaves.
   */
  async function driveRawDownload(
    consume: (response: Response) => Promise<unknown>,
    visitorToken: string = VISITOR_TOKEN,
  ): Promise<Response> {
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new IncomingRequest(`${ORIGIN}${RAW_PATH}`, {
        headers: { "X-PickPic-Visitor": visitorToken },
      }),
      env,
      ctx,
    );

    await consume(response);
    await waitOnExecutionContext(ctx);

    return response;
  }

  async function readDownloadedAt(): Promise<string | null> {
    const row = await env.DB.prepare(
      "SELECT downloaded_at AS downloadedAt FROM raw_requests WHERE photo_id = ?",
    )
      .bind(PHOTO_ID)
      .first<{ downloadedAt: string | null }>();

    return row?.downloadedAt ?? null;
  }

  async function seedDeliveredRaw(options?: {
    status?: string;
    fulfilled?: boolean;
    bytes?: Uint8Array;
  }): Promise<string> {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      status: options?.status ?? "ready",
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
      bytes: options?.bytes,
    });

    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt:
        options?.fulfilled === false ? undefined : new Date().toISOString(),
    });

    return storageKey;
  }

  it("serves the RAW to its requester as an uncacheable attachment", async () => {
    await seedDeliveredRaw();

    const response = await driveRawDownload(async (streaming) => {
      expect(new Uint8Array(await streaming.arrayBuffer())).toEqual(
        new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]),
      );
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe(
      "application/octet-stream",
    );
    expect(response.headers.get("Content-Disposition")).toContain(
      'attachment; filename="DSC01015.ARW"',
    );

    /*
     * The whole reason this route does not reuse getStoredJpeg. A year of
     * immutable edge caching would keep a private original retrievable long
     * after the reclaim deleted it, and would defeat the reclaim itself.
     */
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Accept-Ranges")).toBeNull();
  });

  it("stamps downloaded_at once the body has been collected", async () => {
    const storageKey = await seedDeliveredRaw();

    await driveRawDownload((response) => response.arrayBuffer());

    expect(await readDownloadedAt()).not.toBeNull();

    /*
     * The grace period, asserted directly: a download that died halfway has
     * to stay retryable, so serving it must not delete the object.
     */
    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(true);
    expect(state.rawStorageKey).toBe(storageKey);
  });

  /*
   * The #239 case, and the reason the stamp moved off the start of the
   * request: a transfer that dies partway must not read as collected, because
   * #220's per-event release deletes on exactly that reading with no grace
   * period behind it.
   */
  it("leaves downloaded_at unstamped when the transfer is abandoned", async () => {
    /*
     * Deliberately larger than the response stream's internal buffer. A
     * payload small enough to sit in it whole would drain with no reader
     * attached, and the cancel below would land after the stamp rather than
     * instead of it -- the test would pass for the wrong reason, or flake.
     */
    const storageKey = await seedDeliveredRaw({
      bytes: new Uint8Array(512 * 1024),
    });

    const response = await driveRawDownload((streaming) =>
      streaming.body!.cancel(),
    );

    /*
     * Pinned so the assertion below cannot pass because the route refused the
     * request -- an unstamped 404 would look identical.
     */
    expect(response.status).toBe(200);
    expect(await readDownloadedAt()).toBeNull();

    /* And the bytes are still there for the retry. */
    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(true);
  });

  it("stays available on a completed gallery", async () => {
    await seedDeliveredRaw({ status: "completed" });

    const response = await driveRawDownload((streaming) =>
      streaming.arrayBuffer(),
    );

    expect(response.status).toBe(200);
  });

  it("404s once the gallery is archived", async () => {
    await seedDeliveredRaw({ status: "archived" });

    const result = await galleryRequest("GET", RAW_PATH, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expectError(result, 404, "Photo not found.");
  });

  it("404s for a visitor who never requested it", async () => {
    await seedDeliveredRaw();

    const result = await galleryRequest("GET", RAW_PATH, {
      headers: { "X-PickPic-Visitor": "visitor-token-for-a-stranger" },
    });

    expectError(result, 404, "This RAW file is not available to download.");
  });

  it("404s for a requester whose own request is not fulfilled", async () => {
    await seedDeliveredRaw({ fulfilled: false });

    const result = await galleryRequest("GET", RAW_PATH, {
      headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
    });

    expectError(result, 404, "This RAW file is not available to download.");
  });

  /*
   * #237: the toggle only governs whether a *new* request can be created.
   * Before the fix this route also 404d an already-fulfilled request the
   * moment the event's flag went false, stranding a viewer mid-delivery with
   * no way to collect bytes the iPad had already sent.
   */
  it("stays downloadable for a fulfilled requester after the event disables new requests", async () => {
    await seedDeliveredRaw();

    await env.DB.prepare(
      "UPDATE events SET raw_requests_enabled = 0 WHERE id = ?",
    )
      .bind(EVENT_ID)
      .run();

    const response = await driveRawDownload((streaming) =>
      streaming.arrayBuffer(),
    );

    expect(response.status).toBe(200);
  });

  it("400s without a visitor token", async () => {
    await seedDeliveredRaw();

    const result = await galleryRequest("GET", RAW_PATH);

    expectError(result, 400, "A valid visitor token is required.");
  });

  it("405s on a non-GET method", async () => {
    await seedDeliveredRaw();

    expectMethodNotAllowed(
      await galleryRequest("DELETE", RAW_PATH, {
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      }),
    );
  });
});

/*
 * The reclaim policy end to end. These drive the iPad's own photo poll,
 * because that is the only heartbeat the TTL half of the policy has -- there
 * is no cron in this project, so a sweep that stopped running here would leave
 * abandoned RAWs in R2 with nothing left to notice.
 */
describe("reclaiming a delivered RAW", () => {
  const PHOTOS_PATH = `/api/admin/events/${EVENT_ID}/photos`;
  const ONE_DAY_MS = 24 * 60 * 60 * 1000;

  function agoIso(milliseconds: number): string {
    return new Date(Date.now() - milliseconds).toISOString();
  }

  async function seedForSweep(request: {
    fulfilledAt: string;
    downloadedAt?: string;
    releasedAt?: string;
  }): Promise<string> {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: PHOTO_ID, eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      fulfilledAt: request.fulfilledAt,
      downloadedAt: request.downloadedAt,
      releasedAt: request.releasedAt,
    });

    return storageKey;
  }

  it("keeps a collected RAW inside the grace period", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(2 * ONE_DAY_MS),
      downloadedAt: agoIso(ONE_DAY_MS / 2),
    });

    await adminRequest("GET", PHOTOS_PATH);

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(true);
    expect(state.rawStorageKey).toBe(storageKey);
  });

  it("reclaims a collected RAW once the grace period has passed", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(3 * ONE_DAY_MS),
      downloadedAt: agoIso(2 * ONE_DAY_MS),
    });

    await adminRequest("GET", PHOTOS_PATH);

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
    expect(state.rawUploadedAt).toBeNull();
    expect(state.accountStorageBytes).toBe(0);
  });

  /*
   * The abandoned requester -- the case a download-only policy cannot bound.
   * Nobody has collected this and nobody ever will, so only the TTL frees it.
   */
  it("reclaims an uncollected RAW once its TTL has elapsed", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(15 * ONE_DAY_MS),
    });

    await adminRequest("GET", PHOTOS_PATH);

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
    expect(state.accountStorageBytes).toBe(0);
  });

  it("keeps an uncollected RAW while its TTL is still running", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(13 * ONE_DAY_MS),
    });

    await adminRequest("GET", PHOTOS_PATH);

    expect((await readRawPhotoState(PHOTO_ID, storageKey)).objectExists).toBe(
      true,
    );
  });

  /*
   * The manual release (#219). Same seed as "keeps a collected RAW inside the
   * grace period" above, minute-old download and all -- the only difference is
   * the marker, so a pass here can only come from the marker being honoured
   * ahead of RAW_DOWNLOAD_GRACE_MS.
   */
  it("reclaims a released RAW without waiting out the grace period", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(2 * ONE_DAY_MS),
      downloadedAt: agoIso(60 * 1000),
      releasedAt: new Date().toISOString(),
    });

    await adminRequest("GET", PHOTOS_PATH);

    const state = await readRawPhotoState(PHOTO_ID, storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
    expect(state.accountStorageBytes).toBe(0);
  });

  /*
   * A release is a statement about the requests that existed when it was made.
   * The second visitor here asked afterwards and has not collected anything, so
   * the earlier release must not hand their bytes away underneath them.
   */
  it("keeps a released RAW once a later visitor has asked for it", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(2 * ONE_DAY_MS),
      downloadedAt: agoIso(2 * ONE_DAY_MS),
      releasedAt: agoIso(ONE_DAY_MS),
    });

    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: "visitor-token-second",
      fulfilledAt: agoIso(60 * 1000),
    });

    await adminRequest("GET", PHOTOS_PATH);

    expect((await readRawPhotoState(PHOTO_ID, storageKey)).objectExists).toBe(
      true,
    );
  });

  /*
   * Reclaiming has to put the photo back into the state the iPad reads as
   * "this one still needs uploading" -- otherwise a visitor who asks again
   * after a reclaim waits forever for a RAW nothing will ever send.
   */
  it("lets a later request re-arm the iPad's pending count", async () => {
    const storageKey = await seedForSweep({
      fulfilledAt: agoIso(3 * ONE_DAY_MS),
      downloadedAt: agoIso(2 * ONE_DAY_MS),
    });

    await adminRequest("GET", PHOTOS_PATH);
    expect((await readRawPhotoState(PHOTO_ID, storageKey)).objectExists).toBe(
      false,
    );

    await galleryRequest(
      "PUT",
      `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`,
      {
        json: { displayName: "Guest" },
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      },
    );

    const listed = await adminRequest<{
      photos: { pendingRawRequestCount: number }[];
    }>("GET", PHOTOS_PATH);

    expect(listed.body.photos[0].pendingRawRequestCount).toBe(1);
  });
});
