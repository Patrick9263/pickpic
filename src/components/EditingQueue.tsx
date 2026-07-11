import "../styles/EditingQueue.css";

import type { EventRecord, PhotoRecord, PhotoWorkflowStatus } from "../types";

interface EditingQueueProps {
  events: EventRecord[];
  photosByEvent: Record<string, PhotoRecord[]>;
  updatingWorkflowPhotoId: string | null;
  clearingHeartsPhotoId: string | null;

  onSetPhotoWorkflowStatus: (
    eventId: string,
    photo: PhotoRecord,
    status: PhotoWorkflowStatus,
  ) => Promise<void>;

  onClearHearts: (eventId: string, photo: PhotoRecord) => Promise<void>;
}

interface QueueItem {
  event: EventRecord;
  photo: PhotoRecord;
}

type QueueKind = "requested" | "editing" | "revision";

function sortQueueItems(items: QueueItem[]): QueueItem[] {
  return [...items].sort((first, second) => {
    if (second.photo.heartCount !== first.photo.heartCount) {
      return second.photo.heartCount - first.photo.heartCount;
    }

    return first.photo.originalFilename.localeCompare(
      second.photo.originalFilename,
    );
  });
}

function EditingQueue({
  events,
  photosByEvent,
  updatingWorkflowPhotoId,
  clearingHeartsPhotoId,
  onSetPhotoWorkflowStatus,
  onClearHearts,
}: EditingQueueProps) {
  const allPhotos: QueueItem[] = events.flatMap((eventRecord) =>
    (photosByEvent[eventRecord.id] ?? []).map((photo) => ({
      event: eventRecord,
      photo,
    })),
  );

  const requested = sortQueueItems(
    allPhotos.filter(
      ({ photo }) => photo.workflowStatus === "idle" && photo.heartCount > 0,
    ),
  );

  const editing = sortQueueItems(
    allPhotos.filter(({ photo }) => photo.workflowStatus === "editing"),
  );

  const revisions = sortQueueItems(
    allPhotos.filter(
      ({ photo }) => photo.workflowStatus === "final" && photo.heartCount > 0,
    ),
  );

  const total = requested.length + editing.length + revisions.length;

  function renderQueueGroup(
    title: string,
    description: string,
    kind: QueueKind,
    items: QueueItem[],
  ) {
    if (items.length === 0) {
      return null;
    }

    return (
      <section className="queue-group">
        <div className="queue-group-header">
          <div>
            <h3>{title}</h3>
            <p>{description}</p>
          </div>

          <span>{items.length}</span>
        </div>

        <div className="editing-queue-list">
          {items.map(({ event, photo }) => {
            const isUpdating = updatingWorkflowPhotoId === photo.id;
            const isClearing = clearingHeartsPhotoId === photo.id;

            return (
              <article className="editing-queue-item" key={photo.id}>
                <a
                  className="queue-thumbnail-link"
                  href={photo.imageUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  <img
                    src={photo.imageUrl}
                    alt={photo.originalFilename}
                    loading="lazy"
                  />
                </a>

                <div className="queue-item-content">
                  <div className="queue-item-heading">
                    <div>
                      <span className="queue-event-title">{event.title}</span>

                      <h3>{photo.originalFilename}</h3>
                    </div>

                    <div className="queue-request-counts">
                      <span>♥ {photo.heartCount}</span>

                      <span>
                        {photo.comments.length}{" "}
                        {photo.comments.length === 1 ? "comment" : "comments"}
                      </span>
                    </div>
                  </div>

                  {photo.comments.length > 0 && (
                    <div className="queue-comments">
                      {photo.comments.map((comment) => (
                        <article className="queue-comment" key={comment.id}>
                          <div>
                            <strong>{comment.displayName}</strong>

                            <p>{comment.body}</p>
                          </div>
                        </article>
                      ))}
                    </div>
                  )}

                  <div className="queue-actions">
                    {kind === "requested" && (
                      <>
                        <button
                          className="queue-primary-button"
                          type="button"
                          disabled={isUpdating}
                          onClick={() =>
                            void onSetPhotoWorkflowStatus(
                              event.id,
                              photo,
                              "editing",
                            )
                          }
                        >
                          {isUpdating ? "Updating…" : "Start editing"}
                        </button>

                        <button
                          className="queue-secondary-button"
                          type="button"
                          disabled={isClearing}
                          onClick={() => void onClearHearts(event.id, photo)}
                        >
                          {isClearing ? "Clearing…" : "Clear request"}
                        </button>
                      </>
                    )}

                    {kind === "editing" && (
                      <>
                        <button
                          className="queue-primary-button"
                          type="button"
                          disabled={isUpdating}
                          onClick={() =>
                            void onSetPhotoWorkflowStatus(
                              event.id,
                              photo,
                              "final",
                            )
                          }
                        >
                          {isUpdating ? "Updating…" : "Mark final"}
                        </button>

                        <button
                          className="queue-secondary-button"
                          type="button"
                          disabled={isUpdating}
                          onClick={() =>
                            void onSetPhotoWorkflowStatus(
                              event.id,
                              photo,
                              "idle",
                            )
                          }
                        >
                          Move back
                        </button>
                      </>
                    )}

                    {kind === "revision" && (
                      <>
                        <button
                          className="queue-primary-button"
                          type="button"
                          disabled={isUpdating}
                          onClick={() =>
                            void onSetPhotoWorkflowStatus(
                              event.id,
                              photo,
                              "editing",
                            )
                          }
                        >
                          {isUpdating ? "Updating…" : "Start revision"}
                        </button>

                        <button
                          className="queue-secondary-button"
                          type="button"
                          disabled={isClearing}
                          onClick={() => void onClearHearts(event.id, photo)}
                        >
                          {isClearing ? "Clearing…" : "Dismiss request"}
                        </button>
                      </>
                    )}
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      </section>
    );
  }

  return (
    <section className="editing-queue-section">
      <div className="section-heading">
        <div>
          <p className="section-label">Photographer workflow</p>
          <h2>Editing queue</h2>
        </div>

        <span className="queue-total">
          {total} {total === 1 ? "photo" : "photos"}
        </span>
      </div>

      {total === 0 ? (
        <div className="editing-queue-empty">
          <h3>No pending edit requests</h3>
          <p>
            Hearted photos appear here. Comments alone do not create an edit
            request.
          </p>
        </div>
      ) : (
        <div className="queue-groups">
          {renderQueueGroup(
            "Requested",
            "Photos your viewers have hearted.",
            "requested",
            requested,
          )}

          {renderQueueGroup(
            "Editing",
            "Photos currently being worked on.",
            "editing",
            editing,
          )}

          {renderQueueGroup(
            "Revision requested",
            "Final photos that were hearted again.",
            "revision",
            revisions,
          )}
        </div>
      )}
    </section>
  );
}

export default EditingQueue;
