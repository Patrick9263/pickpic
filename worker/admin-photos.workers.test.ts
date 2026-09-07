import { beforeEach, describe, expect, it } from "vitest";
import { clearTestData, insertEvent, insertPhoto } from "./test-fixtures.ts";
import {
  adminRequest,
  expectError,
  expectMethodNotAllowed,
} from "./test-request.ts";

interface PhotoListBody {
  photos: { id: string }[];
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
