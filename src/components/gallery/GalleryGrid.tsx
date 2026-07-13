import type { GalleryPhotoGroup } from "./types";
import type { GalleryPhotoRecord } from "../../types";
import { useState } from "react";

type GalleryGridProps = {
  group: GalleryPhotoGroup;
  togglingPhotoId: string | null;
  openPhoto(photo: GalleryPhotoRecord): void;
  toggleHeart(photo: GalleryPhotoRecord): Promise<void>;
  priorityPhotoIds: Set<string>;
  interactionsEnabled: boolean;
};

function GalleryGrid({
  group,
  togglingPhotoId,
  openPhoto,
  toggleHeart,
  priorityPhotoIds,
  interactionsEnabled,
}: GalleryGridProps) {
  const [loadedPhotoIds, setLoadedPhotoIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [failedPhotoIds, setFailedPhotoIds] = useState<Set<string>>(
    () => new Set(),
  );
  return (
    <div className="gallery-grid">
      {group.photos.map((photo) => {
        const isToggling = togglingPhotoId === photo.id;
        const isPriority = priorityPhotoIds.has(photo.id);
        const displayedThumbnail = photo.finalPhoto
          ? photo.finalPhoto.variants.thumbnail
          : photo.variants.thumbnail;
        const gridImageUrl =
          displayedThumbnail?.imageUrl ??
          photo.finalPhoto?.imageUrl ??
          photo.imageUrl;
        const isLoaded = loadedPhotoIds.has(photo.id);
        const hasFailed = failedPhotoIds.has(photo.id);

        return (
          <article className="gallery-photo-card" key={photo.id}>
            <button
              className="gallery-photo-button"
              type="button"
              data-gallery-photo-id={photo.id}
              onClick={() => openPhoto(photo)}
              aria-label={`Open ${photo.originalFilename}`}
            >
              <div
                className={`gallery-image-frame ${
                  isLoaded ? "gallery-image-loaded" : ""
                }`}
              >
                {!isLoaded && !hasFailed && (
                  <div className="gallery-image-skeleton" aria-hidden="true" />
                )}

                {hasFailed ? (
                  <div className="gallery-image-error">
                    <span>Image unavailable</span>

                    <button
                      type="button"
                      onClick={() => {
                        setFailedPhotoIds((currentIds) => {
                          const nextIds = new Set(currentIds);
                          nextIds.delete(photo.id);
                          return nextIds;
                        });
                      }}
                    >
                      Retry
                    </button>
                  </div>
                ) : (
                  <img
                    src={gridImageUrl}
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
                      setFailedPhotoIds((currentIds) => {
                        const nextIds = new Set(currentIds);
                        nextIds.add(photo.id);
                        return nextIds;
                      });
                    }}
                    style={{
                      aspectRatio: displayedThumbnail
                        ? `${displayedThumbnail.width} / ${displayedThumbnail.height}`
                        : undefined,
                    }}
                  />
                )}
              </div>
            </button>

            {photo.finalPhoto && (
              <span className="gallery-final-badge">Final</span>
            )}
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
              title={interactionsEnabled ? undefined : "This gallery is closed"}
            >
              <span aria-hidden="true">♥</span>

              <span>{photo.heartCount}</span>
            </button>
          </article>
        );
      })}
    </div>
  );
}

export default GalleryGrid;
