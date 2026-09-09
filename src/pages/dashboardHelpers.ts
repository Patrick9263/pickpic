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
