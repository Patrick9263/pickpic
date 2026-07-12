import type { ChangeEvent } from "react";
import type {
  EventRecord,
  PhotoRecord,
  UploadBatchProgress,
  PhotoWorkflowStatus,
} from "../types";
import { isVariantSetComplete, isVariantSetMissing } from "../imageVariants";

function getWorkflowLabel(photo: PhotoRecord): string {
  if (photo.workflowStatus === "editing") {
    return "Editing";
  }

  if (photo.workflowStatus === "final") {
    return photo.heartCount > 0 ? "Final · revision requested" : "Final";
  }

  return photo.heartCount > 0 ? "Requested" : "Not requested";
}

function formatCapturedAt(value: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/.exec(value);

  if (!match) {
    return value;
  }

  const [, year, month, day, hour, minute, second] = match;

  const date = new Date(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second),
  );

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function getMapUrl(latitude: number, longitude: number): string {
  return (
    "https://www.google.com/maps?q=" +
    encodeURIComponent(`${latitude},${longitude}`)
  );
}

function getUploadStageLabel(
  stage: UploadBatchProgress["currentStage"],
): string {
  switch (stage) {
    case "preparing":
      return "Preparing";

    case "uploading":
      return "Uploading";

    case "optimizing":
      return "Optimizing";

    default:
      return "Processing";
  }
}

type EventCardProps = {
  eventRecord: EventRecord;
  shareUrl: string;
  wasCopied: boolean;
  isUploading: boolean;
  editRequestCount: number;
  photos: PhotoRecord[];
  deletingPhotoId: string | null;
  clearingHeartsPhotoId: string | null;
  updatingWorkflowPhotoId: string | null;
  uploadingFinalPhotoId: string | null;
  repairingVariantsPhotoId: string | null;
  variantRepairWarnings: Record<string, string>;
  handleRepairPhotoVariants(eventId: string, photo: PhotoRecord): Promise<void>;
  handleFinalPhotoSelection(
    eventId: string,
    photo: PhotoRecord,
    event: ChangeEvent<HTMLInputElement>,
  ): Promise<void>;
  handleSetPhotoWorkflowStatus(
    eventId: string,
    photo: PhotoRecord,
    status: PhotoWorkflowStatus,
  ): Promise<void>;
  handlePhotoSelection(
    eventId: string,
    changeEvent: ChangeEvent<HTMLInputElement, Element>,
  ): Promise<void>;
  handleDeletePhoto(eventId: string, photo: PhotoRecord): Promise<void>;
  copyShareLink(eventRecord: EventRecord): Promise<void>;
  handleClearHearts(eventId: string, photo: PhotoRecord): Promise<void>;
  uploadProgress: UploadBatchProgress | null;
  uploadsDisabled: boolean;
};

