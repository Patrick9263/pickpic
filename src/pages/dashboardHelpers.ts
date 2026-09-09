import type { PhotoRecord, PhotoVariantSource } from "../types";
import { isVariantSetMissing } from "../imageVariants";

/*
 * Pulled out of DashboardPage.tsx so it can be unit tested without
 * rendering the component tree. See galleryHelpers.ts for the same pattern
 * on the gallery side.
 */
export function getMissingVariantSources(
  photo: PhotoRecord,
): PhotoVariantSource[] {
  const sources: PhotoVariantSource[] = [];

  if (isVariantSetMissing(photo.variants)) {
    sources.push("original");
  }

  if (photo.finalPhoto && isVariantSetMissing(photo.finalPhoto.variants)) {
    sources.push("final");
  }

  return sources;
}

/*
 * Splits a Promise.allSettled result into the entries that succeeded and
 * whether anything failed, so a single dropped per-event photo request
 * doesn't erase the photos that did load for every other event.
 */
export function collectFulfilledPhotoEntries(
  results: readonly PromiseSettledResult<readonly [string, PhotoRecord[]]>[],
): { entries: [string, PhotoRecord[]][]; hasFailure: boolean } {
  const entries: [string, PhotoRecord[]][] = [];
  let hasFailure = false;

  for (const result of results) {
    if (result.status === "fulfilled") {
      entries.push([...result.value]);
    } else {
      hasFailure = true;
    }
  }

  return { entries, hasFailure };
}

export interface QueueDisplayImage {
  thumbnailUrl: string;
  width: number | undefined;
  height: number | undefined;
  fullImageUrl: string;
}

/*
 * A revision request is a final photo hearted again, so the queue must show
 * the delivered final (what the viewer is reacting to), not the pre-edit
 * proof — falls back to the proof if a final somehow isn't present yet.
 */
export function getQueueDisplayImage(
  photo: PhotoRecord,
  showFinal: boolean,
): QueueDisplayImage {
  const source = showFinal && photo.finalPhoto ? photo.finalPhoto : photo;
  const thumbnail = source.variants.thumbnail;

  return {
    thumbnailUrl: thumbnail?.imageUrl ?? source.imageUrl,
    width: thumbnail?.width,
    height: thumbnail?.height,
    fullImageUrl: source.imageUrl,
  };
}
