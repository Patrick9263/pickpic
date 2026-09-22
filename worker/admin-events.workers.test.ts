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

  /*
   * JSON.parse("null") does not throw, so a literal `null` body used to
   * clear the try/catch around request.json() and crash on the first
   * property read (500) instead of returning the 400 every other malformed
   * body gets (#325).
   */
  it("rejects a null body with 400, not 500", async () => {
    const result = await adminRequest("POST", "/api/admin/events", {
      json: null,
    });

    expectError(result, 400, "The request body must be valid JSON.");
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

interface EventListBody {
  events: Array<{
    id: string;
    rawRequestsEnabled: boolean;
    hasRawRequests: boolean;
  }>;
}

describe("GET /api/admin/events", () => {
  /*
   * listEvents' own SELECT once omitted raw_requests_enabled entirely, so
   * every listed event read back as rawRequestsEnabled: undefined --
   * falsy, so the dashboard checkbox always rendered unchecked on load
   * regardless of what PUT .../raw-requests had actually saved. The write
   * itself worked; only the read that populates the toggle on a fresh page
   * load was wrong, which made a real, persisted setting look like it had
   * silently reverted.
   */
  it("reflects a persisted rawRequestsEnabled rather than always reading false", async () => {
    const created = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "Reads back enabled" },
    });

    await adminRequest(
      "PUT",
      `/api/admin/events/${created.body.event.id}/raw-requests`,
      { json: { enabled: true } },
    );

    const listed = await adminRequest<EventListBody>(
      "GET",
      "/api/admin/events",
    );

    const event = listed.body.events.find(
      (candidate) => candidate.id === created.body.event.id,
    );

    expect(event?.rawRequestsEnabled).toBe(true);
  });

  /*
   * hasRawRequests (#266) drives whether the dashboard's "Release collected
   * RAW files" control renders at all -- it must stay false for an event
   * that has never had one, and flip true as soon as a photo does, even
   * with the request still outstanding (unfulfilled).
   */
  it("reports hasRawRequests only once a photo in the event has one", async () => {
    const created = await adminRequest<EventBody>("POST", "/api/admin/events", {
      json: { title: "Never requested" },
    });

    const eventId = created.body.event.id;

    const beforeRequest = await adminRequest<EventListBody>(
      "GET",
      "/api/admin/events",
    );

    expect(
      beforeRequest.body.events.find((candidate) => candidate.id === eventId)
        ?.hasRawRequests,
    ).toBe(false);

    await insertPhoto({ id: "photo-has-raw-requests", eventId });
    await insertRawRequest({
      photoId: "photo-has-raw-requests",
      eventId,
      visitorToken: "visitor-token-has-raw-requests",
    });

    const afterRequest = await adminRequest<EventListBody>(
      "GET",
      "/api/admin/events",
    );

    expect(
      afterRequest.body.events.find((candidate) => candidate.id === eventId)
        ?.hasRawRequests,
    ).toBe(true);
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

/*
 * "Stop offering originals for this event" (#282) -- the force-clear #219's
 * release button deliberately declines to do on its own. Unlike that suite,
 * these assert the reclaim itself as well as the eligibility rule: the whole
 * point of this route is to force a reclaim through the awaitingCount veto
 * and the 24h grace period that raw-releases respects.
 */
describe("POST /api/admin/events/:id/raw-requests/stop", () => {
  const EVENT_ID = "event-raw-stop";
  const SHARE_TOKEN = "share-raw-stop";
  const STOP_PATH = `/api/admin/events/${EVENT_ID}/raw-requests/stop`;

  interface StopBody {
    event: { id: string; rawRequestsEnabled: boolean };
    cancelledRequestCount: number;
  }

  function agoIso(milliseconds: number): string {
    return new Date(Date.now() - milliseconds).toISOString();
  }

  async function readRequestRow(photoId: string): Promise<{
    downloadedAt: string | null;
    releasedAt: string | null;
  } | null> {
    return env.DB.prepare(
      `
        SELECT downloaded_at AS downloadedAt, released_at AS releasedAt
        FROM raw_requests
        WHERE photo_id = ?
      `,
    )
      .bind(photoId)
      .first<{ downloadedAt: string | null; releasedAt: string | null }>();
  }

  beforeEach(async () => {
    await insertEvent({
      id: EVENT_ID,
      shareToken: SHARE_TOKEN,
      rawRequestsEnabled: true,
    });
  });

  it("cancels a request nobody has uploaded a RAW for yet", async () => {
    await insertPhoto({ id: "photo-unfulfilled", eventId: EVENT_ID });
    await insertRawRequest({
      photoId: "photo-unfulfilled",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-unfulfilled",
    });

    const result = await adminRequest<StopBody>("POST", STOP_PATH);

    expect(result.status).toBe(200);
    expect(result.body.cancelledRequestCount).toBe(1);
    expect(await readRequestRow("photo-unfulfilled")).toBeNull();
  });

  it("cancels a delivered RAW nobody has downloaded, and reclaims it", async () => {
    await insertPhoto({ id: "photo-undownloaded", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-undownloaded",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-undownloaded",
      eventId: EVENT_ID,
      visitorToken: "visitor-undownloaded",
      fulfilledAt: agoIso(60 * 60 * 1000),
    });

    const result = await adminRequest<StopBody>("POST", STOP_PATH);

    expect(result.body.cancelledRequestCount).toBe(1);
    expect(await readRequestRow("photo-undownloaded")).toBeNull();

    const state = await readRawPhotoState("photo-undownloaded", storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
  });

  /*
   * The load-bearing case: a collected RAW downloaded a minute ago, well
   * inside the 24h grace period and never explicitly released. raw-releases
   * would hold this; this route must free it anyway, because the whole
   * point is "regardless of collection status".
   */
  it("force-reclaims a collected but unreleased RAW without waiting the grace period", async () => {
    await insertPhoto({ id: "photo-collected", eventId: EVENT_ID });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-collected",
      eventId: EVENT_ID,
    });

    await insertRawRequest({
      photoId: "photo-collected",
      eventId: EVENT_ID,
      visitorToken: "visitor-token-collected",
      fulfilledAt: agoIso(60 * 60 * 1000),
      downloadedAt: agoIso(60 * 1000),
    });

    const result = await adminRequest<StopBody>("POST", STOP_PATH);

    /* Collected requests are history, not cancelled. */
    expect(result.body.cancelledRequestCount).toBe(0);

    const row = await readRequestRow("photo-collected");
    expect(row?.downloadedAt).not.toBeNull();
    expect(row?.releasedAt).not.toBeNull();

    const state = await readRawPhotoState("photo-collected", storageKey);
    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
  });

  it("turns raw_requests_enabled off", async () => {
    const result = await adminRequest<StopBody>("POST", STOP_PATH);

    expect(result.body.event.rawRequestsEnabled).toBe(false);
  });

  it("leaves another event's requests untouched", async () => {
    const OTHER_EVENT_ID = "event-raw-stop-other";

    await insertEvent({
      id: OTHER_EVENT_ID,
      shareToken: "share-raw-stop-other",
      rawRequestsEnabled: true,
    });
    await insertPhoto({ id: "photo-bystander", eventId: OTHER_EVENT_ID });
    await insertRawRequest({
      photoId: "photo-bystander",
      eventId: OTHER_EVENT_ID,
      visitorToken: "visitor-token-bystander",
    });

    await adminRequest("POST", STOP_PATH);

    expect(await readRequestRow("photo-bystander")).not.toBeNull();
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "POST",
      "/api/admin/events/no-such-event/raw-requests/stop",
    );

    expectError(result, 404, "Event not found.");
  });

  it("405s on a non-POST method", async () => {
    expectMethodNotAllowed(await adminRequest("GET", STOP_PATH));
  });
});

describe("DELETE /api/admin/events/:id", () => {
  it("deletes the event row", async () => {
    await insertEvent({ id: "event-delete", shareToken: "share-delete" });

    const result = await adminRequest<{ deleted: boolean }>(
      "DELETE",
      "/api/admin/events/event-delete",
    );

    expect(result.status).toBe(200);
    expect(result.body.deleted).toBe(true);

    const row = await env.DB.prepare(`SELECT id FROM events WHERE id = ?`)
      .bind("event-delete")
      .first();

    expect(row).toBeNull();
  });

  /*
   * The bug this guards against (#230): a keys-from-the-database delete only
   * ever reaches objects a photo or variant row still points at. An object
   * put in R2 with no row -- an upload cancelled between the R2 write and the
   * D1 insert, or a superseded variant key -- used to survive event deletion
   * forever, since the event row that would have traced it back to an
   * account was gone the moment this returned. The fix sweeps by R2 prefix
   * instead of by known key, so this orphan has to be gone too.
   */
  it("deletes R2 objects under the event's prefix that have no database row", async () => {
    await insertEvent({ id: "event-orphan", shareToken: "share-orphan" });
    await insertPhoto({ id: "photo-tracked", eventId: "event-orphan" });

    const orphanKey = "events/event-orphan/photos/photo-tracked/orphan.jpg";

    await env.pickpic_photos.put(orphanKey, new Uint8Array([1, 2, 3]));

    expect(await env.pickpic_photos.head(orphanKey)).not.toBeNull();

    const result = await adminRequest(
      "DELETE",
      "/api/admin/events/event-orphan",
    );

    expect(result.status).toBe(200);
    expect(await env.pickpic_photos.head(orphanKey)).toBeNull();
  });

  it("leaves other events' R2 objects alone", async () => {
    await insertEvent({ id: "event-victim", shareToken: "share-victim" });
    await insertEvent({ id: "event-bystander", shareToken: "share-bystander" });

    const bystanderKey = "events/event-bystander/photos/photo-a/orphan.jpg";

    await env.pickpic_photos.put(bystanderKey, new Uint8Array([1, 2, 3]));

    await adminRequest("DELETE", "/api/admin/events/event-victim");

    expect(await env.pickpic_photos.head(bystanderKey)).not.toBeNull();
  });

  it("404s for an event that doesn't exist", async () => {
    const result = await adminRequest(
      "DELETE",
      "/api/admin/events/no-such-event",
    );

    expectError(result, 404, "Event not found.");
  });
});
