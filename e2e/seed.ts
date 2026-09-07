import { createHash } from "node:crypto";
import type { APIRequestContext } from "@playwright/test";

/*
 * A byte-valid 1x1 JPEG, embedded as base64 rather than committed as a binary
 * file. The gallery falls back to the full image when no thumbnail/preview
 * variant exists (see GalleryGrid/GalleryLightbox reading
 * `variants.thumbnail?.imageUrl ?? photo.imageUrl`), so a real image never has
 * to be generated client-side for these smoke tests to render one.
 */
const TINY_JPEG_BASE64 =
  "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD/AP/Z";

export interface SeededGallery {
  eventId: string;
  shareToken: string;
  photoId: string;
  originalFilename: string;
}

/*
 * Seeds a fresh event with one photo through the real admin API rather than
 * writing rows into D1/objects into R2 directly. `/api/admin/*` is a no-op
 * auth check on localhost (see worker/access.ts's `isLocalRequest` /
 * `requireAdminAccess`) as long as the dev server's AUTH_MODE isn't forced to
 * "session" -- true for a fresh checkout, where `.dev.vars` (git-ignored)
 * doesn't exist at all. This walks the same create-event -> upload-photo path
 * the iPad app and dashboard use, so it exercises real validation (JPEG
 * content type, SHA-256 dedupe, the draft -> ready transition on first
 * upload) instead of duplicating that logic in a second, drifting code path.
 *
 * If your own `.dev.vars` sets AUTH_MODE=session (e.g. to exercise the
 * magic-link flow), this seeding step will fail with 401s -- unset it, or
 * comment it out, before running `npm run test:e2e`.
 */
export async function seedGallery(
  request: APIRequestContext,
  title: string,
): Promise<SeededGallery> {
  const eventResponse = await request.post("/api/admin/events", {
    data: { title },
  });

  if (!eventResponse.ok()) {
    throw new Error(
      `Failed to seed a test event (${eventResponse.status()}): ${await eventResponse.text()}`,
    );
  }

  const { event } = (await eventResponse.json()) as {
    event: { id: string; shareToken: string };
  };

  const jpegBytes = Buffer.from(TINY_JPEG_BASE64, "base64");
  const sha256 = createHash("sha256").update(jpegBytes).digest("hex");
  const originalFilename = "fixture.jpg";

  const photoResponse = await request.post(
    `/api/admin/events/${event.id}/photos`,
    {
      headers: {
        "Content-Type": "image/jpeg",
        "X-File-Name": originalFilename,
        "X-File-SHA256": sha256,
      },
      data: jpegBytes,
    },
  );

  if (!photoResponse.ok()) {
    throw new Error(
      `Failed to seed a test photo (${photoResponse.status()}): ${await photoResponse.text()}`,
    );
  }

  const { photo } = (await photoResponse.json()) as { photo: { id: string } };

  return {
    eventId: event.id,
    shareToken: event.shareToken,
    photoId: photo.id,
    originalFilename,
  };
}
