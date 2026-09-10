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
import {
  adminRequest,
  expectError,
  expectMethodNotAllowed,
} from "./test-request.ts";

interface EventBody {
  event: {
    id: string;
    title: string;
    status: string;
    rawRequestsEnabled: boolean;
  };
}

beforeEach(async () => {
  await clearTestData();
});

describe("POST /api/admin/events", () => {
  it("creates a draft event, trimming the title", async () => {
    const result = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "  Harbour wedding  " },
    });

    expect(result.status).toBe(201);
    expect(result.body.event.title).toBe("Harbour wedding");
    expect(result.body.event.status).toBe("draft");
  });

  it("rejects a missing title", async () => {
    const result = await adminRequest("POST", "/api/admin/events", {
      json: {},
    });

    expectError(result, 400, "An event title is required.");
  });

  it.each(["   ", ""])(
    "rejects a title that trims to empty (%j)",
    async (title) => {
      const result = await adminRequest("POST", "/api/admin/events", {
        json: { title },
      });

      expectError(
        result,
        400,
        "The event title must be between 1 and 120 characters.",
      );
    },
  );

  it("rejects a title over 120 characters", async () => {
    const result = await adminRequest("POST", "/api/admin/events", {
      json: { title: "a".repeat(121) },
    });

    expectError(
      result,
      400,
      "The event title must be between 1 and 120 characters.",
    );
  });

  it("accepts a title at the 120 character boundary", async () => {
    const result = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "a".repeat(120) },
    });

    expect(result.status).toBe(201);
  });

  it("rejects an id that isn't a UUID", async () => {
    const result = await adminRequest("POST", "/api/admin/events", {
      json: { title: "Test event", id: "not-a-uuid" },
    });

    expectError(result, 400, "An event id must be a UUID.");
  });

  /*
   * The iPad names an event before it can reach the network, so a retried
   * create -- one whose response the client never saw -- has to converge on
   * the same event instead of leaving a duplicate behind (worker/index.ts:886-900).
   */
  it("is idempotent on a client-supplied id: a repeated create returns the same event", async () => {
    const id = "11111111-1111-4111-8111-111111111111";

    const first = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "First name", id },
    });

    expect(first.status).toBe(201);
    expect(first.body.event.id).toBe(id);

    const second = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "Retried with a different title", id },
    });

    expect(second.status).toBe(200);
    expect(second.body.event).toEqual(first.body.event);
  });

  it("uppercase ids converge with their lowercase form", async () => {
    const id = "22222222-2222-4222-8222-222222222222";

    const first = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "Lowercase create", id },
    });

    const second = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "Uppercase retry", id: id.toUpperCase() },
    });

    expect(second.status).toBe(200);
    expect(second.body.event.id).toBe(first.body.event.id);
  });

  it("405s on a non-POST/GET method", async () => {
    const result = await adminRequest("DELETE", "/api/admin/events");

    expectMethodNotAllowed(result);
  });
});

describe("PUT /api/admin/events/:id/status", () => {
  const EVENT_ID = "event-status";

  beforeEach(async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: "share-status",
      status: "draft",
    });
  });

  it.each(["draft", "ready", "completed", "archived"])(
    "sets the status to %s",
    async (status) => {
      const result = await adminRequest<EventBody>(
        "PUT",
        `/api/admin/events/${EVENT_ID}/status`,
        { json: { status } },
      );

      expect(result.status).toBe(200);
      expect(result.body.event.status).toBe(status);
    },
  );

  it("400s on an unknown status", async () => {
    const result = await adminRequest(
      "PUT",
      `/api/admin/events/${EVENT_ID}/status`,
      { json: { status: "cancelled" } },
    );

    expectError(
      result,
      400,
      "The status must be draft, ready, completed, or archived.",
    );
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "PUT",
      "/api/admin/events/no-such-event/status",
      { json: { status: "ready" } },
    );

    expectError(result, 404, "Event not found.");
  });

  it("405s on a non-PUT method", async () => {
    const result = await adminRequest(
      "GET",
      `/api/admin/events/${EVENT_ID}/status`,
    );

    expectMethodNotAllowed(result);
  });
});

describe("PUT /api/admin/events/:id/raw-requests", () => {
  const EVENT_ID = "event-raw-requests";

  beforeEach(async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: "share-raw-requests",
      status: "draft",
    });
  });

  it("enables and disables RAW requests", async () => {
    const enabled = await adminRequest<EventBody>(
      "PUT",
      `/api/admin/events/${EVENT_ID}/raw-requests`,
      { json: { enabled: true } },
    );

    expect(enabled.status).toBe(200);
    expect(enabled.body.event.rawRequestsEnabled).toBe(true);

    const disabled = await adminRequest<EventBody>(
      "PUT",
      `/api/admin/events/${EVENT_ID}/raw-requests`,
      { json: { enabled: false } },
    );

    expect(disabled.status).toBe(200);
    expect(disabled.body.event.rawRequestsEnabled).toBe(false);
  });

  it("400s on a non-boolean enabled value", async () => {
    const result = await adminRequest(
      "PUT",
      `/api/admin/events/${EVENT_ID}/raw-requests`,
      { json: { enabled: "yes" } },
    );

    expectError(result, 400, "The enabled flag must be a boolean.");
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "PUT",
      "/api/admin/events/no-such-event/raw-requests",
      { json: { enabled: true } },
    );

    expectError(result, 404, "Event not found.");
  });

  it("405s on a non-PUT method", async () => {
    const result = await adminRequest(
      "GET",
      `/api/admin/events/${EVENT_ID}/raw-requests`,
    );

    expectMethodNotAllowed(result);
  });
});

