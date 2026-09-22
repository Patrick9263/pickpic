import {
  handleAuthRequest,
  normalizeEmail,
  requireAdminPrincipal,
  type AuthEnvironment,
} from "./auth.ts";
import { generateAuthToken, hashAuthToken } from "./session.ts";
import {
  escapeHtml,
  sendGalleryEmail,
  type EmailEnvironment,
} from "./email.ts";
import {
  buildAppleAppSiteAssociation,
  type AppleEnvironment,
} from "./apple.ts";
import {
  resolveAccountDatabase,
  resolveAccountForPrincipal,
  type AccountRecord,
} from "./accounts.ts";
import {
  isLocalRequest,
  requireOwnerRole,
  type AdminPrincipal,
} from "./access.ts";
import { handleOperatorRequest, requireOperatorPrincipal } from "./operator.ts";
import {
  scheduleUploadStartedNotification,
  scheduleRawRequestNotification,
} from "./telegram.ts";
import {
  createAccountScope,
  type AccountScope,
  type TenantEnv,
} from "./tenancy.ts";

const ADMIN_PHOTO_IMAGE_BASE = "/api/admin/photos";

function galleryPhotoImageBase(shareToken: string): string {
  return `/api/galleries/${encodeURIComponent(shareToken)}/photos`;
}

interface CreateEventBody {
  title?: unknown;
  id?: unknown;
}

interface UpdateEventBody {
  title?: unknown;
}

interface UpdateAccountBody {
  name?: unknown;
  rawDeliveryTtlMs?: unknown;
}

type GalleryStatus = "draft" | "ready" | "completed" | "archived";

interface SetEventStatusBody {
  status?: unknown;
}

interface EventStatusRow extends EventQueryRow {
  status: string;
}

interface GalleryStatusRow {
  status: string;
}

interface HeartRequestBody {
  displayName?: unknown;
}

interface RawRequestRequestBody {
  displayName?: unknown;
  email?: unknown;
}

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
  rawRequestsEnabled: boolean;

  /*
   * Whether any photo in this event has ever had a RAW request (#266) --
   * distinct from rawRequestsEnabled, which is just the current opt-in
   * toggle. Drives hiding the "Release collected RAW files" control for the
   * common case of an event that has never used RAW requests at all.
   */
  hasRawRequests: boolean;
}

/*
 * D1 has no boolean column type -- raw_requests_enabled and the EXISTS below
 * come back as 0/1. Every SELECT that builds an EventRecord reads into this
 * shape first, then converts through toEventRecord() so real JS booleans are
 * what ever reach a JSON response.
 */
type EventQueryRow = Omit<
  EventRecord,
  "rawRequestsEnabled" | "hasRawRequests"
> & {
  rawRequestsEnabled: number;
  hasRawRequests: number;
};

function toEventRecord(row: EventQueryRow): EventRecord {
  return {
    ...row,
    rawRequestsEnabled: Boolean(row.rawRequestsEnabled),
    hasRawRequests: Boolean(row.hasRawRequests),
  };
}

interface SetEventRawRequestsEnabledBody {
  enabled?: unknown;
}

interface EventStorageRow {
  eventId: string;
  title: string;
  status: string;
  photoCount: number;
  finalCount: number;
  rawCount: number;
  proofBytes: number;
  finalBytes: number;
  rawBytes: number;
}

interface EventVariantStorageRow {
  eventId: string;
  variantCount: number;
  variantBytes: number;
}

interface EventStorageRecord {
  eventId: string;
  title: string;
  status: string;
  photoCount: number;
  finalCount: number;
  variantCount: number;
  rawCount: number;
  proofBytes: number;
  finalBytes: number;
  variantBytes: number;
  rawBytes: number;
  totalBytes: number;
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

interface RawPhotoRecord {
  originalFilename: string;
  contentType: string;
  byteSize: number;
  uploadedAt: string;
}

/*
 * RAW delivery state is deliberately *not* on PhotoRecord. PublicPhotoRecord
 * extends it (see below) and the public gallery builds through the same
 * toPhotoRecord, so a field added there ships to every gallery visitor by
 * accident. What the gallery exposes about a delivered RAW -- and whether it
 * exposes anything at all before the download route exists -- belongs to #209.
 * Until then this stays on the admin side, where only the iPad reads it.
 */
interface AdminPhotoRecord extends PhotoRecord {
  pendingRawRequestCount: number;

  /*
   * Fulfilled requests nobody has downloaded or had released -- also the
   * population #221's cancel action targets (see cancelUndeliveredRawRequests
   * below). Zero whenever raw_storage_key is null, since a request only gets
   * fulfilled_at stamped once the RAW actually lands (addRawRequest,
   * uploadRawPhoto).
   */
  awaitingRawDownloadCount: number;
  rawPhoto: RawPhotoRecord | null;
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

interface AdminPhotoRow extends PhotoRow {
  pendingRawRequestCount: number;
  awaitingRawDownloadCount: number;
  rawOriginalFilename: string | null;
  rawContentType: string | null;
  rawByteSize: number | null;
  rawUploadedAt: string | null;
}

interface StoredPhotoRow {
  storageKey: string;
  finalStorageKey: string | null;
  rawStorageKey: string | null;
  byteSize: number;
  finalByteSize: number | null;
  rawByteSize: number | null;
}

interface FinalPhotoUploadRow {
  eventId: string;
  finalStorageKey: string | null;
  finalByteSize: number | null;
}

interface RawPhotoUploadRow {
  eventId: string;
  rawStorageKey: string | null;
  rawByteSize: number | null;
}

interface FinalPhotoKeyRow {
  finalStorageKey: string | null;
}

interface PublicGalleryEvent {
  title: string;
  status: string;
  createdAt: string;
  rawRequestsEnabled: boolean;
}

interface PublicGalleryEventRow extends Omit<
  PublicGalleryEvent,
  "rawRequestsEnabled"
> {
  id: string;
  rawDeliveryTtlMs: number;
  rawRequestsEnabled: number;
}

/*
 * What a gallery visitor is told about a RAW that is sitting in R2 waiting for
 * them. Only ever populated for the visitor whose own raw_requests row was
 * fulfilled -- it is built in getPublicGallery's mapper from a visitor-scoped
 * query, never in toPhotoRecord, for the reason spelled out above
 * AdminPhotoRecord.
 *
 * byteSize is here because the gallery is mobile-first and this is the one
 * download in the product measured in hundreds of megabytes: "Download RAW"
 * and "Download RAW (118 MB)" are different decisions on cellular.
 */
interface ViewerRawDownloadRecord {
  filename: string;
  byteSize: number;
  expiresAt: string;
}

interface PublicPhotoRecord extends Omit<PhotoRecord, "comments"> {
  comments: PublicPhotoCommentRecord[];
  viewerHearted: boolean;
  viewerRequestedRaw: boolean;

  /*
   * Null both before the RAW arrives and after it has been reclaimed, which is
   * why viewerRawDownloadedAt has to exist separately: without it those two
   * states are indistinguishable and a collected download renders as "still
   * waiting". No aggregate is exposed here -- a viewer sees their own request
   * state and nothing about anyone else's (#206).
   */
  viewerRawDownload: ViewerRawDownloadRecord | null;
  viewerRawDownloadedAt: string | null;

  /*
   * The address this viewer's own request carries, shown back to them so a typo
   * is visible and correctable (#224). Scoped to their own row exactly like the
   * fields above, so it can never surface somebody else's address -- which is
   * also why it stays null for a second browser that has attached to a row it
   * does not own.
   */
  viewerRawRequestEmail: string | null;

