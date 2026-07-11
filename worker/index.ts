interface CreateEventBody {
  title?: unknown;
}

interface HeartRequestBody {
  displayName?: unknown;
}

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

interface FinalPhotoRecord {
  originalFilename: string;
  contentType: string;
  byteSize: number;
  uploadedAt: string;
  imageUrl: string;
}

interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
  heartCount: number;
  workflowStatus: PhotoWorkflowStatus;
  finalPhoto: FinalPhotoRecord | null;
  comments: PhotoCommentRecord[];
}

interface PhotoRow {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  heartCount: number;
  workflowStatus: PhotoWorkflowStatus;
  finalOriginalFilename: string | null;
  finalContentType: string | null;
  finalByteSize: number | null;
  finalUploadedAt: string | null;
}

interface StoredPhotoRow {
  storageKey: string;
  finalStorageKey: string | null;
}

interface FinalPhotoUploadRow {
  eventId: string;
  finalStorageKey: string | null;
}

interface FinalPhotoKeyRow {
  finalStorageKey: string | null;
}

interface PublicGalleryEvent {
  title: string;
  status: string;
  createdAt: string;
}

interface PublicGalleryEventRow extends PublicGalleryEvent {
  id: string;
}

interface PublicPhotoRecord extends Omit<PhotoRecord, "comments"> {
  comments: PublicPhotoCommentRecord[];
  viewerHearted: boolean;
}

interface PublicGalleryResponse {
  event: PublicGalleryEvent;
  photos: PublicPhotoRecord[];
}

interface GalleryPhotoRow {
  photoId: string;
  eventId: string;
}

interface VisitorRow {
  id: string;
}

interface HeartedPhotoRow {
  photoId: string;
}

interface HeartCountRow {
  heartCount: number;
}

interface CommentRequestBody {
  displayName?: unknown;
  body?: unknown;
}

interface ResolveCommentRequestBody {
  resolved?: unknown;
}

interface DashboardCommentRow {
  id: string;
  photoId: string;
  eventId: string;
}

interface PhotoCommentRecord {
  id: string;
  photoId: string;
  displayName: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  resolvedAt: string | null;
}

interface UpdateCommentRequestBody {
  body?: unknown;
}

interface PublicPhotoCommentRecord extends PhotoCommentRecord {
  viewerOwned: boolean;
}

interface CommentRow extends PhotoCommentRecord {
  visitorToken: string;
}

type PhotoWorkflowStatus = "idle" | "editing" | "final";

interface SetPhotoWorkflowBody {
  status?: unknown;
}

interface PhotoWorkflowRow {
  id: string;
  workflowStatus: PhotoWorkflowStatus;
  finalStorageKey: string | null;
}

const MAX_JPEG_BYTES = 25 * 1024 * 1024;

const MAX_FINAL_JPEG_BYTES = 50 * 1024 * 1024;

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

function getVisitorToken(request: Request): string | null {
  const token = request.headers.get("X-PickPic-Visitor")?.trim();

  if (!token || token.length < 20 || token.length > 100) {
    return null;
  }

  return token;
}

