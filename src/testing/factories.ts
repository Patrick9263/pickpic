import type {
  EventRecord,
  GalleryPhotoRecord,
  PhotoRecord,
  StorageUsageRecord,
} from "../types";

/*
 * Typed against src/types.ts (Partial<T> overrides, not a builder API) so a
 * field added to a record type breaks the factory at compile time instead
 * of the factory silently defaulting it to `undefined`.
 */

export function makeEvent(overrides: Partial<EventRecord> = {}): EventRecord {
  return {
    id: "event-1",
    title: "Test Event",
    shareToken: "share-token",
    status: "draft",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    rawRequestsEnabled: false,
    ...overrides,
  };
}

function makeBasePhotoFields(): Omit<PhotoRecord, "comments"> {
  return {
    id: "photo-1",
    eventId: "event-1",
    originalFilename: "DSC01015.ARW",
    contentType: "image/jpeg",
    byteSize: 1_000,
    createdAt: "2026-01-01T00:00:00.000Z",
    imageUrl: "https://example.com/photo-1.jpg",
    heartCount: 0,
    workflowStatus: "idle",
    finalPhoto: null,
    variants: { thumbnail: null, preview: null },
    capturedAt: null,
    latitude: null,
    longitude: null,
  };
}

export function makePhoto(overrides: Partial<PhotoRecord> = {}): PhotoRecord {
  return {
    ...makeBasePhotoFields(),
    comments: [],
    ...overrides,
  };
}

export function makeGalleryPhoto(
  overrides: Partial<GalleryPhotoRecord> = {},
): GalleryPhotoRecord {
  return {
    ...makeBasePhotoFields(),
    comments: [],
    viewerHearted: false,
    viewerRequestedRaw: false,
    viewerRawDownload: null,
    viewerRawDownloadedAt: null,
    ...overrides,
  };
}

export function makeStorageUsage(
  overrides: Partial<StorageUsageRecord> = {},
): StorageUsageRecord {
  return {
    photoCount: 0,
    finalCount: 0,
    variantCount: 0,
    rawCount: 0,
    proofBytes: 0,
    finalBytes: 0,
    variantBytes: 0,
    rawBytes: 0,
    totalBytes: 0,
    plan: "free",
    capBytes: 5_000_000_000,
    events: [],
    ...overrides,
  };
}