/*
 * The manual release (#219). These assert the eligibility rule rather than the
 * reclaim itself -- gallery.workers.test.ts already drives the sweep -- because
 * the rule is the whole safety argument: a RAW somebody is still waiting on
 * must survive a release aimed at the event it sits in.
 */
describe("POST /api/admin/events/:id/raw-releases", () => {
  const EVENT_ID = "event-raw-releases";
  const SHARE_TOKEN = "share-raw-releases";
  const RELEASES_PATH = `/api/admin/events/${EVENT_ID}/raw-releases`;

  interface ReleaseBody {
    releasedPhotoCount: number;
    awaitingPhotoCount: number;
  }

  function agoIso(milliseconds: number): string {
    return new Date(Date.now() - milliseconds).toISOString();
  }

  async function seedRequestedRaw(
    photoId: string,
    request: { fulfilledAt?: string; downloadedAt?: string },
  ): Promise<string> {
    await insertPhoto({ id: photoId, eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({ photoId, eventId: EVENT_ID });

    await insertRawRequest({
      photoId,
      eventId: EVENT_ID,
      visitorToken: `visitor-${photoId}`,
      fulfilledAt: request.fulfilledAt,
      downloadedAt: request.downloadedAt,
    });

    return storageKey;
  }

  beforeEach(async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
  });

  it("releases a collected RAW and frees its bytes in the same request", async () => {
    const storageKey = await seedRequestedRaw("photo-collected", {
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });

    const result = await adminRequest<ReleaseBody>("POST", RELEASES_PATH);

    expect(result.status).toBe(200);
    expect(result.body).toEqual({
      releasedPhotoCount: 1,
      awaitingPhotoCount: 0,
    });

    const state = await readRawPhotoState("photo-collected", storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
    expect(state.accountStorageBytes).toBe(0);
  });

  /*
   * Releasing an undownloaded RAW would be "cancel this delivery", which is a
   * different feature and deliberately not this one.
   */
  it("leaves a delivered but uncollected RAW alone", async () => {
    const storageKey = await seedRequestedRaw("photo-uncollected", {
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<ReleaseBody>("POST", RELEASES_PATH);

    expect(result.body).toEqual({
      releasedPhotoCount: 0,
      awaitingPhotoCount: 1,
    });
    expect(
      (await readRawPhotoState("photo-uncollected", storageKey)).objectExists,
    ).toBe(true);
  });

  /*
   * One release covers the shoot, and each photo is judged on its own
   * requests -- the point of the per-event granularity.
   */
  it("releases only the collected photos in the event", async () => {
    const collectedKey = await seedRequestedRaw("photo-both-collected", {
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });
    const waitingKey = await seedRequestedRaw("photo-still-waiting", {
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<ReleaseBody>("POST", RELEASES_PATH);

    expect(result.body).toEqual({
      releasedPhotoCount: 1,
      awaitingPhotoCount: 1,
    });
    expect(
      (await readRawPhotoState("photo-both-collected", collectedKey))
        .objectExists,
    ).toBe(false);
    expect(
      (await readRawPhotoState("photo-still-waiting", waitingKey)).objectExists,
    ).toBe(true);
  });

  /*
   * Two requesters, one collected. Reclaiming on the first download alone is
   * exactly what migration 0021 says must not happen, and a per-event release
   * is the easiest way to reintroduce it.
   */
  it("holds a photo whose second requester has not collected", async () => {
    await insertPhoto({ id: "photo-two-visitors", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
      visitorToken: "visitor-two-visitors-collected",
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });
    await insertRawRequest({
      photoId: "photo-two-visitors",
      eventId: EVENT_ID,
      visitorToken: "visitor-two-visitors-still-waiting",
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<ReleaseBody>("POST", RELEASES_PATH);

    expect(result.body).toEqual({
      releasedPhotoCount: 0,
      awaitingPhotoCount: 1,
    });
    expect(
      (await readRawPhotoState("photo-two-visitors", storageKey)).objectExists,
    ).toBe(true);
  });

  /*
   * The record of who collected what is the reason this is a marker rather
   * than a row deletion. Freeing storage must not cost that history.
   */
  it("keeps the request rows and their downloaded_at", async () => {
    await seedRequestedRaw("photo-history", {
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });

    await adminRequest("POST", RELEASES_PATH);

    const row = await env.DB.prepare(
      `
        SELECT downloaded_at AS downloadedAt, released_at AS releasedAt
        FROM raw_requests
        WHERE photo_id = ?
      `,
    )
      .bind("photo-history")
      .first<{ downloadedAt: string | null; releasedAt: string | null }>();

    expect(row?.downloadedAt).not.toBeNull();
    expect(row?.releasedAt).not.toBeNull();
  });

  it("reports nothing to do for an event with no delivered RAWs", async () => {
    await insertPhoto({ id: "photo-no-raw", eventId: EVENT_ID });

    const result = await adminRequest<ReleaseBody>("POST", RELEASES_PATH);

    expect(result.body).toEqual({
      releasedPhotoCount: 0,
      awaitingPhotoCount: 0,
    });
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "POST",
      "/api/admin/events/no-such-event/raw-releases",
    );

    expectError(result, 404, "Event not found.");
  });

  it("405s on a non-POST method", async () => {
    expectMethodNotAllowed(await adminRequest("GET", RELEASES_PATH));
  });
});