  /*
   * True between asking and clicking the confirmation link. It has to come from
   * the server rather than component state because the whole point of that step
   * is that the viewer leaves for their mail app and comes back to a reloaded
   * page.
   */
  viewerRawConfirmationPending: boolean;
}

interface PublicGalleryResponse {
  event: PublicGalleryEvent;
  photos: PublicPhotoRecord[];
}

interface GalleryPhotoRow {
  photoId: string;
  eventId: string;
  storageKey: string;
  finalStorageKey: string | null;
  originalFilename: string;
  eventTitle: string;
  shareToken: string;
  rawRequestsEnabled: number;
  rawStorageKey: string | null;
  rawOriginalFilename: string | null;
  rawContentType: string | null;
  rawByteSize: number | null;
  rawDeliveryTtlMs: number;
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

interface RawRequestedPhotoRow {
  photoId: string;
  email: string | null;
  fulfilledAt: string | null;
  downloadedAt: string | null;
  rawStorageKey: string | null;
  rawOriginalFilename: string | null;
  rawByteSize: number | null;
}

interface PendingConfirmationPhotoRow {
  photoId: string;
  email: string;
}

/*
 * One existing raw_requests row, in the shape addRawRequest's resolution needs.
 * visitorId is here because attaching to an address's existing row deliberately
 * keeps that row's original visitor rather than moving it to whoever asked
 * last.
 */
interface RawRequestResolutionRow {
  visitorId: string;
  email: string | null;
  fulfilledAt: string | null;
  downloadedAt: string | null;
}

interface RawConfirmationRow {
  id: string;
  eventId: string;
  photoId: string;
  email: string;
  visitorToken: string;
  displayName: string;
  expiresAt: string;
}

/*
 * What the "your RAW is ready" mail needs, gathered in one query per photo
 * rather than per recipient.
 */
interface RawDeliveryRecipientRow {
  visitorId: string;
  email: string;
  displayName: string;
  eventTitle: string;
  shareToken: string;
  filename: string;
}

/*
 * Everything the reclaim decision needs about one photo's RAW, folded into a
 * single row so the check is one query rather than one per requester.
 * liveRequestCount counts rows that still exist -- a visitor who withdraws is
 * DELETEd outright (removeRawRequest), so "withdrew" and "never asked" are the
 * same state here, which is exactly what makes the zero-requester case
 * reclaimable immediately.
 */
/*
 * The subset toViewerRawDownload needs, structural rather than nominal so the
 * two callers can pass what they already have -- findPhotoInShare's row on the
 * request path, and the visitor-scoped raw_requests join on the gallery path.
 */
interface RawDownloadSource {
  originalFilename: string;
  rawStorageKey: string | null;
  rawOriginalFilename: string | null;
  rawByteSize: number | null;
}

interface RawRequestOwnerRow {
  visitorId: string;
  fulfilledAt: string | null;
}

interface RawReclaimRow {
  photoId: string;
  accountId: string;
  rawDeliveryTtlMs: number;
  rawStorageKey: string;
  rawByteSize: number | null;
  liveRequestCount: number;
  awaitingCount: number;
  unreleasedCount: number;
  lastFulfilledAt: string | null;
  lastDownloadedAt: string | null;
}

interface RawReleaseCandidateRow {
  photoId: string;
  awaitingCount: number;
  unreleasedCount: number;
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

interface PreflightRequestBody {
  filenames?: unknown;
}

interface PreflightMatchRow {
  id: string;
  filename: string;
  sourceSha256: string | null;
  finalSha256: string | null;
}

interface PreflightMatch {
  filename: string;
  photoId: string;
  sourceSha256: string | null;
  finalSha256: string | null;
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
  byteSize: number;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const MAX_JPEG_BYTES = 25 * 1024 * 1024;

const MAX_PREFLIGHT_FILENAMES = 2000;

const PREFLIGHT_CHUNK_SIZE = 90;
const MAX_FINAL_JPEG_BYTES = 50 * 1024 * 1024;

/*
 * Deliberately not MAX_FINAL_JPEG_BYTES: a lossless-compressed A7R V .ARW is
 * 60-80 MB and an uncompressed one around 120 MB, so a RAW is 10-20x the proof
 * JPEG that photos.byte_size measures (trap 6).
 *
 * Pinned to Cloudflare's own ceiling rather than set independently of it.
 * Cloudflare caps a Worker's *incoming request body* by zone plan -- 100 MB on
 * Free and Pro, 200 MB on Business -- and that rejection happens at the edge,
 * before this handler runs, with Cloudflare's own error page rather than our
 * JSON. Setting this any higher than the zone's cap (as it used to be, at 128
 * MB -- see #215) creates a dead band where every layer here believes an
 * upload is legal and only the edge disagrees, so the RAW is rejected only
 * after the photographer's connection has spent minutes uploading it. Keep
 * RawUploadFileService.maximumRawBytes in the iPad app equal to this value.
 */
const MAX_RAW_BYTES = 100 * 1024 * 1024;

const RAW_CONTENT_TYPE = "application/octet-stream";

/*
 * Named rather than inlined because the same sentence has to come back from
 * both the declared-size precheck and the stored-size re-check, and the iPad
 * shows it verbatim. Built from MAX_RAW_BYTES rather than a separate literal
 * so the two can't drift apart the next time the limit changes.
 */
const RAW_TOO_LARGE_MESSAGE = `The RAW file must be ${MAX_RAW_BYTES / (1024 * 1024)} MB or smaller.`;

/*
 * The two halves of the reclaim policy (#209). A delivered RAW is the single
 * largest thing this system stores -- 10-20x the proof JPEG -- so it is held
 * only as long as somebody is plausibly still going to collect it, and neither
 * half alone gives that.
 *
 * Reclaiming purely on "everyone downloaded it" is unbounded: one visitor who
 * requests a RAW and never opens the gallery again pins ~120 MB against the
 * account's cap forever. Reclaiming purely on a TTL wastes the common case,
 * where the only requester collects within minutes and the bytes then sit for
 * the full window. So both run, whichever fires first.
 *
 * The grace period exists because the download route cannot observe a
 * *completed* transfer, only a started one (see migration 0021). A visitor
 * whose download dies partway has until the next day to retry before the
 * object goes; without it, a dropped connection on a phone would cost a fresh
 * upload of the original from the iPad.
 *
 * Because the grace period is a proxy for a fact the server cannot observe,
 * the photographer can supply that fact directly and skip it --
 * releaseCollectedRawPhotos (#219) marks the collected requests released and
 * isRawReclaimable honours the marker ahead of this constant.
 *
 * The TTL is measured from the newest fulfilled_at rather than from
 * raw_uploaded_at so that a visitor who requests a photo whose RAW is already
 * sitting there gets a full window of their own, instead of inheriting the
 * tail of someone else's.
 */
const RAW_DOWNLOAD_GRACE_MS = 24 * 60 * 60 * 1000;

/*
 * Bounds for the per-account raw_delivery_ttl_ms column (#225, migration
 * 0024). The minimum must stay strictly above RAW_DOWNLOAD_GRACE_MS, or a TTL
 * shorter than the grace period would always win and the grace period would
 * stop existing. Keep in sync with the CHECK constraint in that migration and
 * the mirrored bounds in AccountSettingsPage.tsx.
 */
const RAW_DELIVERY_TTL_MIN_MS = 2 * 24 * 60 * 60 * 1000;
const RAW_DELIVERY_TTL_MAX_MS = 90 * 24 * 60 * 60 * 1000;

/*
 * How long a viewer has to click the confirmation link (#224). Far longer than
 * a sign-in link's minutes, deliberately: this grants no session and no
 * authority beyond being mailed a download link for a gallery whose share link
 * the holder already has, and a guest who reads their mail that evening should
 * not have to start the request over.
 */
const RAW_CONFIRMATION_TTL_MS = 24 * 60 * 60 * 1000;

/*
 * Anyone holding a share link can cause gallery mail to be sent to an address
 * they typed, so these caps are the only thing between a public gallery and a
 * mail amplifier pointed at the domain every customer's sign-in deliverability
 * depends on.
 *
 * Two-sided on purpose. The per-address cap alone bounds nothing -- fifty
 * different addresses are fifty fresh budgets -- so the per-visitor cap is the
 * one that actually stops amplification, while the per-address cap is what
 * stops one address being buried by requests across many photos. Both are sized
 * to leave room for a genuine correction or a guest collecting several RAWs
 * from one shoot.
 */
const RAW_EMAIL_CAP_WINDOW_MS = 24 * 60 * 60 * 1000;
const RAW_EMAIL_CAP_PER_ADDRESS = 12;
const RAW_EMAIL_CAP_PER_VISITOR = 12;

/*
 * Hardcoded rather than derived from the incoming request, matching
 * PUBLIC_GALLERY_BASE_URL in telegram.ts and for the same reason: the delivery
 * mail is sent from whichever worker fulfils the request, and for the iPad's
 * upload path that is admin.pickpic.photos or app.pickpic.photos. A link built
 * from the request's own origin would point a gallery viewer at an origin that
 * will not serve them.
 */
const PUBLIC_GALLERY_ORIGIN = "https://pickpic.photos";

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

export function roundPublicCoordinate(value: number | null): number | null {
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

/*
 * A literal `null` body is valid JSON, so it clears a bare try/catch around
 * request.json() -- every call site's first property read then throws a
 * TypeError instead of returning the 400 it meant to. Centralized here so a
 * new route can't forget the check.
 */
async function parseJsonObjectBody<T extends object>(
  request: Request,
  invalidBodyMessage: string,
): Promise<T | Response> {
  let body: T | null;

  try {
    body = await request.json<T | null>();
  } catch {
    return jsonResponse({ error: invalidBodyMessage }, 400);
  }

  if (body === null || typeof body !== "object") {
    return jsonResponse({ error: invalidBodyMessage }, 400);
  }

  return body;
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

/*
 * A photo counts as a duplicate when the incoming source hash matches
 * either the stored original hash or the stored final hash, scoped to a
 * single event.
 *
 * This rule is mirrored client-side by the iPad preflight check, which
 * compares against both hashes returned by preflightPhotos below. Keep
 * the two in sync: preflight is only an optimisation, and this function
 * remains the authoritative check.
 */
export async function findDuplicatePhoto(
  scope: AccountScope,
  eventId: string,
  sourceSha256: string,
): Promise<DuplicatePhotoRow | null> {
  return scope.database
    .prepare(
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

/*
 * Duplicate preflight.
 *
 * The iPad sends the RAW filenames it is about to convert. We return the
 * stored hashes for any filename this event already knows about, so the
 * client can hash just those few files locally and skip converting them.
 *
 * Filenames alone are not sufficient evidence: Sony bodies reset frame
 * counters, so DSC01015.ARW legitimately recurs across cards. The client
 * therefore confirms by hash before skipping anything.
 */
async function preflightPhotos(
  request: Request,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  if (!(await eventExists(scope, eventId))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  let body: PreflightRequestBody;

  try {
    body = (await request.json()) as PreflightRequestBody;
  } catch {
    return jsonResponse({ error: "A JSON body is required." }, 400);
  }

  const requestedFilenames = body?.filenames;

  if (!Array.isArray(requestedFilenames)) {
    return jsonResponse({ error: "A filenames array is required." }, 400);
  }

  if (requestedFilenames.length > MAX_PREFLIGHT_FILENAMES) {
    return jsonResponse(
      {
        error: `At most ${MAX_PREFLIGHT_FILENAMES} filenames may be checked at once.`,
      },
      400,
    );
  }

  const filenames = Array.from(
    new Set(
      requestedFilenames.filter(
        (filename): filename is string =>
          typeof filename === "string" &&
          filename.length > 0 &&
          filename.length <= 255 &&
          !filename.includes("\0"),
      ),
    ),
  );

  if (filenames.length === 0) {
    return jsonResponse({ matches: [] });
  }

  const matches: PreflightMatch[] = [];

  /*
   * Chunked to stay well inside D1's bound-parameter limit.
   */
  for (let index = 0; index < filenames.length; index += PREFLIGHT_CHUNK_SIZE) {
    const chunk = filenames.slice(index, index + PREFLIGHT_CHUNK_SIZE);

    const placeholders = chunk.map(() => "?").join(", ");

    const result = await scope.database
      .prepare(
        `
        SELECT
          id,
          original_filename AS filename,
          source_sha256 AS sourceSha256,
          final_sha256 AS finalSha256
        FROM photos
        WHERE
          event_id = ?
          AND original_filename IN (${placeholders})
      `,
      )
      .bind(eventId, ...chunk)
      .all<PreflightMatchRow>();

    for (const row of result.results) {
      matches.push({
        filename: row.filename,
        photoId: row.id,
        sourceSha256: row.sourceSha256,
        finalSha256: row.finalSha256,
      });
    }
  }

  return jsonResponse({ matches });
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

/*
 * WHATWG URL leaves an invalid percent-escape untouched in pathname instead of
 * rejecting it, so a malformed segment (e.g. "%zz") still matches a route's
 * regex and reaches here. Every route-parameter decode goes through this so a
 * bad escape 404s like any other missing resource instead of throwing a
 * URIError that falls through to routeRequest's catch as a generic 500.
 */
export function safeDecodePathSegment(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
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

/*
 * imageBasePath is `/api/admin/photos` for the dashboard or
 * `/api/galleries/{shareToken}/photos` for a public gallery -- the two
 * callers of this function, which is why it's threaded through here rather
 * than hardcoded.
 */
function toPhotoRecord(
  row: PhotoRow,
  imageBasePath: string,
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
    imageUrl: `${imageBasePath}/${encodeURIComponent(row.id)}/image`,
    variants: photoVariants.original,
    finalPhoto: hasFinalPhoto
      ? {
          originalFilename: finalOriginalFilename,
          contentType: finalContentType,
          byteSize: Number(finalByteSize),
          uploadedAt: finalUploadedAt,
          imageUrl:
            `${imageBasePath}/${encodeURIComponent(row.id)}/final-image` +
            `?v=${encodeURIComponent(finalUploadedAt)}`,
          variants: photoVariants.final,
        }
      : null,
    comments,
  };
}

/*
 * The admin-only wrapper around toPhotoRecord. Kept as a separate function
 * rather than folded into it so the public gallery response shape cannot drift
 * onto the RAW fields by accident -- see the comment on AdminPhotoRecord.
 */
function toAdminPhotoRecord(
  row: AdminPhotoRow,
  imageBasePath: string,
  comments: PhotoCommentRecord[] = [],
  photoVariants: PhotoVariantsBySource = createEmptyPhotoVariants(),
): AdminPhotoRecord {
  const {
    pendingRawRequestCount,
    awaitingRawDownloadCount,
    rawOriginalFilename,
    rawContentType,
    rawByteSize,
    rawUploadedAt,
    ...photoRow
  } = row;

  const hasRawPhoto =
    rawOriginalFilename !== null &&
    rawContentType !== null &&
    rawByteSize !== null &&
    rawUploadedAt !== null;

  return {
    ...toPhotoRecord(photoRow, imageBasePath, comments, photoVariants),
    pendingRawRequestCount: Number(pendingRawRequestCount ?? 0),
    awaitingRawDownloadCount: Number(awaitingRawDownloadCount ?? 0),
    rawPhoto: hasRawPhoto
      ? {
          originalFilename: rawOriginalFilename,
          contentType: rawContentType,
          byteSize: Number(rawByteSize),
          uploadedAt: rawUploadedAt,
        }
      : null,
  };
}

async function openDraftEventForUpload(
  scope: AccountScope,
  eventId: string,
): Promise<void> {
  const updatedAt = new Date().toISOString();

  await scope.database
    .prepare(
      `
      UPDATE events
      SET
        status = 'ready',
        updated_at = ?
      WHERE
        id = ?
        AND status = 'draft'
    `,
    )
    .bind(updatedAt, eventId)
    .run();
}

/*
 * A 1,500-frame shoot calls this once per photo, but only the first upload
 * for an event can possibly need to flip it out of 'draft' or send the
 * upload-started notification -- every later call in the same isolate is a
 * pointless D1 write plus a pointless waitUntil read. A per-isolate memo
 * skips both after the first: a burst from one shoot reuses the isolate and
 * pays the cost once, a cold isolate pays it again exactly like before.
 *
 * Deriving "first upload" from the UPDATE's own affected-row count was
 * rejected -- it would never fire for an event the photographer published
 * manually before uploading, since that UPDATE's WHERE clause would already
 * match nothing on the very first photo.
 */
const eventsMarkedUploadStarted = new Set<string>();

async function markEventUploadStarted(
  scope: AccountScope,
  env: TenantEnv,
  ctx: ExecutionContext,
  eventId: string,
): Promise<void> {
  if (eventsMarkedUploadStarted.has(eventId)) {
    return;
  }

  await openDraftEventForUpload(scope, eventId);
  scheduleUploadStartedNotification(scope.database, env, ctx, eventId);

  eventsMarkedUploadStarted.add(eventId);
}

async function eventExists(
  scope: AccountScope,
  eventId: string,
): Promise<boolean> {
  const event = await scope
    .prepare(
      `
      SELECT id
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<{ id: string }>();

  return event !== null;
}

async function findEventById(
  scope: AccountScope,
  eventId: string,
): Promise<EventRecord | null> {
  const event = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<EventQueryRow>();

  return event ? toEventRecord(event) : null;
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
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<SetEventStatusBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

  if (!isGalleryStatus(body.status)) {
    return jsonResponse(
      {
        error: "The status must be draft, ready, completed, or archived.",
      },
      400,
    );
  }

  const existingEvent = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<EventStatusRow>();

  if (!existingEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const updatedAt = new Date().toISOString();

  await scope.database
    .prepare(
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
      ...toEventRecord(existingEvent),
      status: body.status,
      updatedAt,
    },
  });
}

async function setEventRawRequestsEnabled(
  request: Request,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<SetEventRawRequestsEnabledBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

  if (typeof body.enabled !== "boolean") {
    return jsonResponse(
      {
        error: "The enabled flag must be a boolean.",
      },
      400,
    );
  }

  const existingEvent = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<EventQueryRow>();

  if (!existingEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  if (Boolean(existingEvent.rawRequestsEnabled) === body.enabled) {
    return jsonResponse({ event: toEventRecord(existingEvent) });
  }

  const updatedAt = new Date().toISOString();

  await scope.database
    .prepare(
      `
      UPDATE events
      SET
        raw_requests_enabled = ?,
        updated_at = ?
      WHERE id = ?
    `,
    )
    .bind(body.enabled ? 1 : 0, updatedAt, eventId)
    .run();

  return jsonResponse({
    event: {
      ...toEventRecord(existingEvent),
      rawRequestsEnabled: body.enabled,
      updatedAt,
    },
  });
}

/*
 * "That lot's collected -- take the bytes back now" (#219), for a whole event.
 *
 * Per event rather than per photo because that is the unit the workflow
 * actually has. The photographer messages a requester once the RAWs are up and
 * hears back once; what they then want to clear is the shoot, not a photo at a
 * time. The marker underneath is still per request, so narrowing this to a
 * single photo later is a different WHERE against the same column rather than a
 * second mechanism -- which is what #217's per-request iPad view will want.
 *
 * A photo is only eligible when *every* live request for it carries both
 * fulfilled_at and downloaded_at. That deliberately stops short of the other
 * half of the issue: a RAW nobody has collected can only be released by
 * cancelling the delivery somebody is still waiting on, which is a different
 * and far more dangerous action than this one and should be worded as such
 * wherever it lands. Here, "release" can never take a file out from under a
 * viewer who has not already had it.
 *
 * Photos with no requests at all are skipped rather than reported: they are
 * already reclaimed with no grace by the liveRequestCount === 0 branch, so
 * there is nothing here to release.
 */
async function releaseCollectedRawPhotos(
  env: TenantEnv,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  if (!(await eventExists(scope, eventId))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const candidates = await scope
    .prepare(
      `
      SELECT
        p.id AS photoId,
        SUM(
          CASE
            WHEN r.fulfilled_at IS NULL OR r.downloaded_at IS NULL
            THEN 1
            ELSE 0
          END
        ) AS awaitingCount,
        SUM(CASE WHEN r.released_at IS NULL THEN 1 ELSE 0 END) AS unreleasedCount
      FROM photos p
      INNER JOIN raw_requests r
        ON r.photo_id = p.id
      WHERE
        p.event_id = ?
        AND p.account_id = :accountId
        AND p.raw_storage_key IS NOT NULL
      GROUP BY p.id
    `,
      eventId,
    )
    .all<RawReleaseCandidateRow>();

  const releasablePhotoIds: string[] = [];

  let awaitingPhotoCount = 0;

  for (const row of candidates.results) {
    if (row.awaitingCount > 0) {
      awaitingPhotoCount += 1;

      continue;
    }

    if (row.unreleasedCount > 0) {
      releasablePhotoIds.push(row.photoId);
    }
  }

  if (releasablePhotoIds.length > 0) {
    const releasedAt = new Date().toISOString();

    /* Chunked to stay well inside D1's bound-parameter limit. */
    for (const chunk of chunkArray(releasablePhotoIds, PREFLIGHT_CHUNK_SIZE)) {
      await scope.database
        .prepare(
          `
          UPDATE raw_requests
          SET released_at = ?
          WHERE
            released_at IS NULL
            AND photo_id IN (${chunk.map(() => "?").join(", ")})
        `,
        )
        .bind(releasedAt, ...chunk)
        .run();
    }
  }

  /*
   * Awaited rather than deferred to ctx.waitUntil, unlike the sweep on the
   * iPad's poll. This route exists to make the bytes go away now, so the
   * response has to be able to say whether they did -- and the dashboard
   * reloads its storage figure the moment it returns.
   */
  await reclaimRawPhotos(scope.database, env, "p.event_id = ?", eventId);

  return jsonResponse({
    releasedPhotoCount: releasablePhotoIds.length,
    awaitingPhotoCount,
  });
}

/*
 * "Stop offering originals for this event" (#282) -- the per-event force-clear
 * #221 explicitly declined to add on its own ("a blanket per-event cancel
 * would revoke every outstanding delivery in a shoot in one click"). What
 * makes it safe to offer here anyway is that it designs the actual risk out
 * instead of gating on it:
 *
 *  - reclaimRawPhotos already only *re-arms* the pipeline (see its own
 *    comment above) -- nothing this deletes is a permanent loss. The
 *    original never left the iPad, and a later request re-uploads it.
 *  - the real risk is silently revoking a stranger's pending delivery, which
 *    is why the dashboard confirms with the real waiting count before this
 *    ever runs.
 *  - a bare reclaim would also just re-arm within minutes the moment a
 *    viewer re-opens the gallery and asks again, which is why this also
 *    turns raw_requests_enabled off -- that is what actually holds the
 *    reclaim rather than inviting the bytes straight back.
 *
 * One atomic action rather than three separate calls a page reload could
 * catch half-applied: delete every request nobody has downloaded yet
 * (unfulfilled or delivered-but-uncollected both read as "still waiting"
 * from the requester's side, which is why this widens #221's WHERE instead
 * of reusing it verbatim), force-release what is left -- by construction,
 * only rows every live requester has already downloaded -- and reclaim
 * through the ordinary #219 pipeline. Reusing that pipeline is what lets
 * this force a reclaim through collection status and the 24h grace period
 * without a second, bypassing delete path into R2.
 */
async function stopOfferingRawRequests(
  env: TenantEnv,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  if (!(await eventExists(scope, eventId))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const now = new Date().toISOString();

  const cancelled = await scope
    .prepare(
      `
      DELETE FROM raw_requests
      WHERE
        downloaded_at IS NULL
        AND photo_id IN (
          SELECT id FROM photos
          WHERE event_id = ? AND account_id = :accountId
        )
    `,
      eventId,
    )
    .run();

  await scope
    .prepare(
      `
      UPDATE raw_requests
      SET released_at = ?
      WHERE
        released_at IS NULL
        AND photo_id IN (
          SELECT id FROM photos
          WHERE event_id = ? AND account_id = :accountId
        )
    `,
      now,
      eventId,
    )
    .run();

  await scope.database
    .prepare(
      `
      UPDATE events
      SET
        raw_requests_enabled = 0,
        updated_at = ?
      WHERE id = ?
    `,
    )
    .bind(now, eventId)
    .run();

  /*
   * Awaited rather than deferred, matching releaseCollectedRawPhotos and
   * cancelUndeliveredRawRequests: this route exists to make the bytes go
   * away now, and the dashboard's storage figure reloads the moment it
   * returns.
   */
  await reclaimRawPhotos(scope.database, env, "p.event_id = ?", eventId);

  const updatedEvent = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<EventQueryRow>();

  if (!updatedEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  return jsonResponse({
    event: toEventRecord(updatedEvent),
    cancelledRequestCount: cancelled.meta.changes ?? 0,
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

async function createEvent(
  request: Request,
  scope: AccountScope,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<CreateEventBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

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

  /*
   * A client may supply the id so that creating an event is idempotent.
   * The iPad needs to name an event before it can reach the network, and
   * retrying a create it never saw the result of must converge on the
   * same event rather than leaving a duplicate behind.
   */
  let requestedId: string | null = null;

  if (body.id !== undefined) {
    if (typeof body.id !== "string" || !UUID_PATTERN.test(body.id)) {
      return jsonResponse({ error: "An event id must be a UUID." }, 400);
    }

    requestedId = body.id.toLowerCase();

    const existing = await findEventById(scope, requestedId);

    if (existing) {
      return jsonResponse({ event: existing }, 200);
    }
  }

  const now = new Date().toISOString();

  const event: EventRecord = {
    id: requestedId ?? crypto.randomUUID(),
    title,
    shareToken: generateShareToken(),
    status: "draft",
    createdAt: now,
    updatedAt: now,
    rawRequestsEnabled: false,
    hasRawRequests: false,
  };

  try {
    await scope
      .prepare(
        `
        INSERT INTO events (
          id,
          title,
          share_token,
          status,
          created_at,
          updated_at,
          account_id
        )
        VALUES (?, ?, ?, ?, ?, ?, :accountId)
      `,
        event.id,
        event.title,
        event.shareToken,
        event.status,
        event.createdAt,
        event.updatedAt,
      )
      .run();
  } catch (error) {
    /*
     * Two creates for the same id can pass the check above concurrently,
     * leaving the loser here. Returning the winner keeps the call
     * idempotent instead of surfacing a primary-key error.
     */
    if (requestedId) {
      const existing = await findEventById(scope, requestedId);

      if (existing) {
        return jsonResponse({ event: existing }, 200);
      }
    }

    throw error;
  }

  return jsonResponse({ event }, 201);
}

async function updateAccount(
  request: Request,
  scope: AccountScope,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<UpdateAccountBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

  const hasName = body.name !== undefined;
  const hasTtl = body.rawDeliveryTtlMs !== undefined;

  if (!hasName && !hasTtl) {
    return jsonResponse(
      {
        error: "Nothing to update.",
      },
      400,
    );
  }

  let name = scope.account.name;

  if (hasName) {
    if (typeof body.name !== "string") {
      return jsonResponse(
        {
          error: "An account name is required.",
        },
        400,
      );
    }

    name = body.name.trim();

    if (name.length === 0 || name.length > 120) {
      return jsonResponse(
        {
          error: "The account name must be between 1 and 120 characters.",
        },
        400,
      );
    }
  }

  let rawDeliveryTtlMs = scope.account.rawDeliveryTtlMs;

  if (hasTtl) {
    const dayMs = 24 * 60 * 60 * 1000;

    if (
      typeof body.rawDeliveryTtlMs !== "number" ||
      !Number.isInteger(body.rawDeliveryTtlMs) ||
      body.rawDeliveryTtlMs < RAW_DELIVERY_TTL_MIN_MS ||
      body.rawDeliveryTtlMs > RAW_DELIVERY_TTL_MAX_MS
    ) {
      return jsonResponse(
        {
          error: `The RAW retention period must be between ${RAW_DELIVERY_TTL_MIN_MS / dayMs} and ${RAW_DELIVERY_TTL_MAX_MS / dayMs} days.`,
        },
        400,
      );
    }

    rawDeliveryTtlMs = body.rawDeliveryTtlMs;
  }

  if (
    name === scope.account.name &&
    rawDeliveryTtlMs === scope.account.rawDeliveryTtlMs
  ) {
    return jsonResponse({
      account: { id: scope.account.id, name, rawDeliveryTtlMs },
    });
  }

  const updatedAt = new Date().toISOString();

  await scope
    .prepare(
      `
      UPDATE accounts
      SET
        name = ?,
        raw_delivery_ttl_ms = ?,
        updated_at = ?
      WHERE id = :accountId
    `,
      name,
      rawDeliveryTtlMs,
      updatedAt,
    )
    .run();

  return jsonResponse({
    account: { id: scope.account.id, name, rawDeliveryTtlMs },
  });
}

async function updateEvent(
  request: Request,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<UpdateEventBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

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

  const existingEvent = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<EventQueryRow>();

  if (!existingEvent) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  if (title === existingEvent.title) {
    return jsonResponse({
      event: toEventRecord(existingEvent),
    });
  }

  const updatedAt = new Date().toISOString();

  await scope.database
    .prepare(
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
      ...toEventRecord(existingEvent),
      title,
      updatedAt,
    },
  });
}

/*
 * Only sums what accounts.storage_bytes already counted for this event, so
 * the caller can decrement that running counter accurately. Deliberately
 * does not enumerate storage keys -- actual R2 deletion is a prefix sweep
 * (deleteStorageObjectsByPrefix below) precisely because the database's view
 * of an event's objects can be incomplete.
 */
async function getEventStorageTotals(
  scope: AccountScope,
  eventId: string,
): Promise<{ photoCount: number; totalBytes: number }> {
  const photoResult = await scope.database
    .prepare(
      `
      SELECT
        byte_size AS byteSize,
        final_byte_size AS finalByteSize,
        raw_byte_size AS rawByteSize
      FROM photos
      WHERE event_id = ?
    `,
    )
    .bind(eventId)
    .all<Pick<StoredPhotoRow, "byteSize" | "finalByteSize" | "rawByteSize">>();

  const variantResult = await scope.database
    .prepare(
      `
        SELECT
          v.byte_size AS byteSize
        FROM photo_variants v
        INNER JOIN photos p
          ON p.id = v.photo_id
        WHERE p.event_id = ?
      `,
    )
    .bind(eventId)
    .all<Pick<StoredVariantRow, "byteSize">>();

  const totalBytes =
    photoResult.results.reduce(
      (sum, photo) =>
        sum +
        photo.byteSize +
        (photo.finalByteSize ?? 0) +
        (photo.rawByteSize ?? 0),
      0,
    ) +
    variantResult.results.reduce((sum, variant) => sum + variant.byteSize, 0);

  return {
    photoCount: photoResult.results.length,
    totalBytes,
  };
}

/*
 * Deletes every R2 object under a prefix rather than just the keys the
 * database currently references. A keys-from-the-database delete can never
 * reach an orphan -- an upload cancelled between the R2 put and the D1
 * insert, or a superseded variant key from two in-flight uploads racing the
 * same photo -- and those bytes become permanently invisible once nothing
 * left in the database points back to them.
 *
 * Safe as a prefix sweep specifically because every object this bucket ever
 * writes is placed under `events/<eventId>/...` and nothing else is ever
 * stored there (see the storageKey construction throughout this file), and
 * because both callers below build the prefix from an eventId they have
 * already confirmed names a real event belonging to this account via their
 * own SELECT before reaching this call.
 */
async function deleteStorageObjectsByPrefix(
  env: TenantEnv,
  prefix: string,
): Promise<void> {
  let cursor: string | undefined;

  do {
    const listing = await env.pickpic_photos.list({ prefix, cursor });
    const keys = listing.objects.map((object) => object.key);

    for (const keyChunk of chunkArray(keys, 1000)) {
      await env.pickpic_photos.delete(keyChunk);
    }

    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}

async function deleteEvent(
  env: TenantEnv,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  const event = await scope
    .prepare(
      `
      SELECT id
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<{ id: string }>();

  if (!event) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const { totalBytes } = await getEventStorageTotals(scope, eventId);

  try {
    await scope.database
      .prepare(
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
        error: "The event record could not be deleted. No images were removed.",
      },
      500,
    );
  }

  await adjustAccountStorageBytes(scope, -totalBytes);

  try {
    await deleteStorageObjectsByPrefix(env, `events/${eventId}/`);
  } catch (error) {
    // The event record is already gone, so this only leaves orphaned R2
    // objects behind rather than a gallery with broken image rows -- the
    // cheaper failure mode. Reconciling orphans is #230/#249's job, not this
    // request's.
    console.error("Unable to delete event images:", error);
  }

  return jsonResponse({
    deleted: true,
    eventId,
  });
}

/*
 * Empties an event without removing it, so a shoot uploaded against the
 * wrong event can be re-uploaded into the right one.
 *
 * The photo rows go first: a photo row whose image is gone renders as a
 * broken gallery, whereas an orphaned R2 object just costs invisible
 * storage -- the cheaper failure to risk here, and #230/#249's job to
 * reconcile. The hearts, comments, and variant rows follow the photos
 * through their ON DELETE CASCADE foreign keys, so one delete covers them.
 */
async function clearEventPhotos(
  env: TenantEnv,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  const event = await scope
    .prepare(
      `
      SELECT id
      FROM events
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      eventId,
    )
    .first<{ id: string }>();

  if (!event) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  const { photoCount, totalBytes } = await getEventStorageTotals(
    scope,
    eventId,
  );

  if (photoCount === 0) {
    return jsonResponse({
      eventId,
      deletedPhotoCount: 0,
    });
  }

  try {
    await scope.database
      .prepare(
        `
        DELETE FROM photos
        WHERE event_id = ?
      `,
      )
      .bind(eventId)
      .run();
  } catch (error) {
    console.error("Unable to delete event photo records:", error);

    return jsonResponse(
      {
        error:
          "The photo records could not be deleted. No images were removed.",
      },
      500,
    );
  }

  await adjustAccountStorageBytes(scope, -totalBytes);

  try {
    await deleteStorageObjectsByPrefix(env, `events/${eventId}/photos/`);
  } catch (error) {
    // The photo records are already gone, so this only leaves orphaned R2
    // objects behind rather than a gallery with broken image rows -- the
    // cheaper failure mode. Reconciling orphans is #230/#249's job, not this
    // request's.
    console.error("Unable to delete event photo images:", error);
  }

  return jsonResponse({
    eventId,
    deletedPhotoCount: photoCount,
  });
}

async function listEvents(scope: AccountScope): Promise<Response> {
  const result = await scope
    .prepare(
      `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt,
        raw_requests_enabled AS rawRequestsEnabled,
        EXISTS (
          SELECT 1
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE p.event_id = events.id
        ) AS hasRawRequests
      FROM events
      WHERE account_id = :accountId
      ORDER BY created_at DESC
    `,
    )
    .all<EventQueryRow>();

  return jsonResponse({
    events: result.results.map(toEventRecord),
  });
}

/*
 * Whether adding additionalBytes (which may be negative, e.g. a replace
 * that shrinks a file) would push the account over its cap. Reads whatever is
 * currently on account.storageBytes -- the request-scoped snapshot at the
 * cheap pre-checks, or a value refreshAccountStorageBytes just re-read at the
 * checks that actually decide -- so even there this is a race-narrowing
 * check, not a race-free reservation: two decisive checks can still land
 * between each other's refresh and its own account_users write. Concurrent
 * uploads on one account are rare enough here that getStorageUsage's
 * reconciliation on the next dashboard load is an acceptable backstop for
 * that remaining gap rather than something to lock against.
 */
function wouldExceedStorageCap(
  account: AccountRecord,
  additionalBytes: number,
): boolean {
  return account.storageBytes + additionalBytes > account.storageCapBytes;
}

/*
 * `Number(null)` is 0, so reading a missing Content-Length header straight
 * through Number() reports a declared size of zero bytes rather than "no
 * declared size" -- silently passing every pre-upload size/cap check below
 * regardless of the account's actual headroom. NaN (the same as a garbage
 * header) makes those checks skip cleanly instead of trusting a false zero.
 */
function parseDeclaredContentLength(request: Request): number {
  const header = request.headers.get("Content-Length");

  return header === null ? NaN : Number(header);
}

/*
 * The running counter enforcement reads (AccountRecord.storageBytes) is
 * maintained here rather than by a trigger so every adjustment site is a
 * grep-able call. Clamped to zero so a missed decrement elsewhere can't
 * compound into a negative counter that then under-reports usage forever.
 */
async function adjustAccountStorageBytes(
  scope: AccountScope,
  deltaBytes: number,
): Promise<void> {
  if (deltaBytes === 0) {
    return;
  }

  await scope
    .prepare(
      `
      UPDATE accounts
      SET storage_bytes = MAX(0, storage_bytes + ?)
      WHERE id = :accountId
    `,
      deltaBytes,
    )
    .run();
}

/*
 * Re-reads storage_bytes immediately before the check in each upload path
 * that actually rejects (the one comparing against an exact, already-known
 * size rather than a declared Content-Length). Progressive, parallel uploads
 * from the iPad mean several requests can pass wouldExceedStorageCap against
 * the same request-start snapshot before any of them adjusts the counter, so
 * refreshing right before the deciding check narrows -- without eliminating
 * -- that window. Mutates scope.account in place rather than threading a
 * fresh AccountRecord through, since every remaining use in the request
 * (adjustAccountStorageBytes, the response body) should see the same value.
 */
async function refreshAccountStorageBytes(scope: AccountScope): Promise<void> {
  const row = await scope
    .prepare(
      `
      SELECT storage_bytes AS storageBytes
      FROM accounts
      WHERE id = :accountId
    `,
    )
    .first<{ storageBytes: number }>();

  if (row) {
    scope.account.storageBytes = row.storageBytes;
  }
}

/*
 * Storage usage is summed from what the database records about every
 * stored object rather than measured against the bucket, which keeps
 * this to two queries with no R2 listing and no extra credentials.
 * The tradeoff is that it reports the database's belief: if a delete
 * ever half-failed, the bucket holds more than this reports.
 *
 * This is also the reconciliation point for accounts.storage_bytes (the
 * counter createPhoto/uploadFinalPhoto/uploadPhotoVariants/deletes
 * maintain incrementally): every dashboard load writes the true sum back,
 * so any drift from a missed adjustment self-heals rather than compounding.
 *
 * Which is exactly why a new kind of stored object has to be added here as
 * well as to its own upload path. Delivered RAWs (uploadRawPhoto) counted
 * only by adjustAccountStorageBytes would survive until the next dashboard
 * load and then be erased from the counter by this reconciliation, quietly
 * putting the account back under its cap while the bytes were still in R2.
 *
 * rawBytes is reported alongside the other three, but src/components/
 * StorageUsage.tsx does not render a row for it yet -- so its Proofs/Finals/
 * Thumbnails breakdown will sum to less than the total once a RAW is
 * delivered. That row is a small src/ follow-up; the cap is correct either
 * way, which is the part that cannot wait.
 */
async function getStorageUsage(scope: AccountScope): Promise<Response> {
  const eventResult = await scope
    .prepare(
      `
      SELECT
        e.id AS eventId,
        e.title AS title,
        e.status AS status,
        COUNT(p.id) AS photoCount,
        COUNT(p.final_storage_key) AS finalCount,
        COUNT(p.raw_storage_key) AS rawCount,
        COALESCE(SUM(p.byte_size), 0) AS proofBytes,
        COALESCE(SUM(p.final_byte_size), 0) AS finalBytes,
        COALESCE(SUM(p.raw_byte_size), 0) AS rawBytes
      FROM events e
      LEFT JOIN photos p
        ON p.event_id = e.id
      WHERE e.account_id = :accountId
      GROUP BY e.id
    `,
    )
    .all<EventStorageRow>();

  const variantResult = await scope
    .prepare(
      `
      SELECT
        p.event_id AS eventId,
        COUNT(v.storage_key) AS variantCount,
        COALESCE(SUM(v.byte_size), 0) AS variantBytes
      FROM photo_variants v
      INNER JOIN photos p
        ON p.id = v.photo_id
      WHERE p.account_id = :accountId
      GROUP BY p.event_id
    `,
    )
    .all<EventVariantStorageRow>();

  const variantsByEvent = new Map(
    variantResult.results.map((variantRow) => [variantRow.eventId, variantRow]),
  );

  const events: EventStorageRecord[] = eventResult.results
    .map((eventRow) => {
      const variants = variantsByEvent.get(eventRow.eventId);
      const variantBytes = variants?.variantBytes ?? 0;

      return {
        eventId: eventRow.eventId,
        title: eventRow.title,
        status: eventRow.status,
        photoCount: eventRow.photoCount,
        finalCount: eventRow.finalCount,
        variantCount: variants?.variantCount ?? 0,
        rawCount: eventRow.rawCount,
        proofBytes: eventRow.proofBytes,
        finalBytes: eventRow.finalBytes,
        variantBytes,
        rawBytes: eventRow.rawBytes,
        totalBytes:
          eventRow.proofBytes +
          eventRow.finalBytes +
          variantBytes +
          eventRow.rawBytes,
      };
    })
    .sort((first, second) => second.totalBytes - first.totalBytes);

  /*
   * The totals are folded from the same per-event records the
   * breakdown is drawn from, so the two can never disagree.
   */
  const totals = events.reduce(
    (running, eventStorage) => ({
      photoCount: running.photoCount + eventStorage.photoCount,
      finalCount: running.finalCount + eventStorage.finalCount,
      variantCount: running.variantCount + eventStorage.variantCount,
      rawCount: running.rawCount + eventStorage.rawCount,
      proofBytes: running.proofBytes + eventStorage.proofBytes,
      finalBytes: running.finalBytes + eventStorage.finalBytes,
      variantBytes: running.variantBytes + eventStorage.variantBytes,
      rawBytes: running.rawBytes + eventStorage.rawBytes,
      totalBytes: running.totalBytes + eventStorage.totalBytes,
    }),
    {
      photoCount: 0,
      finalCount: 0,
      variantCount: 0,
      rawCount: 0,
      proofBytes: 0,
      finalBytes: 0,
      variantBytes: 0,
      rawBytes: 0,
      totalBytes: 0,
    },
  );

  if (totals.totalBytes !== scope.account.storageBytes) {
    await scope
      .prepare(
        `
        UPDATE accounts
        SET storage_bytes = ?
        WHERE id = :accountId
      `,
        totals.totalBytes,
      )
      .run();
  }

  return jsonResponse({
    storage: {
      ...totals,
      plan: scope.account.plan,
      capBytes: scope.account.storageCapBytes,
      events,
    },
  });
}

async function createPhoto(
  request: Request,
  env: TenantEnv,
  scope: AccountScope,
  eventId: string,
  ctx: ExecutionContext,
): Promise<Response> {
  if (!(await eventExists(scope, eventId))) {
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

  const declaredSize = parseDeclaredContentLength(request);

  if (Number.isFinite(declaredSize) && declaredSize > MAX_JPEG_BYTES) {
    return jsonResponse({ error: "The JPEG must be 25 MB or smaller." }, 413);
  }

  if (
    Number.isFinite(declaredSize) &&
    wouldExceedStorageCap(scope.account, declaredSize)
  ) {
    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

  const duplicatePhoto = await findDuplicatePhoto(scope, eventId, sourceSha256);

  if (duplicatePhoto) {
    await markEventUploadStarted(scope, env, ctx, eventId);

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

  await refreshAccountStorageBytes(scope);

  if (wouldExceedStorageCap(scope.account, storedObject.size)) {
    await env.pickpic_photos.delete(storageKey);

    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

  const createdAt = new Date().toISOString();

  try {
    await scope
      .prepare(
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
          created_at,
          account_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, :accountId)
      `,
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
      scope,
      eventId,
      sourceSha256,
    );

    if (duplicateAfterInsert) {
      await markEventUploadStarted(scope, env, ctx, eventId);

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

  await adjustAccountStorageBytes(scope, storedObject.size);
  await markEventUploadStarted(scope, env, ctx, eventId);

  const photo: PhotoRecord = {
    id: photoId,
    eventId,
    originalFilename,
    contentType: "image/jpeg",
    byteSize: storedObject.size,
    createdAt,
    imageUrl: `${ADMIN_PHOTO_IMAGE_BASE}/${encodeURIComponent(photoId)}/image`,
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

async function listPhotos(
  env: TenantEnv,
  ctx: ExecutionContext,
  scope: AccountScope,
  eventId: string,
): Promise<Response> {
  if (!(await eventExists(scope, eventId))) {
    return jsonResponse({ error: "Event not found." }, 404);
  }

  /*
   * The only heartbeat this project has. There is no cron (CLAUDE.md keeps
   * scheduled work out of the deployment), so the TTL half of the RAW reclaim
   * policy needs some request to advance it -- and the iPad polls this route
   * for every event on each activation sweep, which is the one thing that
   * keeps happening whether or not anybody opens the gallery. A shoot whose
   * requester never came back is collected here.
   *
   * Off the response path: the poll already runs a correlated subquery per
   * photo and should not also wait on R2 deletes.
   */
  ctx.waitUntil(
    reclaimRawPhotos(scope.database, env, "p.event_id = ?", eventId),
  );

  const result = await scope.database
    .prepare(
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
        p.raw_original_filename AS rawOriginalFilename,
        p.raw_content_type AS rawContentType,
        p.raw_byte_size AS rawByteSize,
        p.raw_uploaded_at AS rawUploadedAt,
        COUNT(h.photo_id) AS heartCount,

        /*
         * A correlated subquery rather than a second LEFT JOIN. Joining
         * raw_requests beside hearts would produce one row per (heart,
         * request) pair, and heartCount above -- a plain COUNT over the
         * joined rows -- would silently multiply for any photo carrying
         * both. This leaves that aggregate untouched.
         */
        (
          SELECT COUNT(*)
          FROM raw_requests r
          WHERE
            r.photo_id = p.id
            AND r.fulfilled_at IS NULL
        ) AS pendingRawRequestCount,

        /*
         * A delivery the photographer would strand by disabling RAW requests
         * (#237), and also #221's cancel target: fulfilled, not yet
         * collected, and not already released -- the same "outstanding"
         * reading isRawReclaimable uses for the per-event release button, but
         * per photo here so the toggle's confirmation can name what is
         * actually at risk.
         */
        (
          SELECT COUNT(*)
          FROM raw_requests r
          WHERE
            r.photo_id = p.id
            AND r.fulfilled_at IS NOT NULL
            AND r.downloaded_at IS NULL
            AND r.released_at IS NULL
        ) AS awaitingRawDownloadCount
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
        p.longitude,
        p.raw_original_filename,
        p.raw_content_type,
        p.raw_byte_size,
        p.raw_uploaded_at
      ORDER BY
        COALESCE(p.captured_at, p.created_at) DESC,
        p.created_at DESC
  `,
    )
    .bind(eventId)
    .all<AdminPhotoRow>();

  const commentsByPhoto = await getCommentsByPhoto(scope.database, eventId);
  const variantsByPhoto = await getPhotoVariantsByEvent(
    scope.database,
    eventId,
    ADMIN_PHOTO_IMAGE_BASE,
  );
  return jsonResponse({
    photos: result.results.map((row) =>
      toAdminPhotoRecord(
        row,
        ADMIN_PHOTO_IMAGE_BASE,
        (commentsByPhoto.get(row.id) ?? []).map(toPhotoCommentRecord),
        variantsByPhoto.get(row.id) ?? createEmptyPhotoVariants(),
      ),
    ),
  });
}

async function getAdminPhotoImage(
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT storage_key AS storageKey
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<{ storageKey: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  return getStoredJpeg(env, photo.storageKey);
}

async function getGalleryPhotoImage(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const photo = await findPhotoInShare(env, shareToken, photoId);

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  /* Cached only below the status gate above -- see getCachedStoredJpeg. */
  return getCachedStoredJpeg(request, env, ctx, photo.storageKey);
}

async function deletePhoto(
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT
        storage_key AS storageKey,
        final_storage_key AS finalStorageKey,
        raw_storage_key AS rawStorageKey,
        byte_size AS byteSize,
        final_byte_size AS finalByteSize,
        raw_byte_size AS rawByteSize
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<StoredPhotoRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const variantResult = await scope.database
    .prepare(
      `
        SELECT
          storage_key AS storageKey,
          byte_size AS byteSize
        FROM photo_variants
        WHERE photo_id = ?
      `,
    )
    .bind(photoId)
    .all<StoredVariantRow>();

  const totalBytes =
    photo.byteSize +
    (photo.finalByteSize ?? 0) +
    (photo.rawByteSize ?? 0) +
    variantResult.results.reduce((sum, variant) => sum + variant.byteSize, 0);

  const storageKeys = [
    photo.storageKey,
    photo.finalStorageKey,
    photo.rawStorageKey,
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
    await scope.database
      .prepare(
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

  await adjustAccountStorageBytes(scope, -totalBytes);

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
        e.id,
        e.title,
        e.status,
        e.created_at AS createdAt,
        e.raw_requests_enabled AS rawRequestsEnabled,
        a.raw_delivery_ttl_ms AS rawDeliveryTtlMs
      FROM events e
      INNER JOIN accounts a
        ON a.id = e.account_id
      WHERE e.share_token = ?
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

  const imageBasePath = galleryPhotoImageBase(shareToken);
  const commentsByPhoto = await getCommentsByPhoto(env.DB, event.id);
  const variantsByPhoto = await getPhotoVariantsByEvent(
    env.DB,
    event.id,
    imageBasePath,
  );
  const visitorToken = getVisitorToken(request);
  const heartedPhotoIds = new Set<string>();
  const rawRequestedPhotoIds = new Set<string>();
  const rawRequestsByPhotoId = new Map<string, RawRequestedPhotoRow>();
  const pendingConfirmationsByPhotoId = new Map<
    string,
    PendingConfirmationPhotoRow
  >();
  const rawRequestsEnabled = Boolean(event.rawRequestsEnabled);

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

    /*
     * Not gated on rawRequestsEnabled. This is scoped to the visitor's own
     * existing rows, so it can only ever surface a request that visitor
     * already made while the event had requests enabled -- toggling the
     * event off afterwards stops new asks (addRawRequest's own gate) but
     * must not blind a visitor to a delivery already in flight or waiting to
     * be collected (#237).
     *
     * Joined to photos rather than read off the main photo query, so every
     * RAW field stays behind this visitor-scoped WHERE. The main query feeds
     * toPhotoRecord, which builds the admin dashboard's records too -- a RAW
     * column added there would reach every visitor for every photo, which is
     * the trap migration 0020's own comment left standing for #209.
     */
    const rawRequestResult = await env.DB.prepare(
      `
        SELECT
          r.photo_id AS photoId,
          r.email AS email,
          r.fulfilled_at AS fulfilledAt,
          r.downloaded_at AS downloadedAt,
          p.raw_storage_key AS rawStorageKey,
          p.raw_original_filename AS rawOriginalFilename,
          p.raw_byte_size AS rawByteSize
        FROM raw_requests r
        INNER JOIN gallery_visitors v
          ON v.id = r.visitor_id
        INNER JOIN photos p
          ON p.id = r.photo_id
        WHERE
          v.event_id = ?
          AND v.visitor_token = ?
      `,
    )
      .bind(event.id, visitorToken)
      .all<RawRequestedPhotoRow>();

    for (const row of rawRequestResult.results) {
      rawRequestedPhotoIds.add(row.photoId);
      rawRequestsByPhotoId.set(row.photoId, row);
    }

    /*
     * Requests this browser has asked for but not yet confirmed (#224). Read
     * from the server rather than held in the page, because the viewer leaves
     * for their mail app between the two steps and comes back to a fresh load
     * -- without this the button would have forgotten what it was waiting for.
     *
     * Expired rows are filtered here rather than deleted: this is a GET on the
     * hot gallery path, and a stale row costs nothing beyond being ignored
     * until the next request for that photo replaces it.
     */
    const pendingResult = await env.DB.prepare(
      `
        SELECT
          photo_id AS photoId,
          email AS email
        FROM raw_request_confirmations
        WHERE
          event_id = ?
          AND visitor_token = ?
          AND expires_at > ?
      `,
    )
      .bind(event.id, visitorToken, new Date().toISOString())
      .all<PendingConfirmationPhotoRow>();

    for (const row of pendingResult.results) {
      pendingConfirmationsByPhotoId.set(row.photoId, row);
    }
  }

  const response: PublicGalleryResponse = {
    event: {
      title: event.title,
      status: event.status,
      createdAt: event.createdAt,
      rawRequestsEnabled,
    },
    photos: photoResult.results.map((row) => {
      const commentRows = commentsByPhoto.get(row.id) ?? [];
      const rawRequest = rawRequestsByPhotoId.get(row.id);
      const photo = toPhotoRecord(
        row,
        imageBasePath,
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
        viewerRequestedRaw: rawRequestedPhotoIds.has(photo.id),
        viewerRawDownload: toViewerRawDownload(
          {
            originalFilename: photo.originalFilename,
            rawStorageKey: rawRequest?.rawStorageKey ?? null,
            rawOriginalFilename: rawRequest?.rawOriginalFilename ?? null,
            rawByteSize: rawRequest?.rawByteSize ?? null,
          },
          rawRequest?.fulfilledAt ?? null,
          event.rawDeliveryTtlMs,
        ),
        viewerRawDownloadedAt: rawRequest?.downloadedAt ?? null,

        /*
         * Falls back to the pending row's address so the viewer can see and
         * correct a typo during the one window where it matters most -- before
         * they have clicked anything and while "nothing arrived" is the only
         * symptom they have.
         */
        viewerRawRequestEmail:
          rawRequest?.email ??
          pendingConfirmationsByPhotoId.get(photo.id)?.email ??
          null,
        viewerRawConfirmationPending: pendingConfirmationsByPhotoId.has(
          photo.id,
        ),
      };
    }),
  };

  return jsonResponse(response);
}

/*
 * The single choke point for "does this photo belong to this share token's
 * event". Every public photo lookup -- hearts, comments, and the three image
 * routes below -- goes through here, which is also where a future per-client
 * share (a subset of an event's photos) gets its narrowing check added.
 *
 * The status filter mirrors getPublicGallery: a share token only exposes
 * anything while the event is `ready` or `completed`. Without it, archiving an
 * event removes the gallery page but leaves every image URL live forever, so
 * anyone who scraped the page (or kept a link) retains full-resolution access
 * to a shoot the photographer considers withdrawn -- and getStoredJpeg sends a
 * one-year immutable Cache-Control, so those responses persist downstream too.
 * Filtering here covers the hearts, comments and all three image routes at
 * once, and every one of those image routes consults the colo cache strictly
 * after this has returned a row (getCachedStoredJpeg), so a cached image can
 * never outlive the gate that admitted it. It is safe during upload: the event
 * is still `draft` then, and only the `/api/admin/*` image routes -- which do
 * not come through here -- are used by the dashboard and the iPad app.
 */
async function findPhotoInShare(
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<GalleryPhotoRow | null> {
  return env.DB.prepare(
    `
      SELECT
        p.id AS photoId,
        p.event_id AS eventId,
        p.storage_key AS storageKey,
        p.final_storage_key AS finalStorageKey,
        p.original_filename AS originalFilename,
        p.raw_storage_key AS rawStorageKey,
        p.raw_original_filename AS rawOriginalFilename,
        p.raw_content_type AS rawContentType,
        p.raw_byte_size AS rawByteSize,
        e.title AS eventTitle,
        e.share_token AS shareToken,
        e.raw_requests_enabled AS rawRequestsEnabled,
        a.raw_delivery_ttl_ms AS rawDeliveryTtlMs
      FROM photos p
      INNER JOIN events e
        ON e.id = p.event_id
      INNER JOIN accounts a
        ON a.id = p.account_id
      WHERE
        p.id = ?
        AND e.share_token = ?
        AND e.status IN ('ready', 'completed')
    `,
  )
    .bind(photoId, shareToken)
    .first<GalleryPhotoRow>();
}

async function getHeartCount(
  database: D1Database,
  photoId: string,
): Promise<number> {
  const result = await database
    .prepare(
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

  const parsedBody = await parseJsonObjectBody<HeartRequestBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

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

  const galleryPhoto = await findPhotoInShare(env, shareToken, photoId);

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
    heartCount: await getHeartCount(env.DB, photoId),
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

  const galleryPhoto = await findPhotoInShare(env, shareToken, photoId);

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
    heartCount: await getHeartCount(env.DB, photoId),
  });
}

async function addRawRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  const parsedBody = await parseJsonObjectBody<RawRequestRequestBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

  if (typeof body.displayName !== "string") {
    return jsonResponse(
      { error: "Enter your name before requesting the RAW file." },
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

  /*
   * Required, not optional-with-a-fallback (#224). An optional address would
   * leave the browser token as the identity for anyone who skipped it, which is
   * exactly the half of #222 this is meant to close.
   */
  const email = normalizeEmail(body.email);

  if (!email) {
    return jsonResponse(
      { error: "Enter a valid email address to request the original file." },
      400,
    );
  }

  const galleryPhoto = await findPhotoInShare(env, shareToken, photoId);

  if (!galleryPhoto) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  if (!galleryPhoto.rawRequestsEnabled) {
    return jsonResponse(
      { error: "RAW requests are not enabled for this gallery." },
      404,
    );
  }

  /*
   * An address that already has a request somewhere in this event has already
   * been through the confirmation step, because nothing else ever writes a
   * raw_requests row -- so that row *is* the record of confirmation, and there
   * is no separate table of confirmed addresses to keep in step with it.
   */
  if (!(await isAddressConfirmedInEvent(env, galleryPhoto.eventId, email))) {
    return startRawRequestConfirmation(
      request,
      env,
      ctx,
      galleryPhoto,
      photoId,
      visitorToken,
      displayName,
      email,
    );
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

  return writeRawRequest(
    request,
    env,
    ctx,
    galleryPhoto,
    photoId,
    visitor.id,
    email,
  );
}

/*
 * Writes (or re-points) the one raw_requests row that belongs to this address,
 * having established that the address is confirmed for this event.
 *
 * This replaces what used to be a single ON CONFLICT(photo_id, visitor_id)
 * upsert, and it has to: there are now two uniqueness constraints over this
 * table -- the surviving primary key, and 0023's unique index on
 * (photo_id, email) -- and SQLite's ON CONFLICT can only name one of them. The
 * other does not take the update arm, it raises. So the row is resolved by an
 * explicit read first, and each of the four cases is written out.
 */
async function writeRawRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  galleryPhoto: GalleryPhotoRow,
  photoId: string,
  visitorId: string,
  email: string,
): Promise<Response> {
  const now = new Date().toISOString();

  /*
   * A request for a photo whose RAW is already sitting in R2 is fulfilled the
   * moment it is made -- the same object serves every requester (migration
   * 0020), so there is nothing for the iPad to send.
   *
   * Getting this wrong is not merely wasteful. Before #209 the insert always
   * left fulfilled_at NULL, which meant a second visitor's request was never
   * stamped, listPhotos reported a pending count that could never reach zero,
   * and -- once there is a download route to reach -- that visitor would have
   * waited forever for a file that was already there.
   */
  const fulfilledAt = galleryPhoto.rawStorageKey === null ? null : now;

  const existing = await env.DB.prepare(
    `
      SELECT
        visitor_id AS visitorId,
        email AS email,
        fulfilled_at AS fulfilledAt,
        downloaded_at AS downloadedAt
      FROM raw_requests
      WHERE
        photo_id = ?1
        AND (email = ?2 OR visitor_id = ?3)
    `,
  )
    .bind(photoId, email, visitorId)
    .all<RawRequestResolutionRow>();

  const emailRow = existing.results.find((row) => row.email === email) ?? null;
  const visitorRow =
    existing.results.find((row) => row.visitorId === visitorId) ?? null;

  const targetVisitorId = emailRow?.visitorId ?? visitorId;
  const previous = emailRow ?? visitorRow;

  /*
   * getGalleryRawPhoto's header-based route only ever recognises the row's
   * actual visitor_id (by design -- see its own comment on device
   * independence coming from the emailed link, not the header route). When a
   * genuinely different browser asks under the same proven address for a
   * photo someone else here already owns, targetVisitorId stays with that
   * original owner, and this caller ends up with no row it can use its own
   * visitor token to fetch from.
   */
  const requestingVisitorOwnsRow = targetVisitorId === visitorId;

  /*
   * Attaching keeps the existing row's visitor rather than moving it to whoever
   * asked most recently. The first device stays the one the in-page UI
   * recognises, and the second is served by the emailed link -- moving it would
   * silently take the in-page download away from the browser that asked.
   *
   * The one row that has to go is a *different* row belonging to this browser:
   * that is the duplicate #222 is about. It is spared when it carries a
   * downloaded_at, because that stamp is the only record of who actually
   * collected the bytes (#220) and a collected row cannot hold storage open
   * anyway, so keeping it as history costs nothing.
   */
  if (emailRow && visitorRow && visitorRow.visitorId !== emailRow.visitorId) {
    if (visitorRow.downloadedAt === null) {
      await env.DB.prepare(
        `
          DELETE FROM raw_requests
          WHERE
            photo_id = ?
            AND visitor_id = ?
        `,
      )
        .bind(photoId, visitorRow.visitorId)
        .run();
    }
  }

  let notifyPhotographer = false;
  let addressCorrected = false;

  if (!previous) {
    await env.DB.prepare(
      `
        INSERT INTO raw_requests (
          photo_id,
          visitor_id,
          email,
          created_at,
          fulfilled_at
        )
        VALUES (?, ?, ?, ?, ?)
      `,
    )
      .bind(photoId, targetVisitorId, email, now, fulfilledAt)
      .run();

    notifyPhotographer = fulfilledAt === null;
  } else if (previous.fulfilledAt !== null && fulfilledAt === null) {
    /*
     * "Ask again": this address already had a fulfilled request and the RAW
     * behind it has since been reclaimed. Resetting the notification lease
     * alongside it is deliberate -- notifyRawRequested returns early on a 'sent'
     * row, so without the reset the photographer would never hear that the file
     * is wanted a second time. Clearing released_at matters for the same reason
     * (#219): the photographer's "they've got it" was about the copy that has
     * since been reclaimed, and left standing it would let the replacement RAW
     * be swept the instant this visitor collects it, with no grace period
     * behind them. Clearing the download token retires the link in the last
     * delivery email, which would otherwise be a credential for bytes that no
     * longer exist and, after the re-delivery, for bytes that do.
     */
    await env.DB.prepare(
      `
        UPDATE raw_requests
        SET
          email = ?3,
          created_at = ?4,
          fulfilled_at = NULL,
          downloaded_at = NULL,
          released_at = NULL,
          download_token_hash = NULL,
          delivery_email_sent_at = NULL,
          notification_status = 'pending',
          notification_attempt_count = 0,
          notification_last_attempt_at = NULL,
          notification_sent_at = NULL,
          notification_last_error = NULL
        WHERE
          photo_id = ?1
          AND visitor_id = ?2
      `,
    )
      .bind(photoId, previous.visitorId, email, now)
      .run();

    notifyPhotographer = true;
  } else if (previous.email !== email) {
    /*
     * An address correction on a row that is still live -- someone mistyped and
     * has come back to fix it. Retiring the token is the load-bearing half: if
     * the RAW was already delivered, a working download link is sitting in the
     * wrong inbox, and only overwriting the hash takes it away. A fresh one is
     * minted and mailed to the corrected address just below.
     */
    await env.DB.prepare(
      `
        UPDATE raw_requests
        SET
          email = ?3,
          download_token_hash = NULL,
          delivery_email_sent_at = NULL
        WHERE
          photo_id = ?1
          AND visitor_id = ?2
      `,
    )
      .bind(photoId, previous.visitorId, email)
      .run();

    addressCorrected = true;
  }

  /*
   * A plain duplicate -- same address, row present, still waiting -- falls
   * through all three arms and changes nothing, exactly as the old upsert's
   * no-op did. That includes the mail below: re-sending it would retire the
   * link already sitting in the viewer's inbox for no reason, which is worse
   * than doing nothing.
   *
   * That "changes nothing" claim only holds when this caller already owns
   * the row. A different browser hitting this same fallthrough under the
   * same proven address for a photo it has never touched *does* need
   * something -- its own working link -- which is why the mail below also
   * fires for it despite nothing here being written.
   */
  if (notifyPhotographer) {
    scheduleRawRequestNotification(env.DB, env, ctx, photoId, targetVisitorId);
  }

  /*
   * fulfilledAt is non-null exactly when the RAW is already in R2, and
   * toViewerRawDownload returns null without one, so it is the whole answer
   * here -- there is no case where a row is collectable and this is null.
   *
   * Gated on !previous || addressCorrected || !requestingVisitorOwnsRow. The
   * first two are the instant-fulfil case and the corrected-address case,
   * where the previous link has just been retired and the viewer would
   * otherwise be left with nothing. The third is a genuinely different
   * browser under the same address (see requestingVisitorOwnsRow above) --
   * without a mail of its own it would be told below that a download is
   * ready and then 404 the moment it tried, since it holds no visitor token
   * the header route recognises. Everything else is the true no-op the
   * comment above describes: sendRawReadyEmail mints a fresh token and
   * overwrites download_token_hash unconditionally, so calling it for a row
   * this caller already owns, already fulfilled and unchanged, would
   * silently retire whatever link was mailed the first time.
   */
  if (
    fulfilledAt !== null &&
    (!previous || addressCorrected || !requestingVisitorOwnsRow)
  ) {
    scheduleRawReadyEmail(request, env, ctx, photoId, targetVisitorId);
  }

  /*
   * Only survives an untouched row this caller actually owns. The ask-again
   * arm clears the stamp, a fresh insert never had one, and a caller that
   * does not own the row (below) gets neither -- it has nothing of its own
   * to report.
   */
  const downloadedAt =
    previous && !notifyPhotographer && requestingVisitorOwnsRow
      ? previous.downloadedAt
      : null;

  /*
   * A caller that does not own the row cannot use its own visitor token to
   * fetch from getGalleryRawPhoto's header route, so claiming a download is
   * ready here would be a dead link the instant it tried -- device
   * independence for it comes from the mail just sent above instead. It
   * still reads as "requested" rather than "confirming": the address is
   * genuinely proven and the file genuinely exists, just not through this
   * browser.
   */
  return jsonResponse({
    requested: true,
    confirmationPending: false,
    email,
    rawDownload: requestingVisitorOwnsRow
      ? toViewerRawDownload(
          galleryPhoto,
          fulfilledAt,
          galleryPhoto.rawDeliveryTtlMs,
        )
      : null,
    rawDownloadedAt: downloadedAt,
  });
}

/*
 * Note the expiry is derived from *this* visitor's fulfilled_at, while the
 * reclaim actually runs off the newest fulfilled_at across every live request
 * for the photo. That can only ever be later, so the date shown to a viewer is
 * a floor rather than a promise -- and it stays that way on purpose, because
 * the true expiry would leak the existence of another visitor's request.
 */
function toViewerRawDownload(
  source: RawDownloadSource,
  fulfilledAt: string | null,
  rawDeliveryTtlMs: number,
): ViewerRawDownloadRecord | null {
  if (source.rawStorageKey === null || fulfilledAt === null) {
    return null;
  }

  return {
    filename: source.rawOriginalFilename ?? source.originalFilename,
    byteSize: source.rawByteSize ?? 0,
    expiresAt: new Date(
      Date.parse(fulfilledAt) + rawDeliveryTtlMs,
    ).toISOString(),
  };
}

/*
 * Whether this address has already proved itself in this event.
 *
 * There is no table of confirmed addresses, and deliberately so: a raw_requests
 * row carrying the address *is* the proof, because confirmRawRequest is the only
 * thing that ever writes one. That also self-cleans -- a viewer whose every
 * request was withdrawn (removeRawRequest) or cancelled by the photographer
 * (#221) leaves no trace in the event and simply confirms again, which is the
 * right answer rather than a bug.
 */
async function isAddressConfirmedInEvent(
  env: Env,
  eventId: string,
  email: string,
): Promise<boolean> {
  const row = await env.DB.prepare(
    `
      SELECT 1 AS found
      FROM raw_requests r
      INNER JOIN photos p
        ON p.id = r.photo_id
      WHERE
        p.event_id = ?
        AND r.email = ?
      LIMIT 1
    `,
  )
    .bind(eventId, email)
    .first<{ found: number }>();

  return row !== null;
}

/*
 * The unproven half of a request. Nothing about the requester is written into
 * raw_requests or gallery_visitors yet -- the pending row holds the visitor
 * token and display name until the address is proved, the same rule
 * auth_signup_tokens follows and for a sharper reason: a request nobody can
 * collect keeps isRawReclaimable's awaitingCount veto true and pins ~120 MB for
 * the account's full raw_delivery_ttl_ms (#225). A typo must therefore cost
 * one undeliverable email and nothing else.
 */
async function startRawRequestConfirmation(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  galleryPhoto: GalleryPhotoRow,
  photoId: string,
  visitorToken: string,
  displayName: string,
  email: string,
): Promise<Response> {
  const now = new Date();
  const nowIso = now.toISOString();

  /*
   * Counted before anything is deleted, and this order is the whole cap.
   * Replacing the pending row first and counting afterwards would mean asking
   * for the same photo over and over -- each time with a different address --
   * never accumulated a count at all, which is precisely the amplification the
   * cap exists to stop.
   */
  const capped = await hasReachedGalleryEmailCap(
    env,
    galleryPhoto.eventId,
    email,
    visitorToken,
  );

  if (!capped) {
    /*
     * A second attempt adds a row rather than replacing the first, which is
     * what gives the cap above something to count -- a replace-in-place would
     * hold the count at one however many addresses were tried.
     *
     * Leaving both live costs nothing: every pending row for this photo
     * redeems to the same request, and the first redemption deletes the rest
     * for that address anyway. A row for a *different* address staying live is
     * correct, since proving that address is exactly what it was issued for.
     */
    const token = generateAuthToken();

    await env.DB.prepare(
      `
        INSERT INTO raw_request_confirmations (
          id,
          token_hash,
          event_id,
          photo_id,
          email,
          visitor_token,
          display_name,
          created_at,
          expires_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `,
    )
      .bind(
        crypto.randomUUID(),
        await hashAuthToken(token),
        galleryPhoto.eventId,
        photoId,
        email,
        visitorToken,
        displayName,
        nowIso,
        new Date(now.getTime() + RAW_CONFIRMATION_TTL_MS).toISOString(),
      )
      .run();

    /*
     * Points at the SPA page, not the API route -- see confirmRawRequest for
     * why (#323).
     */
    ctx.waitUntil(
      sendGalleryEmailSafely(request, env, {
        kind: "raw-confirm",
        to: email,
        url: `${PUBLIC_GALLERY_ORIGIN}/g/${encodeURIComponent(
          galleryPhoto.shareToken,
        )}/raw-confirm?t=${encodeURIComponent(token)}`,
        eventTitle: galleryPhoto.eventTitle,
        filename:
          galleryPhoto.rawOriginalFilename ?? galleryPhoto.originalFilename,
        displayName,
      }),
    );
  }

  /*
   * The response is identical whether or not the cap suppressed the send. The
   * cap exists to stop a share link being used as a mail amplifier, and a
   * response that said "not sent" would tell the amplifier exactly when to
   * start again -- while a viewer who hit it genuinely is told to check their
   * mail, which is what they should do.
   */
  return jsonResponse({
    requested: false,
    confirmationPending: true,
    email,
    rawDownload: null,
    rawDownloadedAt: null,
  });
}

/*
 * Redeems a confirmation link and completes the request behind it.
 *
 * A POST from the SPA page at /g/:shareToken/raw-confirm, not a GET on the
 * mailed link itself (#323). The mailed link used to point straight at this
 * route as a GET, and mail scanners -- Outlook Safe Links, Gmail's fetcher --
 * follow every URL in a message with a GET, so the scanner's automatic fetch
 * burned the single-use token before the recipient ever clicked, while
 * silently completing the request behind their back. #193 hit the identical
 * bug for sign-in links and fixed it the same way: the mailed link lands on a
 * page that redeems the token with a deliberate press, which a scanner never
 * makes. The token now travels in a JSON body rather than the query string,
 * and every outcome is JSON rather than a rendered page -- there is no longer
 * a bare browser navigation to answer, since the SPA page owns rendering.
 *
 * Note what this deliberately does *not* do: adopt the clicking browser as the
 * requester. The pending row names the browser that made the request, and
 * confirming from a laptop must not move the request off the phone it was made
 * on -- the worker cannot read the clicking browser's localStorage anyway, and
 * transplanting a visitor token through a URL would make a forwarded email a
 * browser-identity credential. Device independence is what the download link in
 * the delivery mail is for.
 */
async function confirmRawRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  shareToken: string,
): Promise<Response> {
  const expired = jsonResponse(
    {
      error:
        "This confirmation link has expired. Open the gallery again and ask for the file — a fresh link will be on its way.",
    },
    400,
  );

  let body: { token?: string } | null;

  try {
    body = (await request.json()) as { token?: string } | null;
  } catch {
    return expired;
  }

  const token = body?.token?.trim();

  if (!token) {
    return expired;
  }

  const confirmation = await env.DB.prepare(
    `
      SELECT
        c.id AS id,
        c.event_id AS eventId,
        c.photo_id AS photoId,
        c.email AS email,
        c.visitor_token AS visitorToken,
        c.display_name AS displayName,
        c.expires_at AS expiresAt
      FROM raw_request_confirmations c
      INNER JOIN events e
        ON e.id = c.event_id
      WHERE
        c.token_hash = ?
        AND e.share_token = ?
    `,
  )
    .bind(await hashAuthToken(token), shareToken)
    .first<RawConfirmationRow>();

  if (!confirmation) {
    return expired;
  }

  /*
   * Single-use, and deleted before anything else happens so a double click
   * cannot run the write twice. The row is gone either way -- an expired token
   * is not worth keeping around to be tried again.
   */
  await env.DB.prepare(
    `
      DELETE FROM raw_request_confirmations
      WHERE id = ?
    `,
  )
    .bind(confirmation.id)
    .run();

  if (Date.parse(confirmation.expiresAt) <= Date.now()) {
    return expired;
  }

  /*
   * Re-read the photo through the same choke point the request itself used, so
   * a gallery that was archived, or a photo deleted, between asking and
   * confirming takes the request away with it.
   */
  const galleryPhoto = await findPhotoInShare(
    env,
    shareToken,
    confirmation.photoId,
  );

  if (!galleryPhoto) {
    return jsonResponse(
      {
        error:
          "This gallery is no longer available. The photographer has closed it or removed the photo, so the original file cannot be sent.",
      },
      404,
    );
  }

  const visitor = await upsertGalleryVisitor(
    env,
    confirmation.eventId,
    confirmation.visitorToken,
    confirmation.displayName,
  );

  if (!visitor) {
    return jsonResponse(
      {
        error:
          "The request could not be saved. Open the gallery and try again.",
      },
      500,
    );
  }

  /*
   * Any other pending link for this address in this event is now redundant --
   * the address is proved, so the rest would only be a second way to confirm
   * something that no longer needs confirming.
   */
  await env.DB.prepare(
    `
      DELETE FROM raw_request_confirmations
      WHERE
        event_id = ?
        AND email = ?
    `,
  )
    .bind(confirmation.eventId, confirmation.email)
    .run();

  await writeRawRequest(
    request,
    env,
    ctx,
    galleryPhoto,
    confirmation.photoId,
    visitor.id,
    confirmation.email,
  );

  return jsonResponse({ photoId: confirmation.photoId });
}

/*
 * Whether this event has already sent as much mail as it may on behalf of this
 * address or this browser. See RAW_EMAIL_CAP_WINDOW_MS for why both halves are
 * needed.
 *
 * Confirmation sends are counted through the pending rows and delivery sends
 * through raw_requests, so the two paths share one budget -- otherwise the
 * cheaper path would simply be used twice as hard.
 */
async function hasReachedGalleryEmailCap(
  env: Env,
  eventId: string,
  email: string,
  visitorToken: string,
): Promise<boolean> {
  const since = new Date(Date.now() - RAW_EMAIL_CAP_WINDOW_MS).toISOString();

  const counts = await env.DB.prepare(
    `
      SELECT
        (
          SELECT COUNT(*)
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          WHERE
            p.event_id = ?1
            AND r.email = ?2
            AND r.delivery_email_sent_at > ?4
        ) + (
          SELECT COUNT(*)
          FROM raw_request_confirmations c
          WHERE
            c.event_id = ?1
            AND c.email = ?2
            AND c.created_at > ?4
        ) AS addressCount,
        (
          SELECT COUNT(*)
          FROM raw_requests r
          INNER JOIN photos p ON p.id = r.photo_id
          INNER JOIN gallery_visitors v ON v.id = r.visitor_id
          WHERE
            p.event_id = ?1
            AND v.visitor_token = ?3
            AND r.delivery_email_sent_at > ?4
        ) + (
          SELECT COUNT(*)
          FROM raw_request_confirmations c
          WHERE
            c.event_id = ?1
            AND c.visitor_token = ?3
            AND c.created_at > ?4
        ) AS visitorCount
    `,
  )
    .bind(eventId, email, visitorToken, since)
    .first<{ addressCount: number; visitorCount: number }>();

  if (!counts) {
    return false;
  }

  return (
    counts.addressCount >= RAW_EMAIL_CAP_PER_ADDRESS ||
    counts.visitorCount >= RAW_EMAIL_CAP_PER_VISITOR
  );
}

/*
 * Mails the download link for one fulfilled request, and stamps that it did.
 *
 * Everything here is best-effort and nothing it does may reach the caller. It
 * runs behind the iPad's RAW upload response and behind a viewer's request, and
 * a RAW that was stored successfully must never be reported as a failed upload
 * because Resend was slow or unconfigured -- the file is there either way, and
 * the viewer can still collect it in the gallery.
 *
 * The plaintext token exists only inside this function. It is minted here,
 * mailed here, and only its hash is written down -- which is also why the mail
 * cannot be re-sent later from stored state: a resend mints a new token and
 * retires the old link, exactly as an address correction does.
 */
async function sendRawReadyEmail(
  request: Request,
  env: Env,
  photoId: string,
  visitorId: string,
): Promise<void> {
  try {
    const recipient = await env.DB.prepare(
      `
        SELECT
          r.visitor_id AS visitorId,
          r.email AS email,
          v.display_name AS displayName,
          v.visitor_token AS visitorToken,
          e.id AS eventId,
          e.title AS eventTitle,
          e.share_token AS shareToken,
          COALESCE(p.raw_original_filename, p.original_filename) AS filename
        FROM raw_requests r
        INNER JOIN gallery_visitors v
          ON v.id = r.visitor_id
        INNER JOIN photos p
          ON p.id = r.photo_id
        INNER JOIN events e
          ON e.id = p.event_id
        WHERE
          r.photo_id = ?
          AND r.visitor_id = ?
          AND r.email IS NOT NULL
          AND r.fulfilled_at IS NOT NULL
      `,
    )
      .bind(photoId, visitorId)
      .first<
        RawDeliveryRecipientRow & { eventId: string; visitorToken: string }
      >();

    if (!recipient) {
      return;
    }

    if (
      await hasReachedGalleryEmailCap(
        env,
        recipient.eventId,
        recipient.email,
        recipient.visitorToken,
      )
    ) {
      return;
    }

    const token = generateAuthToken();

    /*
     * Stamped before the send rather than after it. A send that throws has
     * still consumed the budget the cap is protecting, and a delivery mail that
     * silently retried on every poll of the photo list would be the exact
     * amplifier the cap exists to prevent.
     */
    await env.DB.prepare(
      `
        UPDATE raw_requests
        SET
          download_token_hash = ?,
          delivery_email_sent_at = ?
        WHERE
          photo_id = ?
          AND visitor_id = ?
      `,
    )
      .bind(
        await hashAuthToken(token),
        new Date().toISOString(),
        photoId,
        visitorId,
      )
      .run();

    await sendGalleryEmailSafely(request, env, {
      kind: "raw-ready",
      to: recipient.email,
      url:
        `${PUBLIC_GALLERY_ORIGIN}/api/galleries/${encodeURIComponent(
          recipient.shareToken,
        )}/photos/${encodeURIComponent(photoId)}/raw` +
        `?t=${encodeURIComponent(token)}`,
      eventTitle: recipient.eventTitle,
      filename: recipient.filename,
      displayName: recipient.displayName,
    });
  } catch (error) {
    console.error("Unable to send a RAW delivery email:", error);
  }
}

function scheduleRawReadyEmail(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  photoId: string,
  visitorId: string,
): void {
  ctx.waitUntil(sendRawReadyEmail(request, env, photoId, visitorId));
}

/*
 * The console fallback is localhost-only, exactly as it is for sign-in mail, so
 * a production deployment without RESEND_API_KEY cannot write working download
 * links into the observability log. Off localhost that throws, and this is where
 * the throw stops: see sendRawReadyEmail for why gallery mail swallows what auth
 * mail turns into a 500.
 */
async function sendGalleryEmailSafely(
  request: Request,
  env: Env,
  email: Parameters<typeof sendGalleryEmail>[1],
): Promise<void> {
  try {
    await sendGalleryEmail(
      env as EmailEnvironment,
      email,
      isLocalRequest(request),
    );
  } catch (error) {
    console.error(`Unable to send a ${email.kind} email:`, error);
  }
}

/*
 * A whole-page response for the two routes a viewer reaches by clicking a link
 * in an email rather than by fetch: the confirmation redemption and the
 * token-authenticated download. A JSON error body is the right answer to the
 * gallery's own fetches and the wrong one in a browser window, where it reads
 * as a broken link rather than an expired one.
 */
function galleryMessagePage(
  heading: string,
  detail: string,
  status: number,
): Response {
  const body = [
    "<!doctype html>",
    '<html lang="en"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${escapeHtml(heading)}</title></head>`,
    '<body style="font-family: system-ui, sans-serif; margin: 0; padding: 2rem; line-height: 1.5;">',
    `<h1 style="font-size: 1.25rem;">${escapeHtml(heading)}</h1>`,
    `<p>${escapeHtml(detail)}</p>`,
    "</body></html>",
  ].join("");

  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "private, no-store",
    },
  });
}

async function removeRawRequest(
  request: Request,
  env: Env,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  if (!visitorToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  const galleryPhoto = await findPhotoInShare(env, shareToken, photoId);

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
        DELETE FROM raw_requests
        WHERE
          photo_id = ?
          AND visitor_id = ?
      `,
    )
      .bind(photoId, visitor.id)
      .run();
  }

  await reclaimRawPhotos(env.DB, env, "p.id = ?", photoId);

  return jsonResponse({
    requested: false,
  });
}

/*
 * The reclaim predicate (#209), kept as a pure function over one row so the
 * policy is readable in one place and testable without R2.
 *
 * Order matters. The TTL is checked first because it is unconditional -- it is
 * the half of the policy that bounds the abandoned-requester case, and a
 * requester who never returns would otherwise keep awaitingCount above zero
 * indefinitely and veto every later branch.
 */
function isRawReclaimable(row: RawReclaimRow, now: number): boolean {
  if (
    row.lastFulfilledAt !== null &&
    now - Date.parse(row.lastFulfilledAt) >= row.rawDeliveryTtlMs
  ) {
    return true;
  }

  /*
   * Somebody is still owed these bytes: either their request has not been
   * stamped fulfilled yet, or it has and they have not collected. Either way
   * the object stays.
   */
  if (row.awaitingCount > 0) {
    return false;
  }

  /*
   * No live requests at all. Two ways to get here, both meaning nobody is
   * waiting: every requester withdrew after the RAW landed (removeRawRequest
   * DELETEs the row, which is what would otherwise orphan the object), or a
   * RAW was uploaded for a photo whose only request was withdrawn mid-upload.
   * No grace period -- a grace period protects an interrupted download, and
   * there is nobody here to have interrupted one.
   */
  if (row.liveRequestCount === 0) {
    return true;
  }

  /*
   * Every live request has been collected *and* the photographer has confirmed
   * it (#219). Checked ahead of the grace comparison rather than folded into
   * it, because it is not a shorter grace period -- it is the fact the grace
   * period was only ever a proxy for. The route can see a download start but
   * never its end (migration 0021), so it waits a day; a requester who says
   * "got it" has answered the question the day was buying an answer to.
   *
   * The awaitingCount veto above still runs first, so this can only fire when
   * nobody is mid-transaction: a visitor who requests the photo after a
   * release inserts an unreleased row and lands here as awaiting, not as
   * released.
   */
  if (row.unreleasedCount === 0) {
    return true;
  }

  return (
    row.lastDownloadedAt !== null &&
    now - Date.parse(row.lastDownloadedAt) >= RAW_DOWNLOAD_GRACE_MS
  );
}

/*
 * Deletes every delivered RAW matching `photoFilter` that the policy above no
 * longer justifies keeping, and gives the account its bytes back.
 *
 * This runs from public, unauthenticated request paths (the download route and
 * removeRawRequest) as well as from the iPad's poll and the manual release
 * route, so it cannot take an AccountScope -- there is no principal on the
 * public side to build one from.
 * It reads account_id off the photo row instead and adjusts that account
 * directly. That is safe because the caller never chooses the account: the
 * filter narrows to one photo or one event, and the row itself names which
 * account's counter to move. It also keeps the aggregate off the whole table.
 *
 * There is no cron in this project (deliberately -- see CLAUDE.md on
 * migrations and workflows), so the TTL half of the policy only advances when
 * one of those callers runs. The iPad's per-event photo poll is the reliable
 * one: a gallery nobody ever opens again still has its abandoned requests
 * swept, because the photographer's app keeps asking about the event.
 *
 * Failure here is deliberately silent. A reclaim that half-fails leaves bytes
 * in R2 that the database no longer counts, which the dashboard's
 * refreshAccountStorageBytes reconciliation is already built to absorb; taking
 * a viewer's download or the iPad's poll down over it would be far worse.
 */
async function reclaimRawPhotos(
  database: D1Database,
  env: TenantEnv,
  photoFilter: string,
  filterValue: string,
): Promise<void> {
  let candidates: D1Result<RawReclaimRow>;

  try {
    candidates = await database
      .prepare(
        `
        SELECT
          p.id AS photoId,
          p.account_id AS accountId,
          a.raw_delivery_ttl_ms AS rawDeliveryTtlMs,
          p.raw_storage_key AS rawStorageKey,
          p.raw_byte_size AS rawByteSize,
          COUNT(r.photo_id) AS liveRequestCount,
          COALESCE(
            SUM(
              CASE
                /*
                 * The r.photo_id test is load-bearing, not defensive. This is
                 * a LEFT JOIN, so a photo with no requests at all still
                 * produces one row with every r.* column NULL -- and without
                 * this guard "r.fulfilled_at IS NULL" is true for that
                 * phantom row, making a RAW nobody is waiting for look like a
                 * RAW somebody is waiting for, forever.
                 */
                WHEN
                  r.photo_id IS NOT NULL
                  AND (r.fulfilled_at IS NULL OR r.downloaded_at IS NULL)
                THEN 1
                ELSE 0
              END
            ),
            0
          ) AS awaitingCount,
          COALESCE(
            SUM(
              CASE
                /* Same phantom-row guard as awaitingCount above. */
                WHEN r.photo_id IS NOT NULL AND r.released_at IS NULL
                THEN 1
                ELSE 0
              END
            ),
            0
          ) AS unreleasedCount,
          MAX(r.fulfilled_at) AS lastFulfilledAt,
          MAX(r.downloaded_at) AS lastDownloadedAt
        FROM photos p
        INNER JOIN accounts a
          ON a.id = p.account_id
        LEFT JOIN raw_requests r
          ON r.photo_id = p.id
        WHERE
          p.raw_storage_key IS NOT NULL
          AND ${photoFilter}
        GROUP BY p.id
      `,
      )
      .bind(filterValue)
      .all<RawReclaimRow>();
  } catch (error) {
    console.error("Unable to look for reclaimable RAW files:", error);
    return;
  }

  const now = Date.now();

  for (const row of candidates.results) {
    if (!isRawReclaimable(row, now)) {
      continue;
    }

    try {
      await env.pickpic_photos.delete(row.rawStorageKey);
    } catch (error) {
      console.error("Unable to delete a reclaimed RAW file:", error);
      continue;
    }

    try {
      /*
       * Clearing raw_uploaded_at alongside the rest is what lets a later
       * request re-arm the pipeline: with no raw_storage_key, addRawRequest
       * leaves fulfilled_at NULL, listPhotos counts the request as pending
       * again, and the iPad re-uploads. The raw_requests rows themselves stay
       * -- they are the history the gallery reads to tell a visitor they
       * already collected this one.
       */
      await database.batch([
        database
          .prepare(
            `
            UPDATE photos
            SET
              raw_storage_key = NULL,
              raw_original_filename = NULL,
              raw_content_type = NULL,
              raw_byte_size = NULL,
              raw_sha256 = NULL,
              raw_uploaded_at = NULL
            WHERE id = ?
          `,
          )
          .bind(row.photoId),

        database
          .prepare(
            `
            UPDATE accounts
            SET storage_bytes = MAX(0, storage_bytes - ?)
            WHERE id = ?
          `,
          )
          .bind(row.rawByteSize ?? 0, row.accountId),
      ]);
    } catch (error) {
      console.error("Unable to record a reclaimed RAW file:", error);
    }
  }
}

async function clearPhotoHearts(
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT id
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<{ id: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  await scope.database
    .prepare(
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

/*
 * "I fulfilled the wrong photo" / "the requester forgot" (#221), for one
 * photo. This is the other half of releaseCollectedRawPhotos (#219) that
 * issue deliberately left out: taking back a RAW nobody has downloaded yet,
 * rather than one every live requester has already collected.
 *
 * That difference means this can't reuse released_at the way #219 does.
 * isRawReclaimable's awaitingCount veto (the first real check it runs) counts
 * any live row with downloaded_at IS NULL, full stop -- it never looks at
 * released_at, which only starts to matter once every row already has a
 * downloaded_at. Stamping released_at on an undelivered row would leave it
 * vetoing reclaim forever, achieving nothing. So this deletes the row
 * outright instead, exactly like removeRawRequest already does for a visitor
 * who withdraws their own request -- and for the same reason: a withdrawn or
 * cancelled request has no history worth keeping, unlike a collected one.
 *
 * Scoped to fulfilled_at IS NOT NULL because an unfulfilled request (nobody
 * has uploaded anything yet) is a request to decline, not a delivery to
 * cancel -- a different action this issue doesn't cover. Scoped to one photo,
 * not the event, because the issue is explicit that a blanket per-event
 * cancel would revoke every outstanding delivery in a shoot in one click.
 */
async function cancelUndeliveredRawRequests(
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT id
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<{ id: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const result = await scope.database
    .prepare(
      `
      DELETE FROM raw_requests
      WHERE
        photo_id = ?
        AND fulfilled_at IS NOT NULL
        AND downloaded_at IS NULL
    `,
    )
    .bind(photoId)
    .run();

  /*
   * Awaited rather than deferred, matching releaseCollectedRawPhotos: this
   * route exists to make the bytes go away now, and the dashboard's storage
   * figure reloads the moment it returns.
   */
  await reclaimRawPhotos(scope.database, env, "p.id = ?", photoId);

  return jsonResponse({
    photoId,
    cancelledRequestCount: result.meta.changes ?? 0,
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
  database: D1Database,
  eventId: string,
): Promise<Map<string, CommentRow[]>> {
  const result = await database
    .prepare(
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

  const parsedBody = await parseJsonObjectBody<CommentRequestBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const requestBody = parsedBody;

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

  const galleryPhoto = await findPhotoInShare(env, shareToken, photoId);

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

  const parsedBody = await parseJsonObjectBody<UpdateCommentRequestBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const requestBody = parsedBody;

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
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const parsedBody = await parseJsonObjectBody<SetPhotoWorkflowBody>(
    request,
    "The request body must be valid JSON.",
  );

  if (parsedBody instanceof Response) {
    return parsedBody;
  }

  const body = parsedBody;

  if (!isPhotoWorkflowStatus(body.status)) {
    return jsonResponse(
      {
        error: "The status must be idle, editing, or final.",
      },
      400,
    );
  }

  const photo = await scope
    .prepare(
      `
      SELECT
        id,
        workflow_status AS workflowStatus,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
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
    await scope.database.batch([
      scope.database
        .prepare(
          `
          UPDATE photos
          SET workflow_status = ?
          WHERE id = ?
        `,
        )
        .bind(body.status, photoId),

      scope.database
        .prepare(
          `
          DELETE FROM hearts
          WHERE photo_id = ?
        `,
        )
        .bind(photoId),
    ]);
  } else {
    await scope.database
      .prepare(
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
    heartCount:
      body.status === "final"
        ? 0
        : await getHeartCount(scope.database, photoId),
  });
}

async function getStoredJpeg(
  env: TenantEnv,
  storageKey: string,
): Promise<Response> {
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

/*
 * The cache key for one stored image, derived from its R2 key rather than from
 * the request URL.
 *
 * R2 keys here are write-once. A proof carries a freshly minted photo UUID
 * (`events/<event>/photos/<photo>/preview.jpg`), and finals, RAWs and variants
 * each carry a fresh upload UUID, so re-uploading any of them writes a *new*
 * key instead of new bytes under the old one. The bytes at a given key
 * therefore never change, which is what makes a cached entry impossible to go
 * stale and justifies the one-year immutable Cache-Control getStoredJpeg
 * already sends.
 *
 * Keying on the object rather than the URL also means rotating an event's share
 * token keeps hitting cache -- same bytes, same object -- without that being a
 * leak: the new token still had to pass findPhotoInShare's status gate before
 * anything looked in the cache at all.
 *
 * The synthetic path has to sit on the request's own origin, because
 * caches.default only accepts keys within the zone serving the request. It is
 * never routed; a cache key is a lookup identity, not a reachable URL.
 */
export function buildStoredImageCacheKey(
  requestUrl: string,
  storageKey: string,
): string {
  const cacheUrl = new URL(requestUrl);

  cacheUrl.pathname = `/__image-object/${encodeURIComponent(storageKey)}`;
  cacheUrl.search = "";
  cacheUrl.hash = "";

  return cacheUrl.toString();
}

/*
 * getStoredJpeg, with the colo cache in front of the R2 read.
 *
 * Cloudflare only fills its edge cache from fetch() subrequests or from
 * requests that miss the Worker entirely, and `run_worker_first: ["/api/*"]`
 * (wrangler.jsonc) routes every image URL through this Worker -- so the
 * immutable Cache-Control getStoredJpeg sets has only ever reached browsers.
 * A gallery handed to a wedding party is the normal case: 40 guests x 300
 * thumbnails is 12,000 R2 reads of about 300 distinct objects, and the browser
 * cache does nothing to share them between viewers.
 *
 * **Only ever call this once the caller's access check has already passed for
 * this request.** The cache is an R2 read optimization and never an
 * authorization decision -- it cannot tell who is asking. Hoisting the lookup
 * above findPhotoInShare, or folding it into getStoredJpeg where a caller could
 * reach it without a gate, would resurrect #124: archiving an event would take
 * the gallery page away while leaving every image URL serving from cache to
 * anyone who kept a link.
 *
 * Neither half may break image serving. A cache miss is the status quo, and a
 * failed read or write is logged and ignored rather than surfaced -- local
 * `wrangler dev` treats caches.default as a no-op, and an image that uploaded
 * fine must not 500 because the cache declined it.
 */
async function getCachedStoredJpeg(
  request: Request,
  env: TenantEnv,
  ctx: ExecutionContext,
  storageKey: string,
): Promise<Response> {
  const cache = caches.default;
  const cacheKey = buildStoredImageCacheKey(request.url, storageKey);

  try {
    const cached = await cache.match(cacheKey);

    if (cached) {
      return cached;
    }
  } catch (error) {
    console.error("Failed to read the image cache:", error);
  }

  const response = await getStoredJpeg(env, storageKey);

  /*
   * Only a served image is worth storing. A 404 here means the D1 row and R2
   * disagree, which is a transient repair case, not something to pin for a
   * year.
   */
  if (response.status === 200) {
    /*
     * The body streams and can only be consumed once, so the cache takes the
     * clone and the caller takes the original. waitUntil keeps the write alive
     * past the response.
     */
    ctx.waitUntil(
      cache.put(cacheKey, response.clone()).catch((error: unknown) => {
        console.error("Failed to write the image cache:", error);
      }),
    );
  }

  return response;
}

function toImageVariantRecord(
  row: PhotoVariantRow,
  imageBasePath: string,
): ImageVariantRecord {
  return {
    imageUrl:
      `${imageBasePath}/${encodeURIComponent(
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
  database: D1Database,
  eventId: string,
  imageBasePath: string,
): Promise<Map<string, PhotoVariantsBySource>> {
  const result = await database
    .prepare(
      `
      SELECT
        v.photo_id AS photoId,
        v.source_kind AS sourceKind,
        v.variant_kind AS variantKind,
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

    const variant = toImageVariantRecord(row, imageBasePath);

    if (row.variantKind === "thumbnail") {
      sourceVariants.thumbnail = variant;
    } else {
      sourceVariants.preview = variant;
    }

    variantsByPhoto.set(row.photoId, photoVariants);
  }

  return variantsByPhoto;
}

async function getAdminFinalPhotoImage(
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
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

async function getGalleryFinalPhotoImage(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const photo = await findPhotoInShare(env, shareToken, photoId);

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  if (!photo.finalStorageKey) {
    return jsonResponse(
      { error: "This photo does not have a final image yet." },
      404,
    );
  }

  /* Cached only below the status gate above -- see getCachedStoredJpeg. */
  return getCachedStoredJpeg(request, env, ctx, photo.finalStorageKey);
}

/*
 * Hands the delivered RAW to the one visitor who asked for it (#209).
 *
 * Scoping is findPhotoInShare -- the same choke point every other public photo
 * read goes through, so an archived or draft event takes the download away
 * with the gallery -- plus a second check that this visitor token owns a
 * *fulfilled* raw_requests row for this photo. A share link alone is not
 * enough: the RAW is the photographer's original, delivered to one named
 * requester, not gallery content.
 *
 * This deliberately does NOT go through getStoredJpeg. That helper sends
 * `public, max-age=31536000, immutable`, which on this route would be actively
 * dangerous in two directions at once: Cloudflare's edge would keep serving a
 * private original for a year after the reclaim deleted it from R2, and the
 * reclaim itself -- the entire point of #209 -- would free storage while the
 * bytes stayed retrievable. The hazard is already flagged in the comment above
 * findPhotoInShare for the image routes; here it is disqualifying.
 */
async function getGalleryRawPhoto(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  url: URL,
  shareToken: string,
  photoId: string,
): Promise<Response> {
  const visitorToken = getVisitorToken(request);

  /*
   * Either credential works (#224). The header is the gallery's own fetch, and
   * ?t= is the link in the delivery email -- which is the whole point of that
   * email, since the header lives in one browser's localStorage and the file is
   * routinely collected on a different device.
   *
   * This concedes the objection recorded at GalleryPage.tsx's downloadRawPhoto:
   * a token in a URL is a credential somewhere shareable and loggable. It is
   * accepted here because this one is single-purpose, scoped to one photo,
   * expires with the file, is retired and replaced on every re-delivery or
   * address correction, and is only ever sent to a confirmed address.
   */
  const downloadToken = url.searchParams.get("t")?.trim() || null;

  if (!visitorToken && !downloadToken) {
    return jsonResponse({ error: "A valid visitor token is required." }, 400);
  }

  const photo = await findPhotoInShare(env, shareToken, photoId);

  if (!photo) {
    return downloadToken
      ? galleryMessagePage(
          "This gallery is no longer available",
          "The photographer has closed it or removed the photo, so the original file cannot be downloaded.",
          404,
        )
      : jsonResponse({ error: "Photo not found." }, 404);
  }

  /*
   * One message for "never delivered", "already reclaimed" and "not yours",
   * and one status code, so the route cannot be used to probe which photos
   * other visitors have RAWs waiting for. A browser that followed a link from
   * an email gets the same refusal as a page, because a JSON body in a window
   * reads as a broken link rather than an expired one.
   */
  const unavailable = downloadToken
    ? galleryMessagePage(
        "This download link has expired",
        "The original file is no longer being held. Open the gallery and ask for it again if you still need it.",
        404,
      )
    : jsonResponse(
        { error: "This RAW file is not available to download." },
        404,
      );

  /*
   * Not gated on photo.rawRequestsEnabled. The event's current toggle only
   * governs whether a *new* request can be created (addRawRequest's own
   * gate) -- a request already fulfilled here must stay downloadable after
   * the photographer disables new requests, or disabling strands whoever is
   * mid-delivery with no way back in (#237). The fulfilledAt check just below
   * is what actually decides whether this visitor has anything to collect.
   */
  if (photo.rawStorageKey === null) {
    return unavailable;
  }

  /*
   * Both lookups land on the same row shape and the same checks below. The
   * token branch still narrows by photo and event rather than trusting the
   * token alone, so a token minted for one photo cannot be pointed at another,
   * and a share token from a different event cannot be paired with it.
   */
  const rawRequest = downloadToken
    ? await env.DB.prepare(
        `
      SELECT
        r.visitor_id AS visitorId,
        r.fulfilled_at AS fulfilledAt
      FROM raw_requests r
      INNER JOIN gallery_visitors v
        ON v.id = r.visitor_id
      WHERE
        r.photo_id = ?
        AND v.event_id = ?
        AND r.download_token_hash = ?
    `,
      )
        .bind(photoId, photo.eventId, await hashAuthToken(downloadToken))
        .first<RawRequestOwnerRow>()
    : await env.DB.prepare(
        `
      SELECT
        r.visitor_id AS visitorId,
        r.fulfilled_at AS fulfilledAt
      FROM raw_requests r
      INNER JOIN gallery_visitors v
        ON v.id = r.visitor_id
      WHERE
        r.photo_id = ?
        AND v.event_id = ?
        AND v.visitor_token = ?
    `,
      )
        .bind(photoId, photo.eventId, visitorToken)
        .first<RawRequestOwnerRow>();

  if (!rawRequest || rawRequest.fulfilledAt === null) {
    return unavailable;
  }

  /*
   * An emailed link dies with the file it points at. The reclaim is what
   * actually removes the bytes, and it runs on the iPad's poll rather than on a
   * timer, so an object can outlive its window by a little -- honouring the
   * stated expiry here rather than waiting for the sweep means the link stops
   * working when the viewer was told it would.
   */
  if (
    downloadToken &&
    Date.now() - Date.parse(rawRequest.fulfilledAt) >= photo.rawDeliveryTtlMs
  ) {
    return unavailable;
  }

  const object = await env.pickpic_photos.get(photo.rawStorageKey);

  if (!object) {
    return unavailable;
  }

  /*
   * The stamp rides on the body draining, not on the request arriving, which
   * supersedes migration 0021's note that the end of a transfer cannot be
   * observed here (#239). It can, in the one sense that matters: piping R2's
   * body through a FixedLengthStream gives a promise that resolves only after
   * exactly `object.size` bytes have been accepted downstream, and the runtime
   * applies the client connection's backpressure the whole way. A transfer
   * that dies at 80% on venue Wi-Fi rejects instead, leaving downloaded_at
   * NULL -- so the button still reads "Download RAW" and nothing behind it has
   * been spent.
   *
   * This got sharper with #220, which gave the photographer a release that
   * skips RAW_DOWNLOAD_GRACE_MS outright. Its eligibility rule reads
   * downloaded_at as "collected", so a stamp written for a transfer nobody
   * ever received meant a per-event release could delete those bytes with no
   * retry window at all.
   *
   * It is still not an acknowledgement from the browser -- the last hop out of
   * the edge is not ours to see -- which is exactly why the grace period stays
   * rather than being tightened on the back of this.
   */
  const relay = new FixedLengthStream(object.size);

  ctx.waitUntil(
    object.body.pipeTo(relay.writable).then(
      () => recordRawDownload(env, photoId, rawRequest.visitorId),
      (error) => {
        /*
         * Every interrupted download lands here, so this is a normal outcome
         * rather than a fault: say so quietly, leave the stamp unwritten, and
         * let the viewer retry against bytes that are still there.
         */
        console.warn("A RAW file download did not complete:", error);
      },
    ),
  );

  /*
   * Deliberately no reclaim sweep here. It would be deleting the R2 object
   * this response is still streaming from -- and now that the stamp lands
   * after the drain rather than before it, the grace clock that used to make
   * the predicate trivially false has not even started at this point. The
   * bytes are collected by the sweep on the iPad's photo poll instead.
   */

  const filename = photo.rawOriginalFilename ?? photo.originalFilename;
  const headers = new Headers();

  headers.set("Content-Type", photo.rawContentType ?? RAW_CONTENT_TYPE);
  headers.set("Content-Length", object.size.toString());

  /*
   * Both forms, because the ASCII fallback is what a browser uses when it
   * cannot parse filename*, and a RAW name can carry anything the camera or
   * the photographer put in it. Quotes and backslashes are stripped rather
   * than escaped so the fallback cannot break out of its own quoting.
   */
  headers.set(
    "Content-Disposition",
    `attachment; filename="${filename.replace(/["\\]/g, "")}"; ` +
      `filename*=UTF-8''${encodeURIComponent(filename)}`,
  );

  headers.set("Cache-Control", "private, no-store");
  headers.set("X-Content-Type-Options", "nosniff");

  /*
   * No ETag and no Accept-Ranges. A range request would let a client resume a
   * transfer we have already stamped as downloaded, across a reclaim that may
   * have removed the object underneath it; a retry of the whole file is both
   * simpler to reason about and what the grace period is sized for.
   */
  return new Response(relay.readable, {
    status: 200,
    headers,
  });
}

/*
 * Writes the collection stamp for a RAW the visitor has now actually received.
 *
 * Runs from a waitUntil after the response has already gone, which is what
 * makes swallowing the error the right call here: there is no request left to
 * fail, the visitor has their file either way, and losing the stamp only costs
 * storage-days because the account's raw_delivery_ttl_ms (#225) still collects
 * the object.
 */
async function recordRawDownload(
  env: Env,
  photoId: string,
  visitorId: string,
): Promise<void> {
  try {
    await env.DB.prepare(
      `
        UPDATE raw_requests
        SET downloaded_at = ?
        WHERE
          photo_id = ?
          AND visitor_id = ?
      `,
    )
      .bind(new Date().toISOString(), photoId, visitorId)
      .run();
  } catch (error) {
    console.error("Unable to record a RAW file download:", error);
  }
}

async function uploadFinalPhoto(
  request: Request,
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT
        event_id AS eventId,
        final_storage_key AS finalStorageKey,
        final_byte_size AS finalByteSize
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<FinalPhotoUploadRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const oldFinalVariants = await scope.database
    .prepare(
      `
      SELECT
        storage_key AS storageKey,
        byte_size AS byteSize
      FROM photo_variants
      WHERE
        photo_id = ?
        AND source_kind = 'final'
    `,
    )
    .bind(photoId)
    .all<StoredVariantRow>();

  /*
   * What replacing the final image will free -- the old final plus its
   * optimized variants, which the batch below deletes. Enforcement checks
   * the net change against the cap, not the new file's raw size, so
   * replacing a final with one of similar size doesn't get blocked at 100%
   * usage.
   */
  const replacedFinalBytes =
    (photo.finalByteSize ?? 0) +
    oldFinalVariants.results.reduce(
      (sum, variant) => sum + variant.byteSize,
      0,
    );

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

  const declaredSize = parseDeclaredContentLength(request);

  if (Number.isFinite(declaredSize) && declaredSize > MAX_FINAL_JPEG_BYTES) {
    return jsonResponse(
      { error: "The final JPEG must be 50 MB or smaller." },
      413,
    );
  }

  if (
    Number.isFinite(declaredSize) &&
    wouldExceedStorageCap(scope.account, declaredSize - replacedFinalBytes)
  ) {
    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
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

  await refreshAccountStorageBytes(scope);

  if (
    wouldExceedStorageCap(scope.account, storedObject.size - replacedFinalBytes)
  ) {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

  const uploadedAt = new Date().toISOString();

  try {
    await scope.database.batch([
      scope.database
        .prepare(
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
        )
        .bind(
          newStorageKey,
          originalFilename,
          "image/jpeg",
          storedObject.size,
          uploadedAt,
          finalSha256,
          photoId,
        ),

      scope.database
        .prepare(
          `
          DELETE FROM hearts
          WHERE photo_id = ?
        `,
        )
        .bind(photoId),

      scope.database
        .prepare(
          `
        DELETE FROM photo_variants
        WHERE
          photo_id = ?
          AND source_kind = 'final'
        `,
        )
        .bind(photoId),
    ]);
  } catch {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "The final photo metadata could not be saved." },
      500,
    );
  }

  await adjustAccountStorageBytes(
    scope,
    storedObject.size - replacedFinalBytes,
  );

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
      `${ADMIN_PHOTO_IMAGE_BASE}/${encodeURIComponent(photoId)}/final-image` +
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

/*
 * Accepts the original RAW for a photo a gallery viewer asked for (#205).
 *
 * This is the only path on which a full original leaves the iPad -- everything
 * else in the pipeline uploads a derived proof or a delivered edit -- so it is
 * held to the same two-step storage check as uploadFinalPhoto above rather
 * than the cheaper declared-size check alone.
 *
 * Storage is per photo, not per request: one photo has one original, and every
 * visitor who asked for it is served the same object. So a second visitor
 * requesting an already-delivered RAW must not make the iPad send it again --
 * which is why the batch below stamps *every* unfulfilled request rather than
 * one, and why the iPad's own filter tests rawPhoto == nil as well as the
 * pending count.
 */
async function uploadRawPhoto(
  request: Request,
  env: TenantEnv,
  ctx: ExecutionContext,
  scope: AccountScope,
  photoId: string,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT
        event_id AS eventId,
        raw_storage_key AS rawStorageKey,
        raw_byte_size AS rawByteSize
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<RawPhotoUploadRow>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  /*
   * What replacing an already-delivered RAW frees. Enforcement is against the
   * net change for the same reason uploadFinalPhoto's is: re-delivering a RAW
   * of similar size shouldn't be blocked by an account sitting near its cap.
   */
  const replacedRawBytes = photo.rawByteSize ?? 0;

  const contentType = request.headers
    .get("Content-Type")
    ?.split(";")[0]
    .trim()
    .toLowerCase();

  /*
   * No RAW format has a registered media type, and the app must not grow a new
   * branch here for every camera. The filename carries the format and
   * photos.original_filename already records it (trap 6), so the body is
   * accepted as opaque bytes.
   */
  if (contentType !== RAW_CONTENT_TYPE) {
    return jsonResponse(
      { error: `RAW uploads must be sent as ${RAW_CONTENT_TYPE}.` },
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

  const rawSha256 = getSourceSha256(request);

  if (!rawSha256) {
    return jsonResponse(
      {
        error: "A valid lowercase SHA-256 value is required in X-File-SHA256.",
      },
      400,
    );
  }

  if (!request.body) {
    return jsonResponse({ error: "The RAW file body is required." }, 400);
  }

  const declaredSize = parseDeclaredContentLength(request);

  if (Number.isFinite(declaredSize) && declaredSize > MAX_RAW_BYTES) {
    return jsonResponse({ error: RAW_TOO_LARGE_MESSAGE }, 413);
  }

  if (
    Number.isFinite(declaredSize) &&
    wouldExceedStorageCap(scope.account, declaredSize - replacedRawBytes)
  ) {
    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

  const uploadId = crypto.randomUUID();

  const newStorageKey =
    `events/${photo.eventId}/photos/${photoId}` + `/raw/${uploadId}.raw`;

  let storedObject: R2Object;

  try {
    storedObject = await env.pickpic_photos.put(newStorageKey, request.body, {
      httpMetadata: {
        contentType: RAW_CONTENT_TYPE,
      },
      customMetadata: {
        eventId: photo.eventId,
        photoId,
        originalFilename,
        variant: "raw",
        sourceSha256: rawSha256,
      },
    });
  } catch {
    return jsonResponse({ error: "The RAW file could not be stored." }, 500);
  }

  if (storedObject.size > MAX_RAW_BYTES) {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse({ error: RAW_TOO_LARGE_MESSAGE }, 413);
  }

  await refreshAccountStorageBytes(scope);

  if (
    wouldExceedStorageCap(scope.account, storedObject.size - replacedRawBytes)
  ) {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

  const uploadedAt = new Date().toISOString();

  try {
    await scope.database.batch([
      scope.database
        .prepare(
          `
          UPDATE photos
          SET
            raw_storage_key = ?,
            raw_original_filename = ?,
            raw_content_type = ?,
            raw_byte_size = ?,
            raw_uploaded_at = ?,
            raw_sha256 = ?
          WHERE id = ?
        `,
        )
        .bind(
          newStorageKey,
          originalFilename,
          RAW_CONTENT_TYPE,
          storedObject.size,
          uploadedAt,
          rawSha256,
          photoId,
        ),

      scope.database
        .prepare(
          `
          UPDATE raw_requests
          SET fulfilled_at = ?
          WHERE
            photo_id = ?
            AND fulfilled_at IS NULL
        `,
        )
        .bind(uploadedAt, photoId),
    ]);
  } catch {
    await env.pickpic_photos.delete(newStorageKey);

    return jsonResponse(
      { error: "The RAW file metadata could not be saved." },
      500,
    );
  }

  /*
   * Tell everyone who was waiting that their file has landed (#224).
   *
   * Read after the batch rather than folded into it, so the blanket UPDATE
   * above stays the single thing that decides what counts as fulfilled -- a
   * request that arrived while this upload was in flight is picked up by that
   * statement and then simply appears in this list. Each recipient's token is
   * minted inside sendRawReadyEmail, one per request, because only the hash is
   * ever stored and the plaintext has to exist where the mail is composed.
   */
  try {
    const recipients = await scope.database
      .prepare(
        `
        SELECT visitor_id AS visitorId
        FROM raw_requests
        WHERE
          photo_id = ?
          AND email IS NOT NULL
          AND fulfilled_at = ?
      `,
      )
      .bind(photoId, uploadedAt)
      .all<{ visitorId: string }>();

    for (const recipient of recipients.results) {
      scheduleRawReadyEmail(
        request,
        env as Env,
        ctx,
        photoId,
        recipient.visitorId,
      );
    }
  } catch (error) {
    /*
     * Logged, never fatal, and emphatically not a reason to delete the object.
     * The RAW is stored and the requests are stamped fulfilled by the point
     * this runs -- every viewer can still collect it from the gallery. Failing
     * the upload here would make the iPad re-send ~120 MB to fix a notification.
     */
    console.error("Unable to queue RAW delivery emails:", error);
  }

  await adjustAccountStorageBytes(scope, storedObject.size - replacedRawBytes);

  if (photo.rawStorageKey !== null && photo.rawStorageKey !== newStorageKey) {
    try {
      await env.pickpic_photos.delete(photo.rawStorageKey);
    } catch (error) {
      console.error("Unable to remove the replaced RAW file:", error);
    }
  }

  const rawPhoto: RawPhotoRecord = {
    originalFilename,
    contentType: RAW_CONTENT_TYPE,
    byteSize: storedObject.size,
    uploadedAt,
  };

  return jsonResponse({
    photoId,
    pendingRawRequestCount: 0,
    rawPhoto,
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
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
  sourceKind: PhotoVariantSource,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT
        event_id AS eventId,
        final_storage_key AS finalStorageKey
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
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

  const oldVariants = await scope.database
    .prepare(
      `
      SELECT
        storage_key AS storageKey,
        byte_size AS byteSize
      FROM photo_variants
      WHERE
        photo_id = ?
        AND source_kind = ?
    `,
    )
    .bind(photoId, sourceKind)
    .all<StoredVariantRow>();

  // Both files are already fully read into memory (multipart form data), so
  // .size is exact -- no Content-Length approximation needed here.
  const replacedVariantBytes = oldVariants.results.reduce(
    (sum, variant) => sum + variant.byteSize,
    0,
  );

  await refreshAccountStorageBytes(scope);

  if (
    wouldExceedStorageCap(
      scope.account,
      thumbnail.size + preview.size - replacedVariantBytes,
    )
  ) {
    return jsonResponse(
      { error: "This account's storage limit has been reached." },
      403,
    );
  }

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
    await scope.database.batch([
      scope.database
        .prepare(
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
        )
        .bind(
          photoId,
          sourceKind,
          thumbnailStorageKey,
          thumbnailObject.size,
          thumbnailWidth,
          thumbnailHeight,
          createdAt,
        ),

      scope.database
        .prepare(
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
        )
        .bind(
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

  await adjustAccountStorageBytes(
    scope,
    thumbnailObject.size + previewObject.size - replacedVariantBytes,
  );

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
        `${ADMIN_PHOTO_IMAGE_BASE}/${encodeURIComponent(
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
        `${ADMIN_PHOTO_IMAGE_BASE}/${encodeURIComponent(
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

async function getVariantStorageKey(
  database: D1Database,
  photoId: string,
  sourceKind: PhotoVariantSource,
  variantKind: PhotoVariantKind,
): Promise<string | null> {
  const variant = await database
    .prepare(
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

  return variant?.storageKey ?? null;
}

async function getAdminPhotoVariantImage(
  env: TenantEnv,
  scope: AccountScope,
  photoId: string,
  sourceKind: PhotoVariantSource,
  variantKind: PhotoVariantKind,
): Promise<Response> {
  const photo = await scope
    .prepare(
      `
      SELECT id
      FROM photos
      WHERE
        id = ?
        AND account_id = :accountId
    `,
      photoId,
    )
    .first<{ id: string }>();

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const storageKey = await getVariantStorageKey(
    scope.database,
    photoId,
    sourceKind,
    variantKind,
  );

  if (!storageKey) {
    return jsonResponse(
      { error: "The requested image variant was not found." },
      404,
    );
  }

  return getStoredJpeg(env, storageKey);
}

async function getGalleryPhotoVariantImage(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  shareToken: string,
  photoId: string,
  sourceKind: PhotoVariantSource,
  variantKind: PhotoVariantKind,
): Promise<Response> {
  const photo = await findPhotoInShare(env, shareToken, photoId);

  if (!photo) {
    return jsonResponse({ error: "Photo not found." }, 404);
  }

  const storageKey = await getVariantStorageKey(
    env.DB,
    photoId,
    sourceKind,
    variantKind,
  );

  if (!storageKey) {
    return jsonResponse(
      { error: "The requested image variant was not found." },
      404,
    );
  }

  /*
   * Cached only below the status gate above -- see getCachedStoredJpeg. The
   * variant's own storage key already distinguishes original from final and
   * thumbnail from preview, so no part of the key has to be spelled out again
   * here.
   */
  return getCachedStoredJpeg(request, env, ctx, storageKey);
}

/*
 * Every /api/admin/* route, hoisted out of fetch so that `scope` can be a
 * non-nullable parameter rather than something each of the seventeen route
 * blocks has to re-check.
 *
 * Returning null means no admin route matched, which lets fetch fall through to
 * the same generic /api/ 404 it used before. Admin paths and public paths are
 * disjoint prefixes (/api/admin/ against /api/photos/ and /api/galleries/), so
 * evaluating this group first cannot shadow a public route.
 */
async function handleAdminRequest(
  request: Request,
  url: URL,
  env: TenantEnv,
  ctx: ExecutionContext,
  scope: AccountScope,
  principal: AdminPrincipal,
): Promise<Response | null> {
  if (url.pathname === "/api/admin/events") {
    if (request.method === "POST") {
      return createEvent(request, scope);
    }

    if (request.method === "GET") {
      return listEvents(scope);
    }

    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  if (url.pathname === "/api/admin/storage") {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return getStorageUsage(scope);
  }

  if (url.pathname === "/api/admin/account") {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return updateAccount(request, scope);
  }

  const adminEventMatch = url.pathname.match(/^\/api\/admin\/events\/([^/]+)$/);

  if (adminEventMatch) {
    const eventId = safeDecodePathSegment(adminEventMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    if (request.method === "PUT") {
      return updateEvent(request, scope, eventId);
    }

    if (request.method === "DELETE") {
      return requireOwnerRole(principal) ?? deleteEvent(env, scope, eventId);
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

    const eventId = safeDecodePathSegment(adminEventStatusMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return setEventStatus(request, scope, eventId);
  }

  const adminEventRawRequestsMatch = url.pathname.match(
    /^\/api\/admin\/events\/([^/]+)\/raw-requests$/,
  );

  if (adminEventRawRequestsMatch) {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const eventId = safeDecodePathSegment(adminEventRawRequestsMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return setEventRawRequestsEnabled(request, scope, eventId);
  }

  const adminEventRawReleasesMatch = url.pathname.match(
    /^\/api\/admin\/events\/([^/]+)\/raw-releases$/,
  );

  if (adminEventRawReleasesMatch) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const eventId = safeDecodePathSegment(adminEventRawReleasesMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return releaseCollectedRawPhotos(env, scope, eventId);
  }

  const adminEventStopOfferingRawsMatch = url.pathname.match(
    /^\/api\/admin\/events\/([^/]+)\/raw-requests\/stop$/,
  );

  if (adminEventStopOfferingRawsMatch) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const eventId = safeDecodePathSegment(adminEventStopOfferingRawsMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return stopOfferingRawRequests(env, scope, eventId);
  }

  const eventPhotosPreflightMatch = url.pathname.match(
    /^\/api\/admin\/events\/([^/]+)\/photos\/preflight$/,
  );

  if (eventPhotosPreflightMatch) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const eventId = safeDecodePathSegment(eventPhotosPreflightMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return preflightPhotos(request, scope, eventId);
  }

  const eventPhotosMatch = url.pathname.match(
    /^\/api\/admin\/events\/([^/]+)\/photos$/,
  );

  if (eventPhotosMatch) {
    const eventId = safeDecodePathSegment(eventPhotosMatch[1]);

    if (eventId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    if (request.method === "POST") {
      return createPhoto(request, env, scope, eventId, ctx);
    }

    if (request.method === "GET") {
      return listPhotos(env, ctx, scope, eventId);
    }

    if (request.method === "DELETE") {
      return (
        requireOwnerRole(principal) ?? clearEventPhotos(env, scope, eventId)
      );
    }

    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  const photoFinalMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/final$/,
  );

  if (photoFinalMatch) {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoFinalMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return uploadFinalPhoto(request, env, scope, photoId);
  }

  const photoRawMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/raw$/,
  );

  if (photoRawMatch) {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoRawMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return uploadRawPhoto(request, env, ctx, scope, photoId);
  }

  const adminPhotoImageMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/image$/,
  );

  if (adminPhotoImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(adminPhotoImageMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getAdminPhotoImage(env, scope, photoId);
  }

  const adminPhotoFinalImageMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/final-image$/,
  );

  if (adminPhotoFinalImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(adminPhotoFinalImageMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getAdminFinalPhotoImage(env, scope, photoId);
  }

  const adminPhotoVariantImageMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/variants\/(original|final)\/(thumbnail|preview)$/,
  );

  if (adminPhotoVariantImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(adminPhotoVariantImageMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getAdminPhotoVariantImage(
      env,
      scope,
      photoId,
      adminPhotoVariantImageMatch[2] as PhotoVariantSource,
      adminPhotoVariantImageMatch[3] as PhotoVariantKind,
    );
  }

  const photoMatch = url.pathname.match(/^\/api\/admin\/photos\/([^/]+)$/);

  if (photoMatch) {
    if (request.method !== "DELETE") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return deletePhoto(env, scope, photoId);
  }

  const photoHeartsMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/hearts$/,
  );

  if (photoHeartsMatch) {
    if (request.method !== "DELETE") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoHeartsMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return requireOwnerRole(principal) ?? clearPhotoHearts(scope, photoId);
  }

  const photoRawRequestsMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/raw-requests$/,
  );

  if (photoRawRequestsMatch) {
    if (request.method !== "DELETE") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoRawRequestsMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return (
      requireOwnerRole(principal) ??
      cancelUndeliveredRawRequests(env, scope, photoId)
    );
  }

  const photoWorkflowMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/workflow$/,
  );

  if (photoWorkflowMatch) {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(photoWorkflowMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return setPhotoWorkflowStatus(request, scope, photoId);
  }

  const adminVariantUploadMatch = url.pathname.match(
    /^\/api\/admin\/photos\/([^/]+)\/variants\/(original|final)$/,
  );

  if (adminVariantUploadMatch) {
    if (request.method !== "PUT") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const photoId = safeDecodePathSegment(adminVariantUploadMatch[1]);

    if (photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return uploadPhotoVariants(
      request,
      env,
      scope,
      photoId,
      adminVariantUploadMatch[2] as PhotoVariantSource,
    );
  }

  return null;
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      return await routeRequest(request, env, ctx);
    } catch (error) {
      console.error("Unhandled error while routing request:", error);
      return jsonResponse({ error: "Internal server error." }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function routeRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);

  /*
   * Unauthenticated and independent of AUTH_MODE: Apple's CDN fetches this
   * from whichever origin the universal link names, before any app is
   * involved, so it cannot be gated behind a session or Access check.
   */
  if (url.pathname === "/.well-known/apple-app-site-association") {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const association = buildAppleAppSiteAssociation(
      env as Env & AppleEnvironment,
    );

    if (!association) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return jsonResponse(association);
  }

  /*
   * Ahead of the admin block because these are the routes that mint the
   * credential the admin block checks, so they cannot themselves require one.
   */
  const authResponse = await handleAuthRequest(
    request,
    url,
    env.DB,
    env as Env & AuthEnvironment,
  );

  if (authResponse) {
    return authResponse;
  }

  /*
   * Ahead of the /api/admin/* block, and it never reaches createAccountScope.
   *
   * An operator handler is typed against Env rather than AccountScope, so the
   * cross-account split is enforced by the type system instead of by review --
   * see the header comment in worker/operator.ts for why the alternative
   * (teaching createAccountScope to skip :accountId for an operator) would have
   * disarmed tenancy everywhere.
   *
   * requireAdminPrincipal is reused for the authentication half because it is
   * the only thing that knows how to resolve an identity under either
   * AUTH_MODE. That also gives /api/operator/* the same Origin requirement on
   * state-changing requests that /api/admin/* has. Nothing here is
   * state-changing today -- requireOperatorPrincipal refuses every non-GET --
   * but having the check already in place is what makes the first operator
   * action safe by default rather than by remembering.
   */
  if (url.pathname.startsWith("/api/operator/")) {
    const access = await requireAdminPrincipal(
      request,
      env.DB,
      env as Env & AuthEnvironment,
      ctx,
    );

    if (!access.ok) {
      return access.response;
    }

    const denied = await requireOperatorPrincipal(
      request,
      env.DB,
      access.principal,
    );

    if (denied) {
      return denied;
    }

    const operatorResponse = await handleOperatorRequest(request, url, env);

    if (operatorResponse) {
      return operatorResponse;
    }
  }

  if (url.pathname.startsWith("/api/admin/")) {
    const access = await requireAdminPrincipal(
      request,
      env.DB,
      env as Env & AuthEnvironment,
      ctx,
    );

    if (!access.ok) {
      return access.response;
    }

    const account = await resolveAccountForPrincipal(env.DB, access.principal);

    if (!account || account.status !== "active") {
      return jsonResponse({ error: "This account is not available." }, 403);
    }

    const adminResponse = await handleAdminRequest(
      request,
      url,
      env,
      ctx,
      createAccountScope(account, resolveAccountDatabase(env, account)),
      access.principal,
    );

    if (adminResponse) {
      return adminResponse;
    }
  }

  const galleryPhotoImageMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/image$/,
  );

  if (galleryPhotoImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(galleryPhotoImageMatch[1]);
    const photoId = safeDecodePathSegment(galleryPhotoImageMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getGalleryPhotoImage(request, env, ctx, shareToken, photoId);
  }

  const galleryPhotoFinalImageMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/final-image$/,
  );

  if (galleryPhotoFinalImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(galleryPhotoFinalImageMatch[1]);
    const photoId = safeDecodePathSegment(galleryPhotoFinalImageMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getGalleryFinalPhotoImage(request, env, ctx, shareToken, photoId);
  }

  const galleryPhotoVariantImageMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/variants\/(original|final)\/(thumbnail|preview)$/,
  );

  if (galleryPhotoVariantImageMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(galleryPhotoVariantImageMatch[1]);
    const photoId = safeDecodePathSegment(galleryPhotoVariantImageMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getGalleryPhotoVariantImage(
      request,
      env,
      ctx,
      shareToken,
      photoId,
      galleryPhotoVariantImageMatch[3] as PhotoVariantSource,
      galleryPhotoVariantImageMatch[4] as PhotoVariantKind,
    );
  }

  /*
   * This guard must stay ahead of every route its regex covers. The chain is
   * ordered and each block returns, so a matching route declared above here
   * simply never reaches the check -- which is how hearts silently escaped it
   * and kept accepting edit requests on a `completed` gallery the UI had
   * already told the viewer was closed.
   *
   * DELETE on raw-request is exempted (#326): withdrawing isn't a new
   * request, it's the only lever a viewer has to release an already-delivered
   * RAW early, and blocking it just pins the object in R2 for the full TTL.
   * findPhotoInShare inside removeRawRequest already scopes to a
   * ready/completed gallery, so the 404 case stays covered without this
   * guard.
   */
  const galleryMutationMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/[^/]+\/(?:heart|raw-request|comments(?:\/[^/]+)?)$/,
  );
  const isRawRequestWithdrawal =
    request.method === "DELETE" && /\/raw-request$/.test(url.pathname);

  if (
    galleryMutationMatch &&
    request.method !== "GET" &&
    !isRawRequestWithdrawal
  ) {
    const shareToken = safeDecodePathSegment(galleryMutationMatch[1]);

    if (shareToken === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    const galleryGuard = await requireOpenGallery(env, shareToken);

    if (galleryGuard) {
      return galleryGuard;
    }
  }

  const galleryHeartMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/heart$/,
  );

  if (galleryHeartMatch) {
    const shareToken = safeDecodePathSegment(galleryHeartMatch[1]);
    const photoId = safeDecodePathSegment(galleryHeartMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    if (request.method === "PUT") {
      return addHeart(request, env, shareToken, photoId);
    }

    if (request.method === "DELETE") {
      return removeHeart(request, env, shareToken, photoId);
    }

    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  const galleryRawRequestMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/raw-request$/,
  );

  if (galleryRawRequestMatch) {
    const shareToken = safeDecodePathSegment(galleryRawRequestMatch[1]);
    const photoId = safeDecodePathSegment(galleryRawRequestMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    if (request.method === "PUT") {
      return addRawRequest(request, env, ctx, shareToken, photoId);
    }

    if (request.method === "DELETE") {
      return removeRawRequest(request, env, shareToken, photoId);
    }

    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  /*
   * Sits beside the request route rather than up with the image routes,
   * because it is the other half of the same feature and shares its scoping:
   * both narrow through findPhotoInShare and then match the visitor token
   * against gallery_visitors/raw_requests. It is a GET, so the
   * requireOpenGallery guard above does not apply to it -- deliberately. A
   * `completed` gallery stops taking new requests while its existing
   * downloads stay collectable, which is what the gallery banner already
   * promises viewers.
   */
  const galleryRawDownloadMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/raw$/,
  );

  if (galleryRawDownloadMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(galleryRawDownloadMatch[1]);
    const photoId = safeDecodePathSegment(galleryRawDownloadMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getGalleryRawPhoto(request, env, ctx, url, shareToken, photoId);
  }

  /*
   * Redeems the confirmation link from a RAW request email (#224). A POST from
   * the SPA page at /g/:shareToken/raw-confirm, not a GET on the mailed link
   * itself -- see confirmRawRequest for why (#323).
   *
   * Outside the requireOpenGallery guard for the same reason the download
   * route is: the viewer asked while the gallery was open, and the
   * photographer marking it `completed` in the meantime must not strand a
   * request that is already half-made. findPhotoInShare inside the handler is
   * what takes it away if the gallery is genuinely gone.
   */
  const galleryRawConfirmMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/raw-confirm$/,
  );

  if (galleryRawConfirmMatch) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(galleryRawConfirmMatch[1]);

    if (shareToken === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return confirmRawRequest(request, env, ctx, shareToken);
  }

  const galleryCommentMatch = url.pathname.match(
    /^\/api\/galleries\/([^/]+)\/photos\/([^/]+)\/comments\/([^/]+)$/,
  );

  if (galleryCommentMatch) {
    const shareToken = safeDecodePathSegment(galleryCommentMatch[1]);
    const photoId = safeDecodePathSegment(galleryCommentMatch[2]);
    const commentId = safeDecodePathSegment(galleryCommentMatch[3]);

    if (shareToken === null || photoId === null || commentId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

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

    const shareToken = safeDecodePathSegment(galleryCommentsMatch[1]);
    const photoId = safeDecodePathSegment(galleryCommentsMatch[2]);

    if (shareToken === null || photoId === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return addComment(request, env, shareToken, photoId);
  }

  const publicGalleryMatch = url.pathname.match(/^\/api\/galleries\/([^/]+)$/);

  if (publicGalleryMatch) {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const shareToken = safeDecodePathSegment(publicGalleryMatch[1]);

    if (shareToken === null) {
      return jsonResponse({ error: "Not found." }, 404);
    }

    return getPublicGallery(request, env, shareToken);
  }

  if (url.pathname.startsWith("/api/")) {
    return jsonResponse({ error: "API route not found." }, 404);
  }

  return new Response(null, { status: 404 });
}
