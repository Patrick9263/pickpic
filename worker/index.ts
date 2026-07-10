interface CreateEventBody {
  title?: unknown;
}

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
}

interface PhotoRow {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
}

interface StoredPhotoRow {
  storageKey: string;
}

const MAX_JPEG_BYTES = 25 * 1024 * 1024;

function jsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
    },
  });
}

function generateShareToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));

  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function getFilename(request: Request): string | null {
  const encodedFilename = request.headers.get("X-File-Name");

  if (!encodedFilename) {
    return null;
  }

  try {
    return decodeURIComponent(encodedFilename);
  } catch {
    return encodedFilename;
  }
}

function toPhotoRecord(row: PhotoRow): PhotoRecord {
  return {
    ...row,
    imageUrl: `/api/photos/${encodeURIComponent(row.id)}/image`,
  };
}

async function eventExists(eventId: string, env: Env): Promise<boolean> {
  const event = await env.DB.prepare(
    `
      SELECT id
      FROM events
      WHERE id = ?
    `,
  )
    .bind(eventId)
    .first<{ id: string }>();

  return event !== null;
}

async function createEvent(request: Request, env: Env): Promise<Response> {
  let body: CreateEventBody;

  try {
    body = await request.json<CreateEventBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (typeof body.title !== "string") {
    return jsonResponse({ error: "An event title is required." }, 400);
  }

  const title = body.title.trim();

  if (title.length === 0 || title.length > 120) {
    return jsonResponse(
      { error: "The event title must be between 1 and 120 characters." },
      400,
    );
  }

  const now = new Date().toISOString();

  const event: EventRecord = {
    id: crypto.randomUUID(),
    title,
    shareToken: generateShareToken(),
    status: "draft",
    createdAt: now,
    updatedAt: now,
  };

  await env.DB.prepare(
    `
      INSERT INTO events (
        id,
        title,
        share_token,
        status,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
    `,
  )
    .bind(
      event.id,
      event.title,
      event.shareToken,
      event.status,
      event.createdAt,
      event.updatedAt,
    )
    .run();

  return jsonResponse({ event }, 201);
}

async function listEvents(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt
      FROM events
      ORDER BY created_at DESC
    `,
  ).all<EventRecord>();

  return jsonResponse({
    events: result.results,
  });
}

async function createPhoto(
  request: Request,
  env: Env,
  eventId: string,
): Promise<Response> {
  if (!(await eventExists(eventId, env))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const contentType = request.headers
    .get("Content-Type")
    ?.split(";")[0]
    .trim()
    .toLowerCase();

  if (contentType !== "image/jpeg") {
    return jsonResponse(
      { error: "Only JPEG images are currently supported." },
      415,
    );
  }

  const originalFilename = getFilename(request)?.trim();

  if (
    !originalFilename ||
    originalFilename.length > 255 ||
    originalFilename.includes("\0")
  ) {
    return jsonResponse(
      { error: "A valid X-File-Name header is required." },
      400,
    );
  }

  if (!request.body) {
    return jsonResponse({ error: "The image body is required." }, 400);
  }

  const declaredSize = Number(request.headers.get("Content-Length"));

  if (Number.isFinite(declaredSize) && declaredSize > MAX_JPEG_BYTES) {
    return jsonResponse({ error: "The JPEG must be 25 MB or smaller." }, 413);
  }

  const photoId = crypto.randomUUID();
  const storageKey = `events/${eventId}/photos/${photoId}/preview.jpg`;

  let storedObject: R2Object;

  try {
    storedObject = await env.pickpic_photos.put(storageKey, request.body, {
      httpMetadata: {
        contentType: "image/jpeg",
      },
      customMetadata: {
        eventId,
        photoId,
        originalFilename,
      },
    });
  } catch {
    return jsonResponse({ error: "The image could not be stored." }, 500);
  }

  if (storedObject.size > MAX_JPEG_BYTES) {
    await env.pickpic_photos.delete(storageKey);

    return jsonResponse({ error: "The JPEG must be 25 MB or smaller." }, 413);
  }

  const createdAt = new Date().toISOString();

  try {
    await env.DB.prepare(
      `
        INSERT INTO photos (
          id,
          event_id,
          original_filename,
          storage_key,
          content_type,
          byte_size,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `,
    )
      .bind(
        photoId,
        eventId,
        originalFilename,
        storageKey,
        "image/jpeg",
        storedObject.size,
        createdAt,
      )
      .run();
  } catch {
    await env.pickpic_photos.delete(storageKey);

    return jsonResponse(
      { error: "The photo metadata could not be saved." },
      500,
    );
  }

  const photo: PhotoRecord = {
    id: photoId,
    eventId,
    originalFilename,
    contentType: "image/jpeg",
    byteSize: storedObject.size,
    createdAt,
    imageUrl: `/api/photos/${encodeURIComponent(photoId)}/image`,
  };

  return jsonResponse({ photo }, 201);
}

async function listPhotos(env: Env, eventId: string): Promise<Response> {
  if (!(await eventExists(eventId, env))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const result = await env.DB.prepare(
    `
      SELECT
        id,
        event_id AS eventId,
        original_filename AS originalFilename,
        content_type AS contentType,
        byte_size AS byteSize,
        created_at AS createdAt
      FROM photos
      WHERE event_id = ?
      ORDER BY created_at DESC
    `,
  )
    .bind(eventId)
    .all<PhotoRow>();

  return jsonResponse({
    photos: result.results.map(toPhotoRecord),
  });
}

async function getPhotoImage(env: Env, photoId: string): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT storage_key AS storageKey
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<StoredPhotoRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const object = await env.pickpic_photos.get(photo.storageKey);

  if (!object) {
    return jsonResponse({ error: "The stored image could not be found." }, 404);
  }

  const headers = new Headers();

  object.writeHttpMetadata(headers);

  if (!headers.has("Content-Type")) {
    headers.set("Content-Type", "image/jpeg");
  }

  headers.set("Content-Disposition", "inline");
  headers.set("Content-Length", object.size.toString());
  headers.set("ETag", object.httpEtag);
  headers.set("Cache-Control", "private, max-age=3600");
  headers.set("X-Content-Type-Options", "nosniff");

  return new Response(object.body, {
    status: 200,
    headers,
  });
}

async function deletePhoto(env: Env, photoId: string): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT storage_key AS storageKey
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<StoredPhotoRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  /*
   * Delete the R2 object first. R2 deletion is safe to retry, so if the
   * subsequent database operation fails, the entire request can be retried.
   */
  try {
    await env.pickpic_photos.delete(photo.storageKey);
  } catch {
    return jsonResponse(
      { error: "The stored image could not be deleted." },
      500,
    );
  }

  try {
    await env.DB.prepare(
      `
        DELETE FROM photos
        WHERE id = ?
      `,
    )
      .bind(photoId)
      .run();
  } catch {
    return jsonResponse(
      {
        error:
          "The image was deleted, but its photo record could not be removed. Try again.",
      },
      500,
    );
  }

  return jsonResponse({
    deletedPhotoId: photoId,
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/events") {
      if (request.method === "POST") {
        return createEvent(request, env);
      }

      if (request.method === "GET") {
        return listEvents(env);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const eventPhotosMatch = url.pathname.match(
      /^\/api\/events\/([^/]+)\/photos$/,
    );

    if (eventPhotosMatch) {
      const eventId = decodeURIComponent(eventPhotosMatch[1]);

      if (request.method === "POST") {
        return createPhoto(request, env, eventId);
      }

      if (request.method === "GET") {
        return listPhotos(env, eventId);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoImageMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/image$/,
    );

    if (photoImageMatch) {
      if (request.method !== "GET") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoImageMatch[1]);

      return getPhotoImage(env, photoId);
    }

    const photoMatch = url.pathname.match(/^\/api\/photos\/([^/]+)$/);

    if (photoMatch) {
      if (request.method !== "DELETE") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoMatch[1]);

      return deletePhoto(env, photoId);
    }

    if (url.pathname.startsWith("/api/")) {
      return jsonResponse({ error: "API route not found." }, 404);
    }

    return new Response(null, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
