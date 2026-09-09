import { beforeEach, describe, expect, it } from "vitest";
import { clearTestData, insertEvent } from "./test-fixtures.ts";
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
