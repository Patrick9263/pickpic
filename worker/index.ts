import { downloadZip } from "client-zip";
import { requireAdminAccess, type AccessEnvironment } from "./access.ts";

interface CreateEventBody {
  title?: unknown;
}

interface UpdateEventBody {
  title?: unknown;
}

type GalleryStatus = "draft" | "ready" | "completed" | "archived";

interface SetEventStatusBody {
  status?: unknown;
}

interface EventStatusRow extends EventRecord {
  status: string;
}

interface GalleryStatusRow {
  status: string;
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
  variants: ImageVariantSet;
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
  capturedAt: string | null;
  latitude: number | null;
  longitude: number | null;
  variants: ImageVariantSet;
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
  capturedAt: string | null;
  latitude: number | null;
  longitude: number | null;
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

interface DuplicatePhotoRow {
  id: string;
  duplicateVariant: "original" | "final";
}

interface PhotoUploadMetadata {
  capturedAt: string | null;
  latitude: number | null;
  longitude: number | null;
}

type PhotoUploadMetadataResult =
  | {
      metadata: PhotoUploadMetadata;
      error?: never;
    }
  | {
      metadata?: never;
      error: string;
    };

type PhotoVariantSource = "original" | "final";

type PhotoVariantKind = "thumbnail" | "preview";

interface ImageVariantRecord {
  imageUrl: string;
  contentType: string;
  byteSize: number;
  width: number;
  height: number;
  createdAt: string;
}

interface ImageVariantSet {
  thumbnail: ImageVariantRecord | null;
  preview: ImageVariantRecord | null;
}

interface PhotoVariantRow {
  photoId: string;
  sourceKind: PhotoVariantSource;
  variantKind: PhotoVariantKind;
  storageKey: string;
  contentType: string;
  byteSize: number;
  width: number;
  height: number;
  createdAt: string;
}

interface PhotoVariantsBySource {
  original: ImageVariantSet;
  final: ImageVariantSet;
}

interface VariantPhotoRow {
  eventId: string;
  finalStorageKey: string | null;
}

interface StoredVariantRow {
  storageKey: string;
}

interface DownloadGalleryRow {
  id: string;
  title: string;
  status: string;
}

interface DownloadPhotoRow {
  id: string;
  finalStorageKey: string;
  finalOriginalFilename: string;
  finalByteSize: number;
  finalUploadedAt: string;
  capturedAt: string | null;
  createdAt: string;
}

const MAX_EXPLICIT_DOWNLOAD_PHOTOS = 100;
const MAX_JPEG_BYTES = 25 * 1024 * 1024;
const MAX_FINAL_JPEG_BYTES = 50 * 1024 * 1024;
const MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024;
const MAX_PREVIEW_BYTES = 10 * 1024 * 1024;
const CAPTURED_AT_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/;

function chunkArray<T>(values: readonly T[], chunkSize: number): T[][] {
  const chunks: T[][] = [];
  for (let index = 0; index < values.length; index += chunkSize) {
    chunks.push(values.slice(index, index + chunkSize));
  }
  return chunks;
}

function sanitizeZipEntryName(filename: string): string {
  const sanitized = Array.from(filename)
    .filter((character) => {
      const characterCode = character.charCodeAt(0);

      return characterCode > 0x1f && characterCode !== 0x7f;
    })
    .join("")
    .replace(/[\\/]/g, "-")
    .trim();

  return sanitized || "photo.jpg";
}

function createUniqueZipEntryNames(filenames: string[]): string[] {
  const usedNames = new Set<string>();

  return filenames.map((filename) => {
    const sanitized = sanitizeZipEntryName(filename);
    const dotIndex = sanitized.lastIndexOf(".");
    const hasExtension = dotIndex > 0;

    const baseName = hasExtension ? sanitized.slice(0, dotIndex) : sanitized;
    const extension = hasExtension ? sanitized.slice(dotIndex) : "";

    let candidate = sanitized;
    let suffix = 2;

    while (usedNames.has(candidate.toLowerCase())) {
      candidate = `${baseName} (${suffix})${extension}`;
      suffix += 1;
    }

    usedNames.add(candidate.toLowerCase());
    return candidate;
  });
}

function createArchiveFilename(title: string): string {
  const sanitizedTitle = title
    .replace(/[^a-z0-9]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80)
    .toLowerCase();

  return `${sanitizedTitle || "pickpic-gallery"}-finals.zip`;
}

function isValidCapturedAt(value: string): boolean {
  const match = CAPTURED_AT_PATTERN.exec(value);

  if (!match) {
    return false;
  }

  const [, yearText, monthText, dayText, hourText, minuteText, secondText] =
    match;

  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);

  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));

  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day &&
    date.getUTCHours() === hour &&
    date.getUTCMinutes() === minute &&
    date.getUTCSeconds() === second
  );
}

