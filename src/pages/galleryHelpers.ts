import type { GalleryPhotoRecord } from "../types";
import type { GalleryPhotoGroup } from "../components/gallery/types";

/*
 * Pure formatting/derivation helpers pulled out of GalleryPage.tsx so they
 * can be unit tested without rendering the component tree. Keep anything
 * that touches the DOM (localStorage, window.prompt, fetch) in the
 * component itself.
 */

export type GalleryGrouping = "all" | "day" | "location";

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

export function getDefaultPreviewUrl(photo: GalleryPhotoRecord): string {
  if (photo.finalPhoto) {
    return (
      photo.finalPhoto.variants.preview?.imageUrl ?? photo.finalPhoto.imageUrl
    );
  }

  return photo.variants.preview?.imageUrl ?? photo.imageUrl;
}
