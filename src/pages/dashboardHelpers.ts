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