function toPhotoRecord(
  row: PhotoRow,
  comments: PhotoCommentRecord[] = [],
): PhotoRecord {
  const {
    finalOriginalFilename,
    finalContentType,
    finalByteSize,
    finalUploadedAt,
    ...basePhoto
  } = row;

  const hasFinalPhoto =
    finalOriginalFilename !== null &&
    finalContentType !== null &&
    finalByteSize !== null &&
    finalUploadedAt !== null;

  return {
    ...basePhoto,
    heartCount: Number(basePhoto.heartCount ?? 0),
    imageUrl: `/api/photos/${encodeURIComponent(row.id)}/image`,
    finalPhoto: hasFinalPhoto
      ? {
          originalFilename: finalOriginalFilename,
          contentType: finalContentType,
          byteSize: Number(finalByteSize),
          uploadedAt: finalUploadedAt,
          imageUrl:
            `/api/photos/${encodeURIComponent(row.id)}/final-image` +
            `?v=${encodeURIComponent(finalUploadedAt)}`,
        }
      : null,
    comments,
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
          workflow_status,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `,
    )
      .bind(
        photoId,
        eventId,
        originalFilename,
        storageKey,
        "image/jpeg",
        storedObject.size,
        "idle",
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
    heartCount: 0,
    workflowStatus: "idle",
    finalPhoto: null,
    comments: [],
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
        p.id,
        p.event_id AS eventId,
        p.original_filename AS originalFilename,
        p.content_type AS contentType,
        p.byte_size AS byteSize,
        p.created_at AS createdAt,
        p.workflow_status AS workflowStatus,
        p.final_original_filename AS finalOriginalFilename,
        p.final_content_type AS finalContentType,
        p.final_byte_size AS finalByteSize,
        p.final_uploaded_at AS finalUploadedAt,
        COUNT(h.photo_id) AS heartCount
      FROM photos p
      LEFT JOIN hearts h
        ON h.photo_id = p.id
      WHERE p.event_id = ?
      GROUP BY
        p.id,
        p.event_id,
        p.original_filename,
        p.content_type,
        p.byte_size,
        p.created_at,
        p.workflow_status,
        p.final_original_filename,
        p.final_content_type,
        p.final_byte_size,
        p.final_uploaded_at
      ORDER BY p.created_at DESC
    `,
  )
    .bind(eventId)
    .all<PhotoRow>();

  const commentsByPhoto = await getCommentsByPhoto(env, eventId);

  return jsonResponse({
    photos: result.results.map((row) =>
      toPhotoRecord(
        row,
        (commentsByPhoto.get(row.id) ?? []).map(toPhotoCommentRecord),
      ),
    ),
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
    .first<{ storageKey: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  return getStoredJpeg(env, photo.storageKey);
}

async function deletePhoto(env: Env, photoId: string): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT
        storage_key AS storageKey,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE id = ?
  `,
  )
    .bind(photoId)
    .first<StoredPhotoRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const storageKeys = [photo.storageKey, photo.finalStorageKey].filter(
    (key): key is string => key !== null,
  );

  try {
    await Promise.all(
      storageKeys.map((storageKey) => env.pickpic_photos.delete(storageKey)),
    );
  } catch {
    return jsonResponse(
      { error: "The stored images could not be deleted." },
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

async function getPublicGallery(
  request: Request,
  env: Env,
  shareToken: string,
): Promise<Response> {
  const event = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        status,
        created_at AS createdAt
      FROM events
      WHERE share_token = ?
    `,
  )
    .bind(shareToken)
    .first<PublicGalleryEventRow>();

  if (!event) {
    return jsonResponse({ error: "Gallery not found." }, 404);
  }

  const photoResult = await env.DB.prepare(
    `
      SELECT
        p.id,
        p.event_id AS eventId,
        p.original_filename AS originalFilename,
        p.content_type AS contentType,
        p.byte_size AS byteSize,
        p.created_at AS createdAt,
        p.workflow_status AS workflowStatus,
        p.final_original_filename AS finalOriginalFilename,
        p.final_content_type AS finalContentType,
        p.final_byte_size AS finalByteSize,
        p.final_uploaded_at AS finalUploadedAt,
        COUNT(h.photo_id) AS heartCount
      FROM photos p
      LEFT JOIN hearts h
        ON h.photo_id = p.id
      WHERE p.event_id = ?
      GROUP BY
        p.id,
        p.event_id,
        p.original_filename,
        p.content_type,
        p.byte_size,
        p.created_at,
        p.workflow_status,
        p.final_original_filename,
        p.final_content_type,
        p.final_byte_size,
        p.final_uploaded_at
      ORDER BY p.created_at ASC
    `,
  )
    .bind(event.id)
    .all<PhotoRow>();

  const commentsByPhoto = await getCommentsByPhoto(env, event.id);
  const visitorToken = getVisitorToken(request);
  const heartedPhotoIds = new Set<string>();

  if (visitorToken) {
    const heartResult = await env.DB.prepare(
      `
        SELECT h.photo_id AS photoId
        FROM hearts h
        INNER JOIN gallery_visitors v
          ON v.id = h.visitor_id
        WHERE
          v.event_id = ?
          AND v.visitor_token = ?
      `,
    )
      .bind(event.id, visitorToken)
      .all<HeartedPhotoRow>();

    for (const row of heartResult.results) {
      heartedPhotoIds.add(row.photoId);
    }
  }

  const response: PublicGalleryResponse = {
    event: {
      title: event.title,
      status: event.status,
      createdAt: event.createdAt,
    },
    photos: photoResult.results.map((row) => {
      const commentRows = commentsByPhoto.get(row.id) ?? [];

      const photo = toPhotoRecord(row, commentRows.map(toPhotoCommentRecord));

      return {
        ...photo,
        comments: commentRows.map((comment) => ({
          ...toPhotoCommentRecord(comment),
          viewerOwned:
            visitorToken !== null && comment.visitorToken === visitorToken,
        })),
        viewerHearted: heartedPhotoIds.has(photo.id),
      };
    }),
  };

  return jsonResponse(response);
}

async function findGalleryPhoto(
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<GalleryPhotoRow | null> {
  return env.DB.prepare(
    `
      SELECT
        p.id AS photoId,
        p.event_id AS eventId
      FROM photos p
      INNER JOIN events e
        ON e.id = p.event_id
      WHERE
        p.id = ?
        AND e.share_token = ?
    `,
  )
    .bind(photoId, shareToken)
    .first<GalleryPhotoRow>();
}

async function getHeartCount(env: Env, photoId: string): Promise<number> {
  const result = await env.DB.prepare(
    `
      SELECT COUNT(*) AS heartCount
      FROM hearts
      WHERE photo_id = ?
    `,
  )
    .bind(photoId)
    .first<HeartCountRow>();

  return Number(result?.heartCount ?? 0);
}

async function addHeart(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  let body: HeartRequestBody;

  try {
    body = await request.json<HeartRequestBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (typeof body.displayName !== "string") {
    return jsonResponse(
      { error: "Enter your name before requesting an edit." },
      400,
    );
  }

  const displayName = body.displayName.trim();

  if (displayName.length === 0 || displayName.length > 80) {
    return jsonResponse(
      { error: "Your name must be between 1 and 80 characters." },
      400,
    );
  }

  const galleryPhoto = await findGalleryPhoto(env, shareToken, photoId);

  if (!galleryPhoto) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const now = new Date().toISOString();

  const visitor = await upsertGalleryVisitor(
    env,
    galleryPhoto.eventId,
    visitorToken,
    displayName,
  );

  if (!visitor) {
    return jsonResponse(
      { error: "The visitor identity could not be saved." },
      500,
    );
  }

  await env.DB.prepare(
    `
      INSERT INTO hearts (
        photo_id,
        visitor_id,
        created_at
      )
      VALUES (?, ?, ?)
      ON CONFLICT(photo_id, visitor_id)
      DO NOTHING
    `,
  )
    .bind(photoId, visitor.id, now)
    .run();

  return jsonResponse({
    hearted: true,
    heartCount: await getHeartCount(env, photoId),
  });
}

async function removeHeart(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  const galleryPhoto = await findGalleryPhoto(env, shareToken, photoId);

  if (!galleryPhoto) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const visitor = await env.DB.prepare(
    `
      SELECT id
      FROM gallery_visitors
      WHERE
        event_id = ?
        AND visitor_token = ?
    `,
  )
    .bind(galleryPhoto.eventId, visitorToken)
    .first<VisitorRow>();

  if (visitor) {
    await env.DB.prepare(
      `
        DELETE FROM hearts
        WHERE
          photo_id = ?
          AND visitor_id = ?
      `,
    )
      .bind(photoId, visitor.id)
      .run();
  }

  return jsonResponse({
    hearted: false,
    heartCount: await getHeartCount(env, photoId),
  });
}

async function clearPhotoHearts(env: Env, photoId: string): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT id
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<{ id: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  await env.DB.prepare(
    `
      DELETE FROM hearts
      WHERE photo_id = ?
    `,
  )
    .bind(photoId)
    .run();

  return jsonResponse({
    photoId,
    heartCount: 0,
  });
}

async function upsertGalleryVisitor(
  env: Env,
  eventId: string,
  visitorToken: string,
  displayName: string,
): Promise<VisitorRow | null> {
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO gallery_visitors (
        id,
        event_id,
        visitor_token,
        display_name,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(event_id, visitor_token)
      DO UPDATE SET
        display_name = excluded.display_name,
        updated_at = excluded.updated_at
    `,
  )
    .bind(crypto.randomUUID(), eventId, visitorToken, displayName, now, now)
    .run();

  return env.DB.prepare(
    `
      SELECT id
      FROM gallery_visitors
      WHERE
        event_id = ?
        AND visitor_token = ?
    `,
  )
    .bind(eventId, visitorToken)
    .first<VisitorRow>();
}

async function getCommentsByPhoto(
  env: Env,
  eventId: string,
): Promise<Map<string, CommentRow[]>> {
  const result = await env.DB.prepare(
    `
      SELECT
        c.id,
        c.photo_id AS photoId,
        v.display_name AS displayName,
        v.visitor_token AS visitorToken,
        c.body,
        c.created_at AS createdAt,
        c.updated_at AS updatedAt,
        c.resolved_at AS resolvedAt
      FROM comments c
      INNER JOIN gallery_visitors v
        ON v.id = c.visitor_id
      INNER JOIN photos p
        ON p.id = c.photo_id
      WHERE p.event_id = ?
      ORDER BY c.created_at ASC
    `,
  )
    .bind(eventId)
    .all<CommentRow>();

  const commentsByPhoto = new Map<string, CommentRow[]>();

  for (const comment of result.results) {
    const comments = commentsByPhoto.get(comment.photoId) ?? [];
    comments.push(comment);
    commentsByPhoto.set(comment.photoId, comments);
  }

  return commentsByPhoto;
}

async function addComment(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  let requestBody: CommentRequestBody;

  try {
    requestBody = await request.json<CommentRequestBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (
    typeof requestBody.displayName !== "string" ||
    typeof requestBody.body !== "string"
  ) {
    return jsonResponse({ error: "Your name and comment are required." }, 400);
  }

  const displayName = requestBody.displayName.trim();
  const commentBody = requestBody.body.trim();

  if (displayName.length === 0 || displayName.length > 80) {
    return jsonResponse(
      { error: "Your name must be between 1 and 80 characters." },
      400,
    );
  }

  if (commentBody.length === 0 || commentBody.length > 1000) {
    return jsonResponse(
      { error: "Your comment must be between 1 and 1000 characters." },
      400,
    );
  }

  const galleryPhoto = await findGalleryPhoto(env, shareToken, photoId);

  if (!galleryPhoto) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const visitor = await upsertGalleryVisitor(
    env,
    galleryPhoto.eventId,
    visitorToken,
    displayName,
  );

  if (!visitor) {
    return jsonResponse(
      { error: "The visitor identity could not be saved." },
      500,
    );
  }

  const now = new Date().toISOString();

  const comment: PublicPhotoCommentRecord = {
    id: crypto.randomUUID(),
    photoId,
    displayName,
    body: commentBody,
    createdAt: now,
    updatedAt: now,
    resolvedAt: null,
    viewerOwned: true,
  };

  await env.DB.prepare(
    `
      INSERT INTO comments (
        id,
        photo_id,
        visitor_id,
        body,
        created_at,
        updated_at,
        resolved_at
      )
      VALUES (?, ?, ?, ?, ?, ?, NULL)
    `,
  )
    .bind(
      comment.id,
      photoId,
      visitor.id,
      comment.body,
      comment.createdAt,
      comment.updatedAt,
    )
    .run();

  return jsonResponse({ comment }, 201);
}

function toPhotoCommentRecord(row: CommentRow): PhotoCommentRecord {
  return {
    id: row.id,
    photoId: row.photoId,
    displayName: row.displayName,
    body: row.body,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    resolvedAt: row.resolvedAt,
  };
}

async function findOwnedGalleryComment(
  env: Env,
  shareToken: string,
  photoId: string,
  commentId: string,
  visitorToken: string,
): Promise<PhotoCommentRecord | null> {
  return env.DB.prepare(
    `
      SELECT
        c.id,
        c.photo_id AS photoId,
        v.display_name AS displayName,
        c.body,
        c.created_at AS createdAt,
        c.updated_at AS updatedAt,
        c.resolved_at AS resolvedAt
      FROM comments c
      INNER JOIN gallery_visitors v
        ON v.id = c.visitor_id
      INNER JOIN photos p
        ON p.id = c.photo_id
      INNER JOIN events e
        ON e.id = p.event_id
      WHERE
        c.id = ?
        AND c.photo_id = ?
        AND e.share_token = ?
        AND v.visitor_token = ?
    `,
  )
    .bind(commentId, photoId, shareToken, visitorToken)
    .first<PhotoCommentRecord>();
}

async function updateComment(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
  commentId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  let requestBody: UpdateCommentRequestBody;

  try {
    requestBody = await request.json<UpdateCommentRequestBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (typeof requestBody.body !== "string") {
    return jsonResponse({ error: "A comment is required." }, 400);
  }

  const body = requestBody.body.trim();

  if (body.length === 0 || body.length > 1000) {
    return jsonResponse(
      {
        error: "Your comment must be between 1 and 1000 characters.",
      },
      400,
    );
  }

  const existingComment = await findOwnedGalleryComment(
    env,
    shareToken,
    photoId,
    commentId,
    visitorToken,
  );

  if (!existingComment) {
    return jsonResponse({ error: "Comment not found." }, 404);
  }

  const updatedAt = new Date().toISOString();

  await env.DB.prepare(
    `
      UPDATE comments
      SET
        body = ?,
        updated_at = ?
      WHERE id = ?
    `,
  )
    .bind(body, updatedAt, commentId)
    .run();

  const comment: PublicPhotoCommentRecord = {
    ...existingComment,
    body,
    updatedAt,
    viewerOwned: true,
  };

  return jsonResponse({ comment });
}

async function deleteComment(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
  commentId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  const existingComment = await findOwnedGalleryComment(
    env,
    shareToken,
    photoId,
    commentId,
    visitorToken,
  );

  if (!existingComment) {
    return jsonResponse({ error: "Comment not found." }, 404);
  }

  await env.DB.prepare(
    `
      DELETE FROM comments
      WHERE id = ?
    `,
  )
    .bind(commentId)
    .run();

  return jsonResponse({
    deletedCommentId: commentId,
  });
}

async function setCommentResolution(
  request: Request,
  env: Env,
  commentId: string,
): Promise<Response> {
  let requestBody: ResolveCommentRequestBody;

  try {
    requestBody = await request.json<ResolveCommentRequestBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (typeof requestBody.resolved !== "boolean") {
    return jsonResponse(
      { error: "The resolved field must be a boolean." },
      400,
    );
  }

  const comment = await env.DB.prepare(
    `
      SELECT
        c.id,
        c.photo_id AS photoId,
        p.event_id AS eventId
      FROM comments c
      INNER JOIN photos p
        ON p.id = c.photo_id
      WHERE c.id = ?
    `,
  )
    .bind(commentId)
    .first<DashboardCommentRow>();

  if (!comment) {
    return jsonResponse({ error: "Comment not found." }, 404);
  }

  const resolvedAt = requestBody.resolved ? new Date().toISOString() : null;

  await env.DB.prepare(
    `
      UPDATE comments
      SET resolved_at = ?
      WHERE id = ?
    `,
  )
    .bind(resolvedAt, commentId)
    .run();

  return jsonResponse({
    commentId,
    photoId: comment.photoId,
    eventId: comment.eventId,
    resolvedAt,
  });
}

function isPhotoWorkflowStatus(value: unknown): value is PhotoWorkflowStatus {
  return value === "idle" || value === "editing" || value === "final";
}

async function setPhotoWorkflowStatus(
  request: Request,
  env: Env,
  photoId: string,
): Promise<Response> {
  let body: SetPhotoWorkflowBody;

  try {
    body = await request.json<SetPhotoWorkflowBody>();
  } catch {
    return jsonResponse(
      {
        error: "The request body must be valid JSON.",
      },
      400,
    );
  }

  if (!isPhotoWorkflowStatus(body.status)) {
    return jsonResponse(
      {
        error: "The status must be idle, editing, or final.",
      },
      400,
    );
  }

  const photo = await env.DB.prepare(
    `
      SELECT
        id,
        workflow_status AS workflowStatus,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE id = ?
  `,
  )
    .bind(photoId)
    .first<PhotoWorkflowRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  if (body.status === "final" && !photo.finalStorageKey) {
    return jsonResponse(
      {
        error: "Upload a final JPEG before marking this photo final.",
      },
      409,
    );
  }

  if (body.status === "final") {
    /*
     * A final photo fulfills its current edit requests.
     * Future hearts then represent a new revision request.
     */
    await env.DB.batch([
      env.DB.prepare(
        `
          UPDATE photos
          SET workflow_status = ?
          WHERE id = ?
        `,
      ).bind(body.status, photoId),

      env.DB.prepare(
        `
          DELETE FROM hearts
          WHERE photo_id = ?
        `,
      ).bind(photoId),
    ]);
  } else {
    await env.DB.prepare(
      `
        UPDATE photos
        SET workflow_status = ?
        WHERE id = ?
      `,
    )
      .bind(body.status, photoId)
      .run();
  }

  return jsonResponse({
    photoId,
    workflowStatus: body.status,
    heartCount: body.status === "final" ? 0 : await getHeartCount(env, photoId),
  });
}

async function getStoredJpeg(env: Env, storageKey: string): Promise<Response> {
  const object = await env.pickpic_photos.get(storageKey);

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

async function getFinalPhotoImage(
  env: Env,
  photoId: string,
): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<FinalPhotoKeyRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  if (!photo.finalStorageKey) {
    return jsonResponse(
      { error: "This photo does not have a final image yet." },
      404,
    );
  }

  return getStoredJpeg(env, photo.finalStorageKey);
}

async function uploadFinalPhoto(
  request: Request,
  env: Env,
  photoId: string,
): Promise<Response> {
  const photo = await env.DB.prepare(
    `
      SELECT
        event_id AS eventId,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE id = ?
    `,
  )
    .bind(photoId)
    .first<FinalPhotoUploadRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const contentType = request.headers
    .get("Content-Type")
    ?.split(";")[0]
    .trim()
    .toLowerCase();

  if (contentType !== "image/jpeg") {
    return jsonResponse(
      { error: "Only JPEG final images are supported." },
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
    return jsonResponse({ error: "The final image body is required." }, 400);
  }

  const declaredSize = Number(request.headers.get("Content-Length"));

  if (Number.isFinite(declaredSize) && declaredSize > MAX_FINAL_JPEG_BYTES) {
    return jsonResponse(
      { error: "The final JPEG must be 50 MB or smaller." },
      413,
    );
  }

  const uploadId = crypto.randomUUID();

  const newStorageKey =
    `events/${photo.eventId}/photos/${photoId}` + `/finals/${uploadId}.jpg`;

  let storedObject: R2Object;

  try {
    storedObject = await env.pickpic_photos.put(newStorageKey, request.body, {
      httpMetadata: {
        contentType: "image/jpeg",
      },
      customMetadata: {
        eventId: photo.eventId,
        photoId,
        originalFilename,
        variant: "final",
      },
    });
  } catch {
    return jsonResponse({ error: "The final image could not be stored." }, 500);
  }

  if (storedObject.size > MAX_FINAL_JPEG_BYTES) {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "The final JPEG must be 50 MB or smaller." },
      413,
    );
  }

  const uploadedAt = new Date().toISOString();

  try {
    await env.DB.batch([
      env.DB.prepare(
        `
          UPDATE photos
          SET
            final_storage_key = ?,
            final_original_filename = ?,
            final_content_type = ?,
            final_byte_size = ?,
            final_uploaded_at = ?,
            workflow_status = 'final'
          WHERE id = ?
        `,
      ).bind(
        newStorageKey,
        originalFilename,
        "image/jpeg",
        storedObject.size,
        uploadedAt,
        photoId,
      ),

      env.DB.prepare(
        `
          DELETE FROM hearts
          WHERE photo_id = ?
        `,
      ).bind(photoId),
    ]);
  } catch {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "The final photo metadata could not be saved." },
      500,
    );
  }

  if (photo.finalStorageKey && photo.finalStorageKey !== newStorageKey) {
    try {
      await env.pickpic_photos.delete(photo.finalStorageKey);
    } catch (error) {
      console.error("Unable to remove replaced final image:", error);
    }
  }

  const finalPhoto: FinalPhotoRecord = {
    originalFilename,
    contentType: "image/jpeg",
    byteSize: storedObject.size,
    uploadedAt,
    imageUrl: `/api/photos/${encodeURIComponent(photoId)}` + "/final-image",
  };

  return jsonResponse({
    photoId,
    workflowStatus: "final",
    heartCount: 0,
    finalPhoto,
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

    const photoFinalImageMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/final-image$/,
    );

    if (photoFinalImageMatch) {
      if (request.method !== "GET") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoFinalImageMatch[1]);

      return getFinalPhotoImage(env, photoId);
    }

    const photoFinalMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/final$/,
    );

    if (photoFinalMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoFinalMatch[1]);

      return uploadFinalPhoto(request, env, photoId);
    }

    const photoMatch = url.pathname.match(/^\/api\/photos\/([^/]+)$/);

    if (photoMatch) {
      if (request.method !== "DELETE") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoMatch[1]);

      return deletePhoto(env, photoId);
    }

    const galleryHeartMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/heart$/,
    );

    if (galleryHeartMatch) {
      const shareToken = decodeURIComponent(galleryHeartMatch[1]);
      const photoId = decodeURIComponent(galleryHeartMatch[2]);

      if (request.method === "PUT") {
        return addHeart(request, env, shareToken, photoId);
      }

      if (request.method === "DELETE") {
        return removeHeart(request, env, shareToken, photoId);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoHeartsMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/hearts$/,
    );

    if (photoHeartsMatch) {
      if (request.method !== "DELETE") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoHeartsMatch[1]);

      return clearPhotoHearts(env, photoId);
    }

    const galleryCommentMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/comments\/([^/]+)$/,
    );

    if (galleryCommentMatch) {
      const shareToken = decodeURIComponent(galleryCommentMatch[1]);
      const photoId = decodeURIComponent(galleryCommentMatch[2]);
      const commentId = decodeURIComponent(galleryCommentMatch[3]);

      if (request.method === "PUT") {
        return updateComment(request, env, shareToken, photoId, commentId);
      }

      if (request.method === "DELETE") {
        return deleteComment(request, env, shareToken, photoId, commentId);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const galleryCommentsMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/comments$/,
    );

    if (galleryCommentsMatch) {
      if (request.method !== "POST") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const shareToken = decodeURIComponent(galleryCommentsMatch[1]);
      const photoId = decodeURIComponent(galleryCommentsMatch[2]);

      return addComment(request, env, shareToken, photoId);
    }

    const publicGalleryMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)$/,
    );

    if (publicGalleryMatch) {
      if (request.method !== "GET") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const shareToken = decodeURIComponent(publicGalleryMatch[1]);

      return getPublicGallery(request, env, shareToken);
    }

    const dashboardCommentResolutionMatch = url.pathname.match(
      /^\/api\/comments\/([^/]+)\/resolution$/,
    );

    if (dashboardCommentResolutionMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const commentId = decodeURIComponent(dashboardCommentResolutionMatch[1]);

      return setCommentResolution(request, env, commentId);
    }

    const photoWorkflowMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/workflow$/,
    );

    if (photoWorkflowMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoWorkflowMatch[1]);

      return setPhotoWorkflowStatus(request, env, photoId);
    }

    if (url.pathname.startsWith("/api/")) {
      return jsonResponse({ error: "API route not found." }, 404);
    }

    return new Response(null, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