function getPhotoUploadMetadata(request: Request): PhotoUploadMetadataResult {
  const capturedAt =
    request.headers.get("X-PickPic-Captured-At")?.trim() || null;

  if (capturedAt !== null && !isValidCapturedAt(capturedAt)) {
    return {
      error: "X-PickPic-Captured-At must use YYYY-MM-DDTHH:mm:ss.",
    };
  }

  const latitudeText =
    request.headers.get("X-PickPic-Latitude")?.trim() || null;

  const longitudeText =
    request.headers.get("X-PickPic-Longitude")?.trim() || null;

  if ((latitudeText === null) !== (longitudeText === null)) {
    return {
      error: "Latitude and longitude must be provided together.",
    };
  }

  if (latitudeText === null || longitudeText === null) {
    return {
      metadata: {
        capturedAt,
        latitude: null,
        longitude: null,
      },
    };
  }

  const latitude = Number(latitudeText);
  const longitude = Number(longitudeText);

  if (
    !Number.isFinite(latitude) ||
    latitude < -90 ||
    latitude > 90 ||
    !Number.isFinite(longitude) ||
    longitude < -180 ||
    longitude > 180
  ) {
    return {
      error: "The supplied GPS coordinates are invalid.",
    };
  }

  return {
    metadata: {
      capturedAt,
      latitude,
      longitude,
    },
  };
}

function roundPublicCoordinate(value: number | null): number | null {
  if (value === null) {
    return null;
  }

  return Math.round(value * 100) / 100;
}

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

function getSourceSha256(request: Request): string | null {
  const value = request.headers.get("X-File-SHA256")?.trim().toLowerCase();

  if (!value || !/^[0-9a-f]{64}$/.test(value)) {
    return null;
  }

  return value;
}

