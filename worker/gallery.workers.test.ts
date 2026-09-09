import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "./index.ts";
import {
  clearTestData,
  insertEvent,
  insertHeart,
  insertPhoto,
  insertRawRequest,
} from "./test-fixtures.ts";

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

  it("405s on a non-GET method", async () => {
    await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN });

    const response = await fetchGallery(SHARE_TOKEN, { method: "DELETE" });

    expect(response.status).toBe(405);
  });
});
