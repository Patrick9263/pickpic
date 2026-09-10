import type { GalleryPhotoGroup } from "./types";
import type { GalleryPhotoRecord } from "../../types";
import { useState } from "react";
import {
  formatApproximateByteSize,
  getRawRequestState,
} from "../../pages/galleryHelpers";
type GalleryGridProps = {
  group: GalleryPhotoGroup;
  togglingPhotoId: string | null;
  openPhoto(photo: GalleryPhotoRecord): void;
  toggleHeart(photo: GalleryPhotoRecord): Promise<void>;
  togglingRawRequestPhotoId: string | null;
  toggleRawRequest(photo: GalleryPhotoRecord): Promise<void>;
  downloadingRawPhotoId: string | null;
  downloadRawPhoto(photo: GalleryPhotoRecord): Promise<void>;
  rawRequestsEnabled: boolean;
  priorityPhotoIds: Set<string>;
  interactionsEnabled: boolean;
  isSelecting: boolean;
  selectedPhotoIds: Set<string>;
  togglePhotoSelection(photo: GalleryPhotoRecord): void;
};
function GalleryGrid({
  group,
  togglingPhotoId,
  openPhoto,
  toggleHeart,
  togglingRawRequestPhotoId,
  toggleRawRequest,
  downloadingRawPhotoId,
  downloadRawPhoto,
  rawRequestsEnabled,
  priorityPhotoIds,
  interactionsEnabled,
  isSelecting,
  selectedPhotoIds,
  togglePhotoSelection,
}: GalleryGridProps) {
  const [loadedPhotoIds, setLoadedPhotoIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [failedPhotoIds, setFailedPhotoIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [retryCounts, setRetryCounts] = useState<Record<string, number>>({});
  return (
    <div className="gallery-grid">
      {group.photos.map((photo) => {
        const isToggling = togglingPhotoId === photo.id;
        const isTogglingRawRequest = togglingRawRequestPhotoId === photo.id;
        const rawRequestState = getRawRequestState(photo);
        const isDownloadingRaw = downloadingRawPhotoId === photo.id;
        const isPriority = priorityPhotoIds.has(photo.id);
        const isSelected = selectedPhotoIds.has(photo.id);
        const displayedThumbnail = photo.finalPhoto
          ? photo.finalPhoto.variants.thumbnail
          : photo.variants.thumbnail;
        const gridImageUrl =
          displayedThumbnail?.imageUrl ??
          photo.finalPhoto?.imageUrl ??
          photo.imageUrl;
        const retryCount = retryCounts[photo.id] ?? 0;
        const requestedImageUrl =
          retryCount > 0
            ? `${gridImageUrl}${
                gridImageUrl.includes("?") ? "&" : "?"
              }retry=${retryCount}`
            : gridImageUrl;
        const isLoaded = loadedPhotoIds.has(photo.id);
        const hasFailed = failedPhotoIds.has(photo.id);
        function retryImage(): void {
          setLoadedPhotoIds((currentIds) => {
            const nextIds = new Set(currentIds);
            nextIds.delete(photo.id);
            return nextIds;
          });
          setFailedPhotoIds((currentIds) => {
            const nextIds = new Set(currentIds);
            nextIds.delete(photo.id);
            return nextIds;
          });
          setRetryCounts((currentCounts) => ({
            ...currentCounts,
            [photo.id]: (currentCounts[photo.id] ?? 0) + 1,
          }));
        }
        return (
          <article
            className={[
              "gallery-photo-card",
              isSelected ? "gallery-photo-card-selected" : "",
            ]
              .filter(Boolean)
              .join(" ")}
            key={photo.id}
          >
            <button
              className="gallery-photo-button"
              type="button"
              data-gallery-photo-id={photo.id}
              onClick={() => {
                if (hasFailed) {
                  retryImage();
                  return;
                }
                if (isSelecting) {
                  togglePhotoSelection(photo);
                  return;
                }
                openPhoto(photo);
              }}
              aria-label={
                hasFailed
                  ? `Retry loading ${photo.originalFilename}`
                  : isSelecting
                    ? `${isSelected ? "Deselect" : "Select"} ${
                        photo.originalFilename
                      }`
                    : `Open ${photo.originalFilename}`
              }
              aria-pressed={isSelecting ? isSelected : undefined}
            >
              <div
                className={`gallery-image-frame ${
                  isLoaded ? "gallery-image-loaded" : ""
                }`}
                style={{
                  aspectRatio: displayedThumbnail
                    ? `${displayedThumbnail.width} / ${displayedThumbnail.height}`
                    : undefined,
                }}
              >
                {!isLoaded && !hasFailed && (
                  <div className="gallery-image-skeleton" aria-hidden="true" />
                )}
                {hasFailed ? (
                  <div className="gallery-image-error">
                    <span>Image unavailable</span>
                    <span className="gallery-image-retry-label">
                      Tap to retry
                    </span>
                  </div>
                ) : (
                  <img
                    src={requestedImageUrl}
                    alt={photo.originalFilename}
                    width={displayedThumbnail?.width}
                    height={displayedThumbnail?.height}
                    loading={isPriority ? "eager" : "lazy"}
                    fetchPriority={isPriority ? "high" : "auto"}
                    decoding="async"
                    className={isLoaded ? "gallery-image-visible" : ""}
                    onLoad={() => {
                      setLoadedPhotoIds((currentIds) => {
                        const nextIds = new Set(currentIds);
                        nextIds.add(photo.id);
                        return nextIds;
                      });
                    }}
                    onError={() => {
                      setLoadedPhotoIds((currentIds) => {
                        const nextIds = new Set(currentIds);
                        nextIds.delete(photo.id);
                        return nextIds;
                      });
                      setFailedPhotoIds((currentIds) => {
                        const nextIds = new Set(currentIds);
                        nextIds.add(photo.id);
                        return nextIds;
                      });
                    }}
                  />
                )}
              </div>
            </button>
            {isSelecting && (
              <span
                className={[
                  "gallery-selection-indicator",
                  isSelected ? "gallery-selection-indicator-selected" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
                aria-hidden="true"
              >
                {isSelected ? "✓" : ""}
              </span>
            )}
            {photo.finalPhoto && (
              <span className="gallery-final-badge">Final</span>
            )}
            {!isSelecting && (
              <button
                className={`gallery-heart-button ${
                  photo.viewerHearted ? "gallery-heart-button-active" : ""
                }`}
                type="button"
                disabled={!interactionsEnabled || isToggling}
                onClick={() => void toggleHeart(photo)}
                aria-pressed={photo.viewerHearted}
                aria-label={
                  !interactionsEnabled
                    ? `Gallery closed; ${photo.heartCount} edit requests for ${photo.originalFilename}`
                    : photo.viewerHearted
                      ? `Remove edit request for ${photo.originalFilename}`
                      : `Request an edit of ${photo.originalFilename}`
                }
                title={
                  interactionsEnabled ? undefined : "This gallery is closed"
                }
              >
                <span aria-hidden="true">♥</span>
                <span>{photo.heartCount}</span>
              </button>
            )}
            {/*
             * The "ready" state is the one exception to interactionsEnabled.
             * A closed gallery stops taking new requests, but a RAW already
             * delivered to this viewer stays collectable -- the same promise
             * the closed-gallery banner makes about photos and downloads, and
             * the worker's GET route is deliberately outside the
             * requireOpenGallery guard to match.
             */}
            {!isSelecting && rawRequestsEnabled && (
              <button
                className={`gallery-raw-request-button ${
                  rawRequestState === "none"
                    ? ""
                    : `gallery-raw-request-button-${rawRequestState}`
                }`}
                type="button"
                disabled={
                  rawRequestState === "ready"
                    ? isDownloadingRaw
                    : !interactionsEnabled || isTogglingRawRequest
                }
                onClick={() =>
                  void (rawRequestState === "ready"
                    ? downloadRawPhoto(photo)
                    : toggleRawRequest(photo))
                }
                aria-pressed={
                  rawRequestState === "ready"
                    ? undefined
                    : photo.viewerRequestedRaw
                }
                aria-label={
                  rawRequestState === "ready"
                    ? `Download the original RAW file for ${photo.originalFilename}` +
                      `, ${formatApproximateByteSize(
                        photo.viewerRawDownload?.byteSize ?? 0,
                      )}`
                    : !interactionsEnabled
                      ? `Gallery closed; cannot request the RAW file for ${photo.originalFilename}`
                      : rawRequestState === "waiting"
                        ? `Cancel RAW file request for ${photo.originalFilename}`
                        : rawRequestState === "collected"
                          ? `Already downloaded; request the RAW file for ${photo.originalFilename} again`
                          : `Request the original RAW file for ${photo.originalFilename}`
                }
                title={
                  rawRequestState === "ready" || interactionsEnabled
                    ? undefined
                    : "This gallery is closed"
                }
              >
                <span aria-hidden="true">
                  {rawRequestState === "ready"
                    ? "↓ RAW"
                    : rawRequestState === "collected"
                      ? "RAW ✓"
                      : "RAW"}
                </span>
              </button>
            )}
          </article>
        );
      })}
    </div>
  );
}

export default GalleryGrid;
