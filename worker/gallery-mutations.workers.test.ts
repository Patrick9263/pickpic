import { beforeEach, describe, expect, it } from "vitest";
import { clearTestData, insertEvent, insertPhoto } from "./test-fixtures.ts";
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
  await insertEvent({ id: EVENT_ID, shareToken: SHARE_TOKEN, status });
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
