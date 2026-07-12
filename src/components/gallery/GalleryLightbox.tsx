import {
  useEffect,
  useRef,
  type Dispatch,
  type FormEvent,
  type PointerEvent as ReactPointerEvent,
  type SetStateAction,
} from "react";
import type { GalleryPhotoRecord, ViewerPhotoCommentRecord } from "../../types";
import type { PhotoVersion } from "./types";
import GalleryComments from "./GalleryComments";

interface PointerStart {
  pointerId: number;
  x: number;
  y: number;
}

const SWIPE_THRESHOLD = 60;
const TAP_MOVEMENT_THRESHOLD = 12;
const SIDE_TAP_RATIO = 0.3;

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  return target.matches("input, textarea, select") || target.isContentEditable;
}

function isInteractiveTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) {
    return false;
  }

  return Boolean(
    target.closest(
      "button, a, input, textarea, select, [contenteditable='true']",
    ),
  );
}

type GalleryLightboxProps = {
  selectedPhoto: GalleryPhotoRecord;
  closeLightbox: () => void;
  selectedImageUrl: string | null;
  selectedVersion: PhotoVersion;
  setSelectedVersion: Dispatch<SetStateAction<PhotoVersion>>;
  togglingPhotoId: string | null;
  toggleHeart: (photo: GalleryPhotoRecord) => Promise<void>;
  commentActionId: string | null;
  commentText: string;
  isSubmittingComment: boolean;
  setCommentText: Dispatch<SetStateAction<string>>;
  editComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  deleteComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  submitComment: (event: FormEvent<HTMLFormElement>) => Promise<void>;
  photoIndex: number;
  photoCount: number;
  canGoPrevious: boolean;
  canGoNext: boolean;
  onPrevious: () => void;
  onNext: () => void;
  interactionsEnabled: boolean;
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
  photoIndex,
  photoCount,
  canGoPrevious,
  canGoNext,
  onPrevious,
  onNext,
  interactionsEnabled,
}: GalleryLightboxProps) {
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  const pointerStartRef = useRef<PointerStart | null>(null);

  useEffect(() => {
    closeButtonRef.current?.focus();
  }, []);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;

    document.body.style.overflow = "hidden";

    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, []);

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent): void {
      if (event.key === "Escape") {
        event.preventDefault();
        closeLightbox();
        return;
      }

      if (isTypingTarget(event.target)) {
        return;
      }

      if (event.key === "ArrowLeft" && canGoPrevious) {
        event.preventDefault();
        onPrevious();
      }

      if (event.key === "ArrowRight" && canGoNext) {
        event.preventDefault();
        onNext();
      }
    }

    window.addEventListener("keydown", handleKeyDown);

    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [canGoNext, canGoPrevious, closeLightbox, onNext, onPrevious]);

  function handlePointerDown(event: ReactPointerEvent<HTMLDivElement>): void {
    if (event.pointerType === "mouse") {
      return;
    }

    pointerStartRef.current = {
      pointerId: event.pointerId,
      x: event.clientX,
      y: event.clientY,
    };

    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function handlePointerUp(event: ReactPointerEvent<HTMLDivElement>): void {
    const start = pointerStartRef.current;

    pointerStartRef.current = null;

    if (!start || start.pointerId !== event.pointerId) {
      return;
    }

    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }

    const horizontalMovement = event.clientX - start.x;

    const verticalMovement = event.clientY - start.y;

    const absoluteHorizontal = Math.abs(horizontalMovement);

    const absoluteVertical = Math.abs(verticalMovement);

    const isHorizontalSwipe =
      absoluteHorizontal >= SWIPE_THRESHOLD &&
      absoluteHorizontal > absoluteVertical * 1.2;

    if (isHorizontalSwipe) {
      if (horizontalMovement < 0 && canGoNext) {
        onNext();
      } else if (horizontalMovement > 0 && canGoPrevious) {
        onPrevious();
      }

      return;
    }

    const isTap =
      absoluteHorizontal <= TAP_MOVEMENT_THRESHOLD &&
      absoluteVertical <= TAP_MOVEMENT_THRESHOLD;

    if (!isTap || isInteractiveTarget(event.target)) {
      return;
    }

    const bounds = event.currentTarget.getBoundingClientRect();

    const tapRatio = (event.clientX - bounds.left) / bounds.width;

    if (tapRatio <= SIDE_TAP_RATIO && canGoPrevious) {
      onPrevious();
    } else if (tapRatio >= 1 - SIDE_TAP_RATIO && canGoNext) {
      onNext();
    }
  }

  function handlePointerCancel(): void {
    pointerStartRef.current = null;
  }

  return (
    <div
      className="lightbox"
      role="dialog"
      aria-modal="true"
      aria-label={selectedPhoto.originalFilename}
    >
      <div className="lightbox-backdrop" aria-hidden="true" />

      <div className="lightbox-content">
        <button
          ref={closeButtonRef}
          className="lightbox-close"
          type="button"
          onClick={closeLightbox}
          aria-label="Close photo viewer"
        >
          <svg aria-hidden="true" viewBox="0 0 24 24">
            <path
              d="M6 6l12 12M18 6 6 18"
              fill="none"
              stroke="currentColor"
              strokeLinecap="round"
              strokeWidth="2"
            />
          </svg>
        </button>

        <div
          className="lightbox-image-stage"
          onPointerDown={handlePointerDown}
          onPointerUp={handlePointerUp}
          onPointerCancel={handlePointerCancel}
        >
          <button
            className="lightbox-nav lightbox-nav-previous"
            type="button"
            disabled={!canGoPrevious}
            onClick={onPrevious}
            aria-label="Previous photo"
          >
            <svg aria-hidden="true" viewBox="0 0 24 24">
              <path
                d="M15 18 9 12l6-6"
                fill="none"
                stroke="currentColor"
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth="2.25"
              />
            </svg>
          </button>

          <img
            src={selectedImageUrl ?? selectedPhoto.imageUrl}
            alt={selectedPhoto.originalFilename}
            draggable={false}
          />

          <button
            className="lightbox-nav lightbox-nav-next"
            type="button"
            disabled={!canGoNext}
            onClick={onNext}
            aria-label="Next photo"
          >
            <svg aria-hidden="true" viewBox="0 0 24 24">
              <path
                d="m9 18 6-6-6-6"
                fill="none"
                stroke="currentColor"
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth="2.25"
              />
            </svg>
          </button>
        </div>

        <p className="lightbox-position" aria-live="polite">
          {photoIndex + 1} of {photoCount}
        </p>

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
            disabled={
              !interactionsEnabled || togglingPhotoId === selectedPhoto.id
            }
            onClick={() => void toggleHeart(selectedPhoto)}
            aria-pressed={selectedPhoto.viewerHearted}
          >
            <span aria-hidden="true">♥</span>

            <span>
              {!interactionsEnabled
                ? "Gallery closed"
                : selectedPhoto.viewerHearted
                  ? "Edit requested"
                  : "Request edit"}
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
          interactionsEnabled={interactionsEnabled}
        />
      </div>
    </div>
  );
}

export default GalleryLightbox;
