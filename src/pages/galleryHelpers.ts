import type { GalleryPhotoRecord } from "../types";
import type { GalleryPhotoGroup } from "../components/gallery/types";

/*
 * Pure formatting/derivation helpers pulled out of GalleryPage.tsx so they
 * can be unit tested without rendering the component tree. Keep anything
 * that touches the DOM (localStorage, window.prompt, fetch) in the
 * component itself.
 */

export type GalleryGrouping = "all" | "day" | "location";

export const VISITOR_TOKEN_KEY = "pickpic-visitor-token";

/*
 * Shared between GalleryPage (writer) and RawConfirmPage (reader), which is
 * why it lives here rather than in either page -- it is the only channel
 * between the two for finishing a batch request after the anchor photo's
 * confirmation link is clicked (#271). See PendingRawBatch below.
 */
export const PENDING_RAW_BATCH_KEY = "pickpic-raw-batch-pending";

/*
 * Safari's "Block All Cookies" setting throws a SecurityError on merely
 * *accessing* window.localStorage, not just on getItem/setItem — so the
 * access itself has to happen inside the try, which is why these take a
 * lazy `getStorage` accessor rather than a Storage instance directly.
 */
type StorageLike = Pick<Storage, "getItem" | "setItem">;

export function readStorageItem(
  getStorage: () => Pick<Storage, "getItem">,
  key: string,
): string | null {
  try {
    return getStorage().getItem(key);
  } catch {
    return null;
  }
}

export function writeStorageItem(
  getStorage: () => Pick<Storage, "setItem">,
  key: string,
  value: string,
): void {
  try {
    getStorage().setItem(key, value);
  } catch {
    // Storage may be blocked; the value just won't survive a reload.
  }
}

export function removeStorageItem(
  getStorage: () => Pick<Storage, "removeItem">,
  key: string,
): void {
  try {
    getStorage().removeItem(key);
  } catch {
    // Storage may be blocked; there is nothing to clean up in that case.
  }
}

export function getOrCreateVisitorToken(
  getStorage: () => StorageLike,
  key: string,
  generateToken: () => string,
): string {
  const storedToken = readStorageItem(getStorage, key);

  if (storedToken) {
    return storedToken;
  }

  const token = generateToken();

  writeStorageItem(getStorage, key, token);

  return token;
}

