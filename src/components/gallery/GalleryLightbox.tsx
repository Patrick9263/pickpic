import type { PhotoVersion } from "../../pages/GalleryPage";
import type { GalleryPhotoRecord, ViewerPhotoCommentRecord } from "../../types";
import GalleryComments from "./GalleryComments";
import type { FormEvent } from "react";

type GalleryLightboxProps = {
  selectedPhoto: GalleryPhotoRecord;
  closeLightbox: () => void;
  selectedImageUrl: string | null;
  selectedVersion: PhotoVersion;
  setSelectedVersion: (value: React.SetStateAction<PhotoVersion>) => void;
  togglingPhotoId: string | null;
  toggleHeart: (photo: GalleryPhotoRecord) => Promise<void>;

  // GalleryComments
  commentActionId: string | null;
  commentText: string;
  isSubmittingComment: boolean;
  setCommentText: (value: React.SetStateAction<string>) => void;
  editComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  deleteComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  submitComment: (event: FormEvent<HTMLFormElement>) => Promise<void>;
};

function GalleryLightbox({
  selectedPhoto,
  closeLightbox,
  selectedImageUrl,
  selectedVersion,
  setSelectedVersion,
  togglingPhotoId,
  toggleHeart,
  commentActionId,
  commentText,
  isSubmittingComment,
  setCommentText,
  editComment,
  deleteComment,
  submitComment,
}: GalleryLightboxProps) {
  return (
    <div
      className="lightbox"
      role="dialog"
      aria-modal="true"
      aria-label={selectedPhoto.originalFilename}
    >
      <button
        className="lightbox-backdrop"
        type="button"
        onClick={closeLightbox}
        aria-label="Close image"
      />

      <div className="lightbox-content">
        <button
          className="lightbox-close"
          type="button"
          onClick={closeLightbox}
          aria-label="Close image"
        >
          x
        </button>

        <img
          src={selectedImageUrl ?? selectedPhoto.imageUrl}
          alt={selectedPhoto.originalFilename}
        />
        {selectedPhoto.finalPhoto && (
          <div className="photo-version-controls">
            <div className="photo-version-toggle">
              <button
                type="button"
                className={
                  selectedVersion === "original" ? "photo-version-active" : ""
                }
                onClick={() => setSelectedVersion("original")}
              >
                Original
              </button>

              <button
                type="button"
                className={
                  selectedVersion === "final" ? "photo-version-active" : ""
                }
                onClick={() => setSelectedVersion("final")}
              >
                Final
              </button>
            </div>

            <a
              className="download-final-link"
              href={selectedPhoto.finalPhoto.imageUrl}
              download={selectedPhoto.finalPhoto.originalFilename}
            >
              Download final
            </a>
          </div>
        )}
        <div className="lightbox-footer">
          <p>{selectedPhoto.originalFilename}</p>

          <button
            className={`lightbox-heart-button ${
              selectedPhoto.viewerHearted ? "lightbox-heart-button-active" : ""
            }`}
            type="button"
            disabled={togglingPhotoId === selectedPhoto.id}
            onClick={() => void toggleHeart(selectedPhoto)}
            aria-pressed={selectedPhoto.viewerHearted}
          >
            <span aria-hidden="true">♥</span>

            <span>
              {selectedPhoto.viewerHearted ? "Edit requested" : "Request edit"}
            </span>

            <span>{selectedPhoto.heartCount}</span>
          </button>
        </div>

        <GalleryComments
          selectedPhoto={selectedPhoto}
          commentActionId={commentActionId}
          commentText={commentText}
          isSubmittingComment={isSubmittingComment}
          setCommentText={setCommentText}
          editComment={editComment}
          deleteComment={deleteComment}
          submitComment={submitComment}
        />
      </div>
    </div>
  );
}

export default GalleryLightbox;
