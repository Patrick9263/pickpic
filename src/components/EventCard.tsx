import type { ChangeEvent } from "react";
import type { EventRecord, PhotoRecord, PhotoWorkflowStatus } from "../types";

function getWorkflowLabel(photo: PhotoRecord): string {
  if (photo.workflowStatus === "editing") {
    return "Editing";
  }

  if (photo.workflowStatus === "final") {
    return photo.heartCount > 0 ? "Final · revision requested" : "Final";
  }

  return photo.heartCount > 0 ? "Requested" : "Not requested";
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
  } = props;

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
          disabled={isUploading}
          onChange={(event) => void handlePhotoSelection(eventRecord.id, event)}
        />

        <label
          className={`upload-button ${
            isUploading ? "upload-button-disabled" : ""
          }`}
          htmlFor={`photo-upload-${eventRecord.id}`}
          aria-disabled={isUploading}
        >
          {isUploading ? "Uploading…" : "Upload JPG"}
        </label>

        <span className="upload-help">Maximum file size: 25 MB</span>
      </div>

      {photos.length > 0 && (
        <div className="photo-list">
          {photos.map((photo) => {
            const isUploadingFinal = uploadingFinalPhotoId === photo.id;
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
                    src={photo.imageUrl}
                    alt={photo.originalFilename}
                    loading="lazy"
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
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}

      <div className="share-link">
        <span>Gallery link</span>
        <code>{shareUrl}</code>
      </div>

      <button
        className="secondary-button full-width"
        type="button"
        onClick={() => void copyShareLink(eventRecord)}
      >
        {wasCopied ? "Copied!" : "Copy gallery link"}
      </button>
    </article>
  );
}

export default EventCard;