function EventCard(props: EventCardProps) {
  const {
    eventRecord,
    shareUrl,
    wasCopied,
    isUploading,
    editRequestCount,
    photos,
    deletingPhotoId,
    clearingHeartsPhotoId,
    updatingWorkflowPhotoId,
    handleSetPhotoWorkflowStatus,
    handlePhotoSelection,
    handleDeletePhoto,
    copyShareLink,
    handleClearHearts,
    uploadingFinalPhotoId,
    handleFinalPhotoSelection,
    uploadProgress,
    uploadsDisabled,
    repairingVariantsPhotoId,
    variantRepairWarnings,
    handleRepairPhotoVariants,
  } = props;
  const isAnyVariantRepairRunning = repairingVariantsPhotoId !== null;

  function formatDate(value: string): string {
    const date = new Date(value);

    if (Number.isNaN(date.getTime())) {
      return value;
    }

    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }

  function formatFileSize(byteSize: number): string {
    if (byteSize < 1024 * 1024) {
      return `${Math.max(1, Math.round(byteSize / 1024))} KB`;
    }

    return `${(byteSize / (1024 * 1024)).toFixed(1)} MB`;
  }

  return (
    <article className="event-card" key={eventRecord.id}>
      <div className="event-card-summary">
        <div className="event-card-header">
          <span className="status-badge">{eventRecord.status}</span>

          <span className="created-date">
            {formatDate(eventRecord.createdAt)}
          </span>
        </div>

        <h3>{eventRecord.title}</h3>

        <dl className="event-stats">
          <div>
            <dt>Photos</dt>
            <dd>{photos.length}</dd>
          </div>

          <div>
            <dt>Edit requests</dt>
            <dd>{editRequestCount}</dd>
          </div>
        </dl>

        <div className="upload-controls">
          <input
            className="visually-hidden"
            id={`photo-upload-${eventRecord.id}`}
            type="file"
            accept="image/jpeg,.jpg,.jpeg"
            multiple
            disabled={uploadsDisabled}
            onChange={(event) =>
              void handlePhotoSelection(eventRecord.id, event)
            }
          />

          <label
            className={`upload-button ${
              uploadsDisabled ? "upload-button-disabled" : ""
            }`}
            htmlFor={`photo-upload-${eventRecord.id}`}
            aria-disabled={uploadsDisabled}
          >
            {isUploading && uploadProgress
              ? `Uploading ${uploadProgress.processed}/${uploadProgress.total}…`
              : "Upload JPGs"}
          </label>

          <span className="upload-help">
            Select one or more JPGs · Maximum 25 MB each
          </span>
          {uploadProgress && (
            <div className="upload-progress" aria-live="polite">
              <progress
                max={uploadProgress.total}
                value={uploadProgress.processed}
              />

              <span>
                {uploadProgress.processed}/{uploadProgress.total} processed
                {" · "}
                {uploadProgress.uploaded} uploaded
                {" · "}
                {uploadProgress.skipped} duplicates skipped
                {uploadProgress.failed > 0 && (
                  <>
                    {" · "}
                    {uploadProgress.failed} failed
                  </>
                )}
                {uploadProgress.warnings > 0 && (
                  <>
                    {" · "}
                    {uploadProgress.warnings} optimization{" "}
                    {uploadProgress.warnings === 1 ? "warning" : "warnings"}
                  </>
                )}
              </span>

              {uploadProgress.currentFilename && (
                <small>
                  {getUploadStageLabel(uploadProgress.currentStage)}{" "}
                  {uploadProgress.currentFilename}
                </small>
              )}
            </div>
          )}
        </div>
      </div>
      {photos.length > 0 && (
        <div className="event-card-scroll-region">
          <div className="photo-list">
            {photos.map((photo) => {
              const isUploadingFinal = uploadingFinalPhotoId === photo.id;
              const originalOptimized = isVariantSetComplete(photo.variants);
              const dashboardThumbnail = photo.variants.thumbnail;

              const finalOptimized =
                !photo.finalPhoto ||
                isVariantSetComplete(photo.finalPhoto.variants);

              const hasMissingVariants =
                isVariantSetMissing(photo.variants) ||
                Boolean(
                  photo.finalPhoto &&
                  isVariantSetMissing(photo.finalPhoto.variants),
                );

              const isRepairingVariants = repairingVariantsPhotoId === photo.id;

              const repairWarning = variantRepairWarnings[photo.id];
              return (
                <article className="photo-item" key={photo.id}>
                  <a
                    className="photo-thumbnail-link"
                    href={photo.imageUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <img
                      className="photo-thumbnail"
                      src={dashboardThumbnail?.imageUrl ?? photo.imageUrl}
                      alt={photo.originalFilename}
                      width={dashboardThumbnail?.width}
                      height={dashboardThumbnail?.height}
                      loading="lazy"
                      decoding="async"
                    />
                  </a>

                  <div className="photo-details">
                    <span title={photo.originalFilename}>
                      {photo.originalFilename}
                    </span>

                    <span className="photo-workflow-badge">
                      {getWorkflowLabel(photo)}
                    </span>

                    <small>
                      {formatFileSize(photo.byteSize)}
                      {" · "}
                      {photo.heartCount}{" "}
                      {photo.heartCount === 1 ? "heart" : "hearts"}
                      {" · "}
                      {photo.comments.length}{" "}
                      {photo.comments.length === 1 ? "comment" : "comments"}
                    </small>

                    <div className="photo-optimization-status">
                      <span
                        className={
                          originalOptimized && finalOptimized
                            ? "photo-optimization-complete"
                            : "photo-optimization-missing"
                        }
                      >
                        {originalOptimized && finalOptimized
                          ? "Web versions ready"
                          : "Web versions missing"}
                      </span>

                      {!originalOptimized && (
                        <small>Original needs optimization</small>
                      )}

                      {photo.finalPhoto && !finalOptimized && (
                        <small>Final needs optimization</small>
                      )}
                    </div>

                    {(photo.capturedAt ||
                      (photo.latitude !== null &&
                        photo.longitude !== null)) && (
                      <div className="photo-metadata">
                        {photo.capturedAt && (
                          <span>
                            Captured {formatCapturedAt(photo.capturedAt)}
                          </span>
                        )}

                        {photo.latitude !== null &&
                          photo.longitude !== null && (
                            <a
                              href={getMapUrl(photo.latitude, photo.longitude)}
                              target="_blank"
                              rel="noreferrer"
                            >
                              View location
                            </a>
                          )}
                      </div>
                    )}

                    {photo.finalPhoto && (
                      <div className="final-photo-details">
                        <span>Final: {photo.finalPhoto.originalFilename}</span>

                        <a
                          href={photo.finalPhoto.imageUrl}
                          target="_blank"
                          rel="noreferrer"
                        >
                          View final
                        </a>
                      </div>
                    )}

                    {photo.comments.length > 0 && (
                      <div className="dashboard-comments">
                        {photo.comments.map((comment) => (
                          <blockquote key={comment.id}>
                            <strong>{comment.displayName}</strong>
                            <span>{comment.body}</span>
                          </blockquote>
                        ))}
                      </div>
                    )}

                    <div className="photo-actions">
                      {hasMissingVariants && (
                        <button
                          className="optimize-photo-button"
                          type="button"
                          disabled={isAnyVariantRepairRunning}
                          onClick={() =>
                            void handleRepairPhotoVariants(
                              eventRecord.id,
                              photo,
                            )
                          }
                        >
                          {isRepairingVariants
                            ? "Optimizing…"
                            : "Optimize missing versions"}
                        </button>
                      )}
                      {photo.workflowStatus === "idle" && (
                        <button
                          className="workflow-photo-button"
                          type="button"
                          disabled={updatingWorkflowPhotoId === photo.id}
                          onClick={() =>
                            void handleSetPhotoWorkflowStatus(
                              eventRecord.id,
                              photo,
                              "editing",
                            )
                          }
                        >
                          {updatingWorkflowPhotoId === photo.id
                            ? "Updating…"
                            : "Start editing"}
                        </button>
                      )}
                      {photo.workflowStatus === "editing" && (
                        <>
                          <input
                            className="visually-hidden"
                            id={`event-final-upload-${photo.id}`}
                            type="file"
                            accept="image/jpeg,.jpg,.jpeg"
                            disabled={isUploadingFinal}
                            onChange={(changeEvent) =>
                              void handleFinalPhotoSelection(
                                eventRecord.id,
                                photo,
                                changeEvent,
                              )
                            }
                          />

                          <label
                            className={`workflow-upload-button ${
                              isUploadingFinal
                                ? "workflow-upload-button-disabled"
                                : ""
                            }`}
                            htmlFor={`event-final-upload-${photo.id}`}
                            aria-disabled={isUploadingFinal}
                          >
                            {isUploadingFinal
                              ? "Uploading…"
                              : photo.finalPhoto
                                ? "Upload replacement"
                                : "Upload final JPG"}
                          </label>

                          <button
                            className="workflow-photo-button"
                            type="button"
                            disabled={updatingWorkflowPhotoId === photo.id}
                            onClick={() =>
                              void handleSetPhotoWorkflowStatus(
                                eventRecord.id,
                                photo,
                                photo.finalPhoto ? "final" : "idle",
                              )
                            }
                          >
                            {photo.finalPhoto
                              ? "Keep current final"
                              : "Move back"}
                          </button>
                        </>
                      )}

                      {photo.workflowStatus === "final" && (
                        <button
                          className="workflow-photo-button"
                          type="button"
                          disabled={updatingWorkflowPhotoId === photo.id}
                          onClick={() =>
                            void handleSetPhotoWorkflowStatus(
                              eventRecord.id,
                              photo,
                              "editing",
                            )
                          }
                        >
                          {updatingWorkflowPhotoId === photo.id
                            ? "Updating…"
                            : "Edit again"}
                        </button>
                      )}
                      {photo.heartCount > 0 && (
                        <button
                          className="clear-hearts-button"
                          type="button"
                          disabled={clearingHeartsPhotoId === photo.id}
                          onClick={() =>
                            void handleClearHearts(eventRecord.id, photo)
                          }
                        >
                          {clearingHeartsPhotoId === photo.id
                            ? "Clearing…"
                            : "Clear hearts"}
                        </button>
                      )}

                      <button
                        className="delete-photo-button"
                        type="button"
                        disabled={deletingPhotoId === photo.id}
                        onClick={() =>
                          void handleDeletePhoto(eventRecord.id, photo)
                        }
                      >
                        {deletingPhotoId === photo.id ? "Deleting…" : "Delete"}
                      </button>
                      {repairWarning && (
                        <p className="photo-optimization-warning" role="alert">
                          {repairWarning}
                        </p>
                      )}
                    </div>
                  </div>
                </article>
              );
            })}
          </div>
        </div>
      )}

      <footer className="event-card-footer">
        <div className="share-link">
          <span>Gallery link</span>

          <code title={shareUrl}>{shareUrl}</code>
        </div>

        <button
          className="secondary-button full-width"
          type="button"
          onClick={() => void copyShareLink(eventRecord)}
        >
          {wasCopied ? "Copied!" : "Copy gallery link"}
        </button>
      </footer>
    </article>
  );
}

export default EventCard;
