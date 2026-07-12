import type { GalleryPhotoGroup } from "./types";
import type { GalleryPhotoRecord } from "../../types";

type GalleryGridProps = {
  group: GalleryPhotoGroup;
  togglingPhotoId: string | null;
  openPhoto(photo: GalleryPhotoRecord): void;
  toggleHeart(photo: GalleryPhotoRecord): Promise<void>;
};

function GalleryGrid({
  group,
  togglingPhotoId,
  openPhoto,
  toggleHeart,
}: GalleryGridProps) {
  return (
    <div className="gallery-grid">
      {group.photos.map((photo) => {
        const isToggling = togglingPhotoId === photo.id;

        return (
          <article className="gallery-photo-card" key={photo.id}>
            <button
              className="gallery-photo-button"
              type="button"
              onClick={() => openPhoto(photo)}
              aria-label={`Open ${photo.originalFilename}`}
            >
              <img
                src={photo.finalPhoto?.imageUrl ?? photo.imageUrl}
                alt={photo.originalFilename}
                loading="lazy"
              />
            </button>

            {photo.finalPhoto && (
              <span className="gallery-final-badge">Final</span>
            )}
            <button
              className={`gallery-heart-button ${
                photo.viewerHearted ? "gallery-heart-button-active" : ""
              }`}
              type="button"
              disabled={isToggling}
              onClick={() => void toggleHeart(photo)}
              aria-pressed={photo.viewerHearted}
              aria-label={
                photo.viewerHearted
                  ? `Remove edit request for ${photo.originalFilename}`
                  : `Request an edit of ${photo.originalFilename}`
              }
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