async function findDuplicatePhoto(
  env: Env,
  eventId: string,
  sourceSha256: string,
): Promise<DuplicatePhotoRow | null> {
  return env.DB.prepare(
    `
      SELECT
        id,
        CASE
          WHEN source_sha256 = ? THEN 'original'
          ELSE 'final'
        END AS duplicateVariant
      FROM photos
      WHERE
        event_id = ?
        AND (
          source_sha256 = ?
          OR final_sha256 = ?
        )
      LIMIT 1
    `,
  )
    .bind(sourceSha256, eventId, sourceSha256, sourceSha256)
    .first<DuplicatePhotoRow>();
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

function createEmptyVariantSet(): ImageVariantSet {
  return {
    thumbnail: null,
    preview: null,
  };
}

function createEmptyPhotoVariants(): PhotoVariantsBySource {
  return {
    original: createEmptyVariantSet(),
    final: createEmptyVariantSet(),
  };
}

function toPhotoRecord(
  row: PhotoRow,
  comments: PhotoCommentRecord[] = [],
  photoVariants: PhotoVariantsBySource = createEmptyPhotoVariants(),
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
    variants: photoVariants.original,
    finalPhoto: hasFinalPhoto
      ? {
          originalFilename: finalOriginalFilename,
          contentType: finalContentType,
          byteSize: Number(finalByteSize),
          uploadedAt: finalUploadedAt,
          imageUrl:
            `/api/photos/${encodeURIComponent(row.id)}/final-image` +
            `?v=${encodeURIComponent(finalUploadedAt)}`,
          variants: photoVariants.final,
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

function isGalleryStatus(value: unknown): value is GalleryStatus {
  return (
    value === "draft" ||
    value === "ready" ||
    value === "completed" ||
    value === "archived"
  );
}

async function setEventStatus(
  request: Request,
  env: Env,
  eventId: string,
): Promise<Response> {
  let body: SetEventStatusBody;

  try {
    body = await request.json<SetEventStatusBody>();
  } catch {
    return jsonResponse(
      {
        error: "The request body must be valid JSON.",
      },
      400,
    );
  }

  if (!isGalleryStatus(body.status)) {
    return jsonResponse(
      {
        error: "The status must be draft, ready, completed, or archived.",
      },
      400,
    );
  }

  const existingEvent = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt
      FROM events
      WHERE id = ?
    `,
  )
    .bind(eventId)
    .first<EventStatusRow>();

  if (!existingEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const updatedAt = new Date().toISOString();

  await env.DB.prepare(
    `
      UPDATE events
      SET
        status = ?,
        updated_at = ?
      WHERE id = ?
    `,
  )
    .bind(body.status, updatedAt, eventId)
    .run();

  return jsonResponse({
    event: {
      ...existingEvent,
      status: body.status,
      updatedAt,
    },
  });
}

async function requireOpenGallery(
  env: Env,
  shareToken: string,
): Promise<Response | null> {
  const event = await env.DB.prepare(
    `
      SELECT status
      FROM events
      WHERE share_token = ?
    `,
  )
    .bind(shareToken)
    .first<GalleryStatusRow>();

  if (!event || (event.status !== "ready" && event.status !== "completed")) {
    return jsonResponse({ error: "Gallery not found." }, 404);
  }

  if (event.status === "completed") {
    return jsonResponse(
      {
        error:
          "This gallery is closed and no longer accepts edit requests or comments.",
      },
      409,
    );
  }

  return null;
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

async function updateEvent(
  request: Request,
  env: Env,
  eventId: string,
): Promise<Response> {
  let body: UpdateEventBody;

  try {
    body = await request.json<UpdateEventBody>();
  } catch {
    return jsonResponse(
      {
        error: "The request body must be valid JSON.",
      },
      400,
    );
  }

  if (typeof body.title !== "string") {
    return jsonResponse(
      {
        error: "An event title is required.",
      },
      400,
    );
  }

  const title = body.title.trim();

  if (title.length === 0 || title.length > 120) {
    return jsonResponse(
      {
        error: "The event title must be between 1 and 120 characters.",
      },
      400,
    );
  }

  const existingEvent = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt
      FROM events
      WHERE id = ?
    `,
  )
    .bind(eventId)
    .first<EventRecord>();

  if (!existingEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  if (title === existingEvent.title) {
    return jsonResponse({
      event: existingEvent,
    });
  }

  const updatedAt = new Date().toISOString();

  await env.DB.prepare(
    `
      UPDATE events
      SET
        title = ?,
        updated_at = ?
      WHERE id = ?
    `,
  )
    .bind(title, updatedAt, eventId)
    .run();

  return jsonResponse({
    event: {
      ...existingEvent,
      title,
      updatedAt,
    },
  });
}

async function deleteEvent(env: Env, eventId: string): Promise<Response> {
  const event = await env.DB.prepare(
    `
      SELECT id
      FROM events
      WHERE id = ?
    `,
  )
    .bind(eventId)
    .first<{ id: string }>();

  if (!event) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const photoResult = await env.DB.prepare(
    `
      SELECT
        storage_key AS storageKey,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE event_id = ?
    `,
  )
    .bind(eventId)
    .all<StoredPhotoRow>();

  const variantResult = await env.DB.prepare(
    `
        SELECT
          v.storage_key AS storageKey
        FROM photo_variants v
        INNER JOIN photos p
          ON p.id = v.photo_id
        WHERE p.event_id = ?
      `,
  )
    .bind(eventId)
    .all<StoredVariantRow>();

  const storageKeys = Array.from(
    new Set(
      [
        ...photoResult.results.flatMap((photo) => [
          photo.storageKey,
          photo.finalStorageKey,
        ]),

        ...variantResult.results.map((variant) => variant.storageKey),
      ].filter((storageKey): storageKey is string => storageKey !== null),
    ),
  );

  try {
    for (const storageKeyChunk of chunkArray(storageKeys, 1000)) {
      await env.pickpic_photos.delete(storageKeyChunk);
    }
  } catch (error) {
    console.error("Unable to delete event images:", error);

    return jsonResponse(
      {
        error:
          "The event images could not be deleted. The event was not removed.",
      },
      500,
    );
  }

  try {
    await env.DB.prepare(
      `
        DELETE FROM events
        WHERE id = ?
      `,
    )
      .bind(eventId)
      .run();
  } catch (error) {
    console.error("Unable to delete event record:", error);

    return jsonResponse(
      {
        error:
          "The images were deleted, but the event record could not be removed.",
      },
      500,
    );
  }

  return jsonResponse({
    deleted: true,
    eventId,
  });
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

  const sourceSha256 = getSourceSha256(request);

  if (!sourceSha256) {
    return jsonResponse(
      {
        error: "A valid lowercase SHA-256 value is required in X-File-SHA256.",
      },
      400,
    );
  }

  const metadataResult = getPhotoUploadMetadata(request);

  if ("error" in metadataResult) {
    return jsonResponse({ error: metadataResult.error }, 400);
  }

  const { capturedAt, latitude, longitude } = metadataResult.metadata;

  const declaredSize = Number(request.headers.get("Content-Length"));

  if (Number.isFinite(declaredSize) && declaredSize > MAX_JPEG_BYTES) {
    return jsonResponse({ error: "The JPEG must be 25 MB or smaller." }, 413);
  }

  const duplicatePhoto = await findDuplicatePhoto(env, eventId, sourceSha256);

  if (duplicatePhoto) {
    return jsonResponse({
      duplicate: true,
      existingPhotoId: duplicatePhoto.id,
      duplicateVariant: duplicatePhoto.duplicateVariant,
    });
  }

  const photoId = crypto.randomUUID();
  const storageKey = `events/${eventId}/photos/${photoId}/preview.jpg`;

  const customMetadata: Record<string, string> = {
    eventId,
    photoId,
    originalFilename,
    sourceSha256,
  };

  if (capturedAt) {
    customMetadata.capturedAt = capturedAt;
  }

  if (latitude !== null && longitude !== null) {
    customMetadata.latitude = latitude.toString();

    customMetadata.longitude = longitude.toString();
  }

  let storedObject: R2Object;

  try {
    storedObject = await env.pickpic_photos.put(storageKey, request.body, {
      httpMetadata: {
        contentType: "image/jpeg",
      },
      customMetadata,
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
          source_sha256,
          captured_at,
          latitude,
          longitude,
          created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        sourceSha256,
        capturedAt,
        latitude,
        longitude,
        createdAt,
      )
      .run();
  } catch (error) {
    await env.pickpic_photos.delete(storageKey);

    /*
     * Another upload could have inserted the same hash after our
     * initial duplicate check.
     */
    const duplicateAfterInsert = await findDuplicatePhoto(
      env,
      eventId,
      sourceSha256,
    );

    if (duplicateAfterInsert) {
      return jsonResponse({
        duplicate: true,
        existingPhotoId: duplicateAfterInsert.id,
        duplicateVariant: duplicateAfterInsert.duplicateVariant,
      });
    }

    console.error("Unable to save photo metadata:", error);

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
    variants: createEmptyVariantSet(),
    comments: [],
    capturedAt,
    latitude,
    longitude,
  };

  return jsonResponse(
    {
      duplicate: false,
      photo,
    },
    201,
  );
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
        p.captured_at AS capturedAt,
        p.latitude,
        p.longitude,
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
        p.final_uploaded_at,
        p.captured_at,
        p.latitude,
        p.longitude
      ORDER BY
        COALESCE(p.captured_at, p.created_at) DESC,
        p.created_at DESC
  `,
  )
    .bind(eventId)
    .all<PhotoRow>();

  const commentsByPhoto = await getCommentsByPhoto(env, eventId);
  const variantsByPhoto = await getPhotoVariantsByEvent(env, eventId);
  return jsonResponse({
    photos: result.results.map((row) =>
      toPhotoRecord(
        row,
        (commentsByPhoto.get(row.id) ?? []).map(toPhotoCommentRecord),
        variantsByPhoto.get(row.id) ?? createEmptyPhotoVariants(),
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

  const variantResult = await env.DB.prepare(
    `
        SELECT
          storage_key AS storageKey
        FROM photo_variants
        WHERE photo_id = ?
      `,
  )
    .bind(photoId)
    .all<StoredVariantRow>();

  const storageKeys = [
    photo.storageKey,
    photo.finalStorageKey,
    ...variantResult.results.map((variant) => variant.storageKey),
  ].filter((key): key is string => key !== null);

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
          "The images were deleted, but the photo record could not be removed. Try again.",
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

  if (event.status !== "ready" && event.status !== "completed") {
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
        p.captured_at AS capturedAt,
        p.latitude,
        p.longitude,
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
        p.final_uploaded_at,
        p.captured_at,
        p.latitude,
        p.longitude
      ORDER BY
        COALESCE(p.captured_at, p.created_at) ASC,
        p.created_at ASC
    `,
  )
    .bind(event.id)
    .all<PhotoRow>();

  const commentsByPhoto = await getCommentsByPhoto(env, event.id);
  const variantsByPhoto = await getPhotoVariantsByEvent(env, event.id);
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
      const photo = toPhotoRecord(
        row,
        commentRows.map(toPhotoCommentRecord),
        variantsByPhoto.get(row.id) ?? createEmptyPhotoVariants(),
      );
      return {
        ...photo,

        /*
         * Public galleries receive approximate coordinates,
         * while the photographer dashboard keeps the exact values.
         */
        latitude: roundPublicCoordinate(photo.latitude),
        longitude: roundPublicCoordinate(photo.longitude),

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
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  headers.set("X-Content-Type-Options", "nosniff");

  return new Response(object.body, {
    status: 200,
    headers,
  });
}

function toImageVariantRecord(row: PhotoVariantRow): ImageVariantRecord {
  return {
    imageUrl:
      `/api/photos/${encodeURIComponent(
        row.photoId,
      )}/variants/${row.sourceKind}/${row.variantKind}` +
      `?v=${encodeURIComponent(row.createdAt)}`,
    contentType: row.contentType,
    byteSize: Number(row.byteSize),
    width: Number(row.width),
    height: Number(row.height),
    createdAt: row.createdAt,
  };
}

async function getPhotoVariantsByEvent(
  env: Env,
  eventId: string,
): Promise<Map<string, PhotoVariantsBySource>> {
  const result = await env.DB.prepare(
    `
      SELECT
        v.photo_id AS photoId,
        v.source_kind AS sourceKind,
        v.variant_kind AS variantKind,
        v.storage_key AS storageKey,
        v.content_type AS contentType,
        v.byte_size AS byteSize,
        v.width,
        v.height,
        v.created_at AS createdAt
      FROM photo_variants v
      INNER JOIN photos p
        ON p.id = v.photo_id
      WHERE p.event_id = ?
    `,
  )
    .bind(eventId)
    .all<PhotoVariantRow>();

  const variantsByPhoto = new Map<string, PhotoVariantsBySource>();

  for (const row of result.results) {
    const photoVariants =
      variantsByPhoto.get(row.photoId) ?? createEmptyPhotoVariants();

    const sourceVariants = photoVariants[row.sourceKind];

    const variant = toImageVariantRecord(row);

    if (row.variantKind === "thumbnail") {
      sourceVariants.thumbnail = variant;
    } else {
      sourceVariants.preview = variant;
    }

    variantsByPhoto.set(row.photoId, photoVariants);
  }

  return variantsByPhoto;
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

  const oldFinalVariants = await env.DB.prepare(
    `
      SELECT storage_key AS storageKey
      FROM photo_variants
      WHERE
        photo_id = ?
        AND source_kind = 'final'
    `,
  )
    .bind(photoId)
    .all<StoredVariantRow>();

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

  const finalSha256 = getSourceSha256(request);

  if (!finalSha256) {
    return jsonResponse(
      {
        error: "A valid lowercase SHA-256 value is required in X-File-SHA256.",
      },
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
        sourceSha256: finalSha256,
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
            final_sha256 = ?,
            workflow_status = 'final'
          WHERE id = ?
        `,
      ).bind(
        newStorageKey,
        originalFilename,
        "image/jpeg",
        storedObject.size,
        uploadedAt,
        finalSha256,
        photoId,
      ),

      env.DB.prepare(
        `
          DELETE FROM hearts
          WHERE photo_id = ?
        `,
      ).bind(photoId),

      env.DB.prepare(
        `
        DELETE FROM photo_variants
        WHERE
          photo_id = ?
          AND source_kind = 'final'
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

  const replacedStorageKeys = [
    photo.finalStorageKey,
    ...oldFinalVariants.results.map((variant) => variant.storageKey),
  ].filter(
    (storageKey): storageKey is string =>
      storageKey !== null && storageKey !== newStorageKey,
  );

  if (replacedStorageKeys.length > 0) {
    try {
      await env.pickpic_photos.delete(replacedStorageKeys);
    } catch (error) {
      console.error("Unable to remove replaced final images:", error);
    }
  }

  const finalPhoto: FinalPhotoRecord = {
    originalFilename,
    contentType: "image/jpeg",
    byteSize: storedObject.size,
    uploadedAt,
    imageUrl:
      `/api/photos/${encodeURIComponent(photoId)}/final-image` +
      `?v=${encodeURIComponent(uploadedAt)}`,
    variants: createEmptyVariantSet(),
  };

  return jsonResponse({
    photoId,
    workflowStatus: "final",
    heartCount: 0,
    finalPhoto,
  });
}

function getFormInteger(formData: FormData, key: string): number | null {
  const value = formData.get(key);

  if (typeof value !== "string") {
    return null;
  }

  const parsedValue = Number(value);

  if (!Number.isInteger(parsedValue) || parsedValue <= 0) {
    return null;
  }

  return parsedValue;
}

async function uploadPhotoVariants(
  request: Request,
  env: Env,
  photoId: string,
  sourceKind: PhotoVariantSource,
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
    .first<VariantPhotoRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  if (sourceKind === "final" && !photo.finalStorageKey) {
    return jsonResponse(
      {
        error: "Upload the final image before its optimized variants.",
      },
      409,
    );
  }

  let formData: FormData;

  try {
    formData = await request.formData();
  } catch {
    return jsonResponse(
      {
        error: "The optimized-image request must use multipart form data.",
      },
      400,
    );
  }

  const thumbnail = formData.get("thumbnail");
  const preview = formData.get("preview");

  const thumbnailWidth = getFormInteger(formData, "thumbnailWidth");

  const thumbnailHeight = getFormInteger(formData, "thumbnailHeight");

  const previewWidth = getFormInteger(formData, "previewWidth");

  const previewHeight = getFormInteger(formData, "previewHeight");

  if (
    !(thumbnail instanceof File) ||
    !(preview instanceof File) ||
    thumbnail.type !== "image/jpeg" ||
    preview.type !== "image/jpeg" ||
    thumbnailWidth === null ||
    thumbnailHeight === null ||
    previewWidth === null ||
    previewHeight === null
  ) {
    return jsonResponse(
      {
        error:
          "Valid thumbnail and preview JPEGs with dimensions are required.",
      },
      400,
    );
  }

  if (thumbnail.size > MAX_THUMBNAIL_BYTES) {
    return jsonResponse(
      {
        error: "The thumbnail JPEG must be 2 MB or smaller.",
      },
      413,
    );
  }

  if (preview.size > MAX_PREVIEW_BYTES) {
    return jsonResponse(
      {
        error: "The preview JPEG must be 10 MB or smaller.",
      },
      413,
    );
  }

  const oldVariants = await env.DB.prepare(
    `
      SELECT storage_key AS storageKey
      FROM photo_variants
      WHERE
        photo_id = ?
        AND source_kind = ?
    `,
  )
    .bind(photoId, sourceKind)
    .all<StoredVariantRow>();

  const uploadId = crypto.randomUUID();

  const baseStorageKey =
    `events/${photo.eventId}/photos/${photoId}` +
    `/variants/${sourceKind}/${uploadId}`;

  const thumbnailStorageKey = `${baseStorageKey}/thumbnail.jpg`;

  const previewStorageKey = `${baseStorageKey}/preview.jpg`;

  let thumbnailObject: R2Object | null = null;
  let previewObject: R2Object | null = null;

  try {
    thumbnailObject = await env.pickpic_photos.put(
      thumbnailStorageKey,
      thumbnail,
      {
        httpMetadata: {
          contentType: "image/jpeg",
        },
        customMetadata: {
          photoId,
          sourceKind,
          variantKind: "thumbnail",
        },
      },
    );

    previewObject = await env.pickpic_photos.put(previewStorageKey, preview, {
      httpMetadata: {
        contentType: "image/jpeg",
      },
      customMetadata: {
        photoId,
        sourceKind,
        variantKind: "preview",
      },
    });
  } catch {
    await env.pickpic_photos.delete([thumbnailStorageKey, previewStorageKey]);

    return jsonResponse(
      {
        error: "The optimized images could not be stored.",
      },
      500,
    );
  }

  if (!thumbnailObject || !previewObject) {
    await env.pickpic_photos.delete([thumbnailStorageKey, previewStorageKey]);

    return jsonResponse(
      {
        error: "The optimized images could not be stored.",
      },
      500,
    );
  }

  const createdAt = new Date().toISOString();

  try {
    await env.DB.batch([
      env.DB.prepare(
        `
          INSERT INTO photo_variants (
            photo_id,
            source_kind,
            variant_kind,
            storage_key,
            content_type,
            byte_size,
            width,
            height,
            created_at
          )
          VALUES (?, ?, 'thumbnail', ?, 'image/jpeg', ?, ?, ?, ?)
          ON CONFLICT (
            photo_id,
            source_kind,
            variant_kind
          )
          DO UPDATE SET
            storage_key = excluded.storage_key,
            content_type = excluded.content_type,
            byte_size = excluded.byte_size,
            width = excluded.width,
            height = excluded.height,
            created_at = excluded.created_at
        `,
      ).bind(
        photoId,
        sourceKind,
        thumbnailStorageKey,
        thumbnailObject.size,
        thumbnailWidth,
        thumbnailHeight,
        createdAt,
      ),

      env.DB.prepare(
        `
          INSERT INTO photo_variants (
            photo_id,
            source_kind,
            variant_kind,
            storage_key,
            content_type,
            byte_size,
            width,
            height,
            created_at
          )
          VALUES (?, ?, 'preview', ?, 'image/jpeg', ?, ?, ?, ?)
          ON CONFLICT (
            photo_id,
            source_kind,
            variant_kind
          )
          DO UPDATE SET
            storage_key = excluded.storage_key,
            content_type = excluded.content_type,
            byte_size = excluded.byte_size,
            width = excluded.width,
            height = excluded.height,
            created_at = excluded.created_at
        `,
      ).bind(
        photoId,
        sourceKind,
        previewStorageKey,
        previewObject.size,
        previewWidth,
        previewHeight,
        createdAt,
      ),
    ]);
  } catch {
    await env.pickpic_photos.delete([thumbnailStorageKey, previewStorageKey]);

    return jsonResponse(
      {
        error: "The optimized-image metadata could not be saved.",
      },
      500,
    );
  }

  const newStorageKeys = new Set([thumbnailStorageKey, previewStorageKey]);
  const replacedStorageKeys = oldVariants.results
    .map((variant) => variant.storageKey)
    .filter((storageKey) => !newStorageKeys.has(storageKey));

  if (replacedStorageKeys.length > 0) {
    try {
      await env.pickpic_photos.delete(replacedStorageKeys);
    } catch (error) {
      console.error("Unable to remove replaced variants:", error);
    }
  }

  const variants: ImageVariantSet = {
    thumbnail: {
      imageUrl:
        `/api/photos/${encodeURIComponent(
          photoId,
        )}/variants/${sourceKind}/thumbnail` +
        `?v=${encodeURIComponent(createdAt)}`,
      contentType: "image/jpeg",
      byteSize: thumbnailObject.size,
      width: thumbnailWidth,
      height: thumbnailHeight,
      createdAt,
    },
    preview: {
      imageUrl:
        `/api/photos/${encodeURIComponent(
          photoId,
        )}/variants/${sourceKind}/preview` +
        `?v=${encodeURIComponent(createdAt)}`,
      contentType: "image/jpeg",
      byteSize: previewObject.size,
      width: previewWidth,
      height: previewHeight,
      createdAt,
    },
  };

  return jsonResponse({
    photoId,
    sourceKind,
    variants,
  });
}

async function getPhotoVariantImage(
  env: Env,
  photoId: string,
  sourceKind: PhotoVariantSource,
  variantKind: PhotoVariantKind,
): Promise<Response> {
  const variant = await env.DB.prepare(
    `
      SELECT storage_key AS storageKey
      FROM photo_variants
      WHERE
        photo_id = ?
        AND source_kind = ?
        AND variant_kind = ?
    `,
  )
    .bind(photoId, sourceKind, variantKind)
    .first<StoredVariantRow>();

  if (!variant) {
    return jsonResponse(
      {
        error: "The requested image variant was not found.",
      },
      404,
    );
  }

  return getStoredJpeg(env, variant.storageKey);
}

async function downloadGalleryFinals(
  request: Request,
  env: Env,
  shareToken: string,
): Promise<Response> {
  const url = new URL(request.url);
  const scope = url.searchParams.get("scope");
  const photoIdsParameter = url.searchParams.get("photoIds");

  if (
    (scope !== null && photoIdsParameter !== null) ||
    (scope === null && photoIdsParameter === null)
  ) {
    return jsonResponse(
      {
        error: "Provide either a download scope or a list of photo IDs.",
      },
      400,
    );
  }

  if (scope !== null && scope !== "all" && scope !== "liked") {
    return jsonResponse(
      { error: "The download scope must be all or liked." },
      400,
    );
  }

  const event = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        status
      FROM events
      WHERE share_token = ?
    `,
  )
    .bind(shareToken)
    .first<DownloadGalleryRow>();

  if (!event || (event.status !== "ready" && event.status !== "completed")) {
    return jsonResponse({ error: "Gallery not found." }, 404);
  }

  let photoRows: DownloadPhotoRow[];

  const basePhotoSelection = `
    SELECT
      p.id,
      p.final_storage_key AS finalStorageKey,
      p.final_original_filename AS finalOriginalFilename,
      p.final_byte_size AS finalByteSize,
      p.final_uploaded_at AS finalUploadedAt,
      p.captured_at AS capturedAt,
      p.created_at AS createdAt
    FROM photos p
  `;

  const finalPhotoConditions = `
    p.event_id = ?
    AND p.final_storage_key IS NOT NULL
    AND p.final_original_filename IS NOT NULL
    AND p.final_byte_size IS NOT NULL
    AND p.final_uploaded_at IS NOT NULL
  `;

  const photoOrdering = `
    ORDER BY
      COALESCE(p.captured_at, p.created_at) ASC,
      p.created_at ASC
  `;

  if (scope === "all") {
    const result = await env.DB.prepare(
      `
        ${basePhotoSelection}
        WHERE ${finalPhotoConditions}
        ${photoOrdering}
      `,
    )
      .bind(event.id)
      .all<DownloadPhotoRow>();

    photoRows = result.results;
  } else if (scope === "liked") {
    const result = await env.DB.prepare(
      `
        ${basePhotoSelection}
        WHERE ${finalPhotoConditions}
          AND EXISTS (
            SELECT 1
            FROM hearts h
            WHERE h.photo_id = p.id
          )
        ${photoOrdering}
      `,
    )
      .bind(event.id)
      .all<DownloadPhotoRow>();

    photoRows = result.results;
  } else {
    const photoIds = Array.from(
      new Set(
        (photoIdsParameter ?? "")
          .split(",")
          .map((photoId) => photoId.trim())
          .filter(Boolean),
      ),
    );

    if (
      photoIds.length === 0 ||
      photoIds.length > MAX_EXPLICIT_DOWNLOAD_PHOTOS
    ) {
      return jsonResponse(
        {
          error: `Select between 1 and ${MAX_EXPLICIT_DOWNLOAD_PHOTOS} individual photos.`,
        },
        400,
      );
    }

    if (
      photoIds.some(
        (photoId) => photoId.length > 100 || !/^[a-z0-9-]+$/i.test(photoId),
      )
    ) {
      return jsonResponse({ error: "One or more photo IDs are invalid." }, 400);
    }

    const placeholders = photoIds.map(() => "?").join(", ");

    const result = await env.DB.prepare(
      `
        ${basePhotoSelection}
        WHERE ${finalPhotoConditions}
          AND p.id IN (${placeholders})
        ${photoOrdering}
      `,
    )
      .bind(event.id, ...photoIds)
      .all<DownloadPhotoRow>();

    photoRows = result.results;

    if (photoRows.length !== photoIds.length) {
      return jsonResponse(
        {
          error:
            "One or more selected photos are unavailable or do not have a final image.",
        },
        400,
      );
    }
  }

  if (photoRows.length === 0) {
    return jsonResponse(
      { error: "No final photos are available to download." },
      404,
    );
  }

  const zipEntryNames = createUniqueZipEntryNames(
    photoRows.map((photo) => photo.finalOriginalFilename),
  );

  async function* createZipInputs() {
    for (const [index, photo] of photoRows.entries()) {
      const object = await env.pickpic_photos.get(photo.finalStorageKey);

      if (!object) {
        throw new Error(
          `Final image ${photo.id} could not be found in storage.`,
        );
      }

      yield {
        name: zipEntryNames[index],
        lastModified: new Date(photo.finalUploadedAt),
        input: object.body,
      };
    }
  }

  const zipResponse = downloadZip(createZipInputs(), {
    metadata: photoRows.map((photo, index) => ({
      name: zipEntryNames[index],
      size: Number(photo.finalByteSize),
      lastModified: new Date(photo.finalUploadedAt),
    })),
  });

  const headers = new Headers(zipResponse.headers);

  headers.set("Content-Type", "application/zip");
  headers.set(
    "Content-Disposition",
    `attachment; filename="${createArchiveFilename(event.title)}"`,
  );
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");

  return new Response(zipResponse.body, {
    status: 200,
    headers,
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/api/admin/")) {
      const accessResponse = await requireAdminAccess(
        request,
        env as Env & AccessEnvironment,
      );

      if (accessResponse) {
        return accessResponse;
      }
    }

    if (url.pathname === "/api/admin/events") {
      if (request.method === "POST") {
        return createEvent(request, env);
      }

      if (request.method === "GET") {
        return listEvents(env);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const adminEventMatch = url.pathname.match(
      /^\/api\/admin\/events\/([^/]+)$/,
    );

    if (adminEventMatch) {
      const eventId = decodeURIComponent(adminEventMatch[1]);

      if (request.method === "PUT") {
        return updateEvent(request, env, eventId);
      }

      if (request.method === "DELETE") {
        return deleteEvent(env, eventId);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const adminEventStatusMatch = url.pathname.match(
      /^\/api\/admin\/events\/([^/]+)\/status$/,
    );

    if (adminEventStatusMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const eventId = decodeURIComponent(adminEventStatusMatch[1]);

      return setEventStatus(request, env, eventId);
    }

    const eventPhotosMatch = url.pathname.match(
      /^\/api\/admin\/events\/([^/]+)\/photos$/,
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
      /^\/api\/admin\/photos\/([^/]+)\/final$/,
    );

    if (photoFinalMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoFinalMatch[1]);

      return uploadFinalPhoto(request, env, photoId);
    }

    const photoMatch = url.pathname.match(/^\/api\/admin\/photos\/([^/]+)$/);

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

    const galleryMutationMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)\/photos\/[^/]+\/(?:heart|comments(?:\/[^/]+)?)$/,
    );

    if (galleryMutationMatch && request.method !== "GET") {
      const shareToken = decodeURIComponent(galleryMutationMatch[1]);

      const galleryGuard = await requireOpenGallery(env, shareToken);

      if (galleryGuard) {
        return galleryGuard;
      }
    }

    const photoHeartsMatch = url.pathname.match(
      /^\/api\/admin\/photos\/([^/]+)\/hearts$/,
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

    const galleryDownloadMatch = url.pathname.match(
      /^\/api\/galleries\/([^/]+)\/download$/,
    );

    if (galleryDownloadMatch) {
      if (request.method !== "GET") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const shareToken = decodeURIComponent(galleryDownloadMatch[1]);

      return downloadGalleryFinals(request, env, shareToken);
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

    const photoWorkflowMatch = url.pathname.match(
      /^\/api\/admin\/photos\/([^/]+)\/workflow$/,
    );

    if (photoWorkflowMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      const photoId = decodeURIComponent(photoWorkflowMatch[1]);

      return setPhotoWorkflowStatus(request, env, photoId);
    }

    const adminVariantUploadMatch = url.pathname.match(
      /^\/api\/admin\/photos\/([^/]+)\/variants\/(original|final)$/,
    );

    if (adminVariantUploadMatch) {
      if (request.method !== "PUT") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      return uploadPhotoVariants(
        request,
        env,
        decodeURIComponent(adminVariantUploadMatch[1]),
        adminVariantUploadMatch[2] as PhotoVariantSource,
      );
    }

    const publicVariantMatch = url.pathname.match(
      /^\/api\/photos\/([^/]+)\/variants\/(original|final)\/(thumbnail|preview)$/,
    );

    if (publicVariantMatch) {
      if (request.method !== "GET") {
        return jsonResponse({ error: "Method not allowed." }, 405);
      }

      return getPhotoVariantImage(
        env,
        decodeURIComponent(publicVariantMatch[1]),
        publicVariantMatch[2] as PhotoVariantSource,
        publicVariantMatch[3] as PhotoVariantKind,
      );
    }

    if (url.pathname.startsWith("/api/")) {
      return jsonResponse({ error: "API route not found." }, 404);
    }

    return new Response(null, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