export function sanitizeDownloadFilename(filename: string): string {
  const sanitized = Array.from(filename)
    .filter((character) => {
      const characterCode = character.charCodeAt(0);

      return characterCode > 0x1f && characterCode !== 0x7f;
    })
    .join("")
    .replace(/[\\/:*?"<>|]/g, "-")
    .replace(/[. ]+$/g, "")
    .trim();

  return sanitized || "photo.jpg";
}

export function createUniqueDownloadNames(filenames: string[]): string[] {
  const usedNames = new Set<string>();

  return filenames.map((filename) => {
    const sanitized = sanitizeDownloadFilename(filename);
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

export function formatApproximateByteSize(byteSize: number): string {
  if (byteSize < 1_000_000) {
    return `${Math.max(1, Math.round(byteSize / 1_000))} KB`;
  }
  if (byteSize < 1_000_000_000) {
    return `${new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 1,
    }).format(byteSize / 1_000_000)} MB`;
  }

  return `${new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 2,
  }).format(byteSize / 1_000_000_000)} GB`;
}

/*
 * The RAW request button's five states, derived in one place because three
 * call sites need them to agree: GalleryPage picks the HTTP method from this,
 * and GalleryGrid and GalleryLightbox each render their own button from it.
 *
 * "collected" is the state that only exists because the RAW gets reclaimed
 * after download (#209). Without it, a viewer whose file has been deleted
 * again shows as "requested" -- indistinguishable from someone still waiting
 * for a RAW that is on its way.
 *
 * "confirming" is the address-proving step (#224): asked for, but no request
 * exists yet on the server and none will until the emailed link is clicked.
 */
export type RawRequestState =
  "none" | "confirming" | "waiting" | "ready" | "collected";

export function getRawRequestState(
  photo: Pick<
    GalleryPhotoRecord,
    | "viewerRequestedRaw"
    | "viewerRawDownload"
    | "viewerRawDownloadedAt"
    | "viewerRawConfirmationPending"
  >,
): RawRequestState {
  /*
   * Checked before viewerRequestedRaw, because a download that is still
   * collectable outranks everything else the viewer could do with the button
   * -- including during the grace window after they have already taken it
   * once, when both this and viewerRawDownloadedAt are set.
   */
  if (photo.viewerRawDownload !== null) {
    return "ready";
  }

  if (photo.viewerRequestedRaw) {
    return photo.viewerRawDownloadedAt === null ? "waiting" : "collected";
  }

  /*
   * Ranked below every real request state and not above "none", because a
   * pending confirmation can outlive the request it was for: asking again after
   * the RAW was reclaimed writes a real row while a stale pending row may still
   * sit there unexpired. Whatever actually exists on the server wins.
   */
  return photo.viewerRawConfirmationPending ? "confirming" : "none";
}

/*
 * The multi-select "Request originals" action (#271) only ever asks for
 * photos with nothing outstanding yet -- state "none" is the same "would
 * invite a brand new ask" rule getRawRequestState's own comment describes for
 * the single-photo button, and rawRequestsEnabled gates a *new* ask the same
 * way there too. Anything already confirming, waiting, ready or collected is
 * excluded rather than made unselectable, so a viewer selecting a mixed batch
 * sees an accurate "N can be requested" instead of losing photos from their
 * selection outright.
 */
export function selectRequestableRawPhotos(
  photos: GalleryPhotoRecord[],
  rawRequestsEnabled: boolean,
): GalleryPhotoRecord[] {
  if (!rawRequestsEnabled) {
    return [];
  }

  return photos.filter((photo) => getRawRequestState(photo) === "none");
}

/*
 * Backs the "Your originals" collection panel (#271): every RAW this viewer
 * can currently download, gathered in one place instead of requiring a scroll
 * through the whole gallery to find each one's inline button. "ready" already
 * means viewerRawDownload is non-null (see getRawRequestState), so nothing
 * further needs deriving here.
 */
export function selectReadyRawPhotos(
  photos: GalleryPhotoRecord[],
): GalleryPhotoRecord[] {
  return photos.filter((photo) => getRawRequestState(photo) === "ready");
}

/*
 * What a batch request that had to wait on confirmation leaves behind so
 * RawConfirmPage can finish the rest of the batch once the anchor photo's
 * link is confirmed (#271) -- see addRawRequestsBatch's comment on why only
 * the anchor gets a real confirmation row. Kept as plain JSON in localStorage
 * rather than anything richer since it only has to survive a same-device trip
 * to the Mail app and back; a different device simply never finds it, which
 * is the documented, acceptable degradation.
 */
export interface PendingRawBatch {
  shareToken: string;
  photoIds: string[];
  displayName: string;
  email: string;
}

export function encodePendingRawBatch(batch: PendingRawBatch): string {
  return JSON.stringify(batch);
}

/*
 * Returns null on anything that doesn't look like a batch pending for this
 * exact gallery -- malformed JSON, a stale shape, or (most commonly) a batch
 * left over from a different share token -- rather than throwing, since a
 * miss here should fall back to RawConfirmPage's ordinary single-photo
 * behaviour instead of breaking the confirmation the viewer actually came to
 * finish.
 */
export function parsePendingRawBatch(
  raw: string | null,
  shareToken: string,
): PendingRawBatch | null {
  if (raw === null) {
    return null;
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }

  if (typeof parsed !== "object" || parsed === null) {
    return null;
  }

  const candidate = parsed as Partial<PendingRawBatch>;

  if (
    candidate.shareToken !== shareToken ||
    typeof candidate.displayName !== "string" ||
    typeof candidate.email !== "string" ||
    !Array.isArray(candidate.photoIds) ||
    candidate.photoIds.length === 0 ||
    !candidate.photoIds.every((id) => typeof id === "string")
  ) {
    return null;
  }

  return {
    shareToken: candidate.shareToken,
    photoIds: candidate.photoIds,
    displayName: candidate.displayName,
    email: candidate.email,
  };
}

export function createArchiveFilename(title: string): string {
  const sanitizedTitle = title
    .replace(/[^a-z0-9]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80)
    .toLowerCase();
  return `${sanitizedTitle || "pickpic-gallery"}-photos.zip`;
}

export function formatDayGroupLabel(dayKey: string): string {
  if (dayKey === "unknown") {
    return "Date unavailable";
  }
  const [year, month, day] = dayKey.split("-").map(Number);

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "full",
  }).format(new Date(year, month - 1, day));
}

export function comparePhotos(
  first: GalleryPhotoRecord,
  second: GalleryPhotoRecord,
): number {
  if (first.capturedAt && second.capturedAt) {
    const captureDateComparison = first.capturedAt.localeCompare(
      second.capturedAt,
    );
    if (captureDateComparison !== 0) {
      return captureDateComparison;
    }
  } else if (first.capturedAt) {
    // Photos with capture metadata come before those without it.
    return -1;
  } else if (second.capturedAt) {
    return 1;
  }

  const filenameComparison = first.originalFilename.localeCompare(
    second.originalFilename,
    undefined,
    {
      numeric: true,
      sensitivity: "base",
    },
  );

  if (filenameComparison !== 0) {
    return filenameComparison;
  }
  // Final fallback if filenames are identical.
  return first.createdAt.localeCompare(second.createdAt);
}

export function buildGalleryGroups(
  photos: GalleryPhotoRecord[],
  grouping: GalleryGrouping,
): GalleryPhotoGroup[] {
  const sortedPhotos = [...photos].sort(comparePhotos);

  if (grouping === "all") {
    return [
      {
        key: "all",
        label: "All photos",
        photos: sortedPhotos,
        mapUrl: null,
      },
    ];
  }

  const groups = new Map<string, GalleryPhotoRecord[]>();
  for (const photo of sortedPhotos) {
    let key: string;

    if (grouping === "day") {
      key = photo.capturedAt?.slice(0, 10) ?? "unknown";
    } else if (photo.latitude !== null && photo.longitude !== null) {
      /*
       * Public coordinates are already rounded by the
       * Worker, creating approximate nearby-area groups.
       */
      key = `${photo.latitude.toFixed(2)},` + photo.longitude.toFixed(2);
    } else {
      key = "unknown";
    }
    const groupPhotos = groups.get(key) ?? [];

    groupPhotos.push(photo);
    groups.set(key, groupPhotos);
  }

  const results = Array.from(groups.entries(), ([key, groupPhotos]) => {
    if (grouping === "day") {
      return {
        key,
        label: formatDayGroupLabel(key),
        photos: groupPhotos,
        mapUrl: null,
      };
    }
    if (key === "unknown") {
      return {
        key,
        label: "Location unavailable",
        photos: groupPhotos,
        mapUrl: null,
      };
    }

    const [latitudeText, longitudeText] = key.split(",");

    return {
      key,
      label: `Near ${latitudeText}, ` + longitudeText,
      photos: groupPhotos,
      mapUrl: "https://www.google.com/maps?q=" + encodeURIComponent(key),
    };
  });
  return results.sort((first, second) => {
    if (first.key === "unknown") {
      return 1;
    }

    if (second.key === "unknown") {
      return -1;
    }

    return first.key.localeCompare(second.key);
  });
}

/*
 * Selection must resolve against the gallery's full photo list, not
 * whatever the current filter happens to show — narrowing the filter
 * after selecting must never silently drop photos from a download.
 * Ids for photos no longer in the gallery (e.g. deleted) are dropped.
 */
export function selectPhotosById(
  photos: GalleryPhotoRecord[],
  selectedIds: Set<string>,
): GalleryPhotoRecord[] {
  return photos.filter((photo) => selectedIds.has(photo.id));
}

/*
 * A single dropped fetch used to discard the whole archive rather than
 * zipping what succeeded (#288) -- on a large selection over cellular, the
 * odds of every fetch succeeding aren't good, and a name here is more useful
 * than making the viewer guess which photo was skipped.
 */
export function formatZipDownloadNotice(
  baseNotice: string,
  failedFilenames: string[],
): string {
  if (failedFilenames.length === 0) {
    return baseNotice;
  }

  const noun = failedFilenames.length === 1 ? "photo" : "photos";

  return `${baseNotice} ${failedFilenames.length} ${noun} could not be included: ${failedFilenames.join(", ")}.`;
}

/*
 * Vendor tokens embedders stamp into the user agent. Lowercased, and matched
 * as substrings, because the surrounding syntax varies between apps and
 * versions. This list is allowed to be incomplete -- see
 * isLikelyInAppBrowser below for why being wrong is survivable.
 */
const IN_APP_BROWSER_UA_TOKENS = [
  "fban", // Facebook iOS
  "fbav", // Facebook Android
  "fb_iab", // Facebook in-app browser
  "instagram",
  "line/",
  "micromessenger", // WeChat
  "whatsapp",
  "snapchat",
  "twitter",
  "linkedinapp",
  "pinterest",
  "tiktok",
  "musical_ly", // older TikTok builds
  "gsa/", // Google app
];

/*
 * In-app browsers -- the webviews chat apps open links in -- commonly swallow
 * a programmatic download of a blob: URL with no exception, no rejected
 * promise and nothing a catch block can see (#218). Share links normally
 * arrive through a chat app, so for this gallery that is the ordinary case
 * rather than an edge one.
 *
 * Three signals, because no single one covers the field:
 *
 * 1. A vendor token (above). Cheap and exact wherever the embedder stamps one.
 * 2. Android's `; wv` marker, which the system WebView adds and Chrome does
 *    not.
 * 3. An iOS WebKit UA carrying `Mobile/` but *no* `Safari/` token. #242 calls
 *    out Telegram's iOS browser as the case that defeats UA sniffing, and it
 *    does defeat (1) -- it stamps nothing. But it also leaves WKWebView's
 *    default UA untouched, and that default has no `Safari/` token, while real
 *    Mobile Safari always has one and every third-party iOS browser (CriOS,
 *    FxiOS, EdgiOS) keeps it and adds its own. So the *absence* is the signal
 *    the presence of a vendor token isn't.
 *
 * This stays a heuristic and it is allowed to be wrong in both directions,
 * which is exactly why nothing here blocks or gates a download. A false
 * positive costs the viewer a per-photo save list instead of a ZIP; a false
 * negative leaves them where they already were, with that same list one tap
 * away behind the download notice.
 */
export function isLikelyInAppBrowser(userAgent: string): boolean {
  const normalized = userAgent.toLowerCase();

  if (normalized === "") {
    return false;
  }

  if (IN_APP_BROWSER_UA_TOKENS.some((token) => normalized.includes(token))) {
    return true;
  }

  if (normalized.includes("android") && /;\s*wv\b/.test(normalized)) {
    return true;
  }

  const isIosWebKit =
    /iphone|ipad|ipod/.test(normalized) && normalized.includes("applewebkit");

  return (
    isIosWebKit &&
    normalized.includes("mobile/") &&
    !normalized.includes("safari/")
  );
}

export interface IndividualSaveEntry {
  photoId: string;
  filename: string;
  imageUrl: string;
}

/*
 * The per-photo fallback and the ZIP have to name and address exactly the same
 * files, so both read from here rather than each picking `finalPhoto ?? photo`
 * for themselves. These URLs need no visitor header (the ZIP already fetches
 * them bare), which is the whole reason the fallback can be a plain anchor a
 * webview will honour where it silently drops a blob:.
 */
export function createIndividualSaveEntries(
  photos: GalleryPhotoRecord[],
): IndividualSaveEntry[] {
  const filenames = createUniqueDownloadNames(
    photos.map(
      (photo) => photo.finalPhoto?.originalFilename ?? photo.originalFilename,
    ),
  );

  return photos.map((photo, index) => ({
    photoId: photo.id,
    filename: filenames[index],
    imageUrl: photo.finalPhoto?.imageUrl ?? photo.imageUrl,
  }));
}

export function getDefaultPreviewUrl(photo: GalleryPhotoRecord): string {
  if (photo.finalPhoto) {
    return (
      photo.finalPhoto.variants.preview?.imageUrl ?? photo.finalPhoto.imageUrl
    );
  }

  return photo.variants.preview?.imageUrl ?? photo.imageUrl;
}
