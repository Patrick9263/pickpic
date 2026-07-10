import "./EditingQueue.css";

interface EventRecord {
  id: string;
  title: string;
}

interface PhotoCommentRecord {
  id: string;
  photoId: string;
  displayName: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  resolvedAt: string | null;
}

interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
  heartCount: number;
  comments: PhotoCommentRecord[];
}

interface EditingQueueProps {
  events: EventRecord[];
  photosByEvent: Record<string, PhotoRecord[]>;
  resolvingCommentId: string | null;
  clearingHeartsPhotoId: string | null;

  onSetCommentResolved: (
    eventId: string,
    photoId: string,
    comment: PhotoCommentRecord,
    resolved: boolean,
  ) => Promise<void>;

  onClearHearts: (eventId: string, photo: PhotoRecord) => Promise<void>;
}

interface QueueItem {
  event: EventRecord;
  photo: PhotoRecord;
  unresolvedComments: PhotoCommentRecord[];
}

function EditingQueue({
  events,
  photosByEvent,
  resolvingCommentId,
  clearingHeartsPhotoId,
  onSetCommentResolved,
  onClearHearts,
}: EditingQueueProps) {
  const queueItems: QueueItem[] = events
    .flatMap((eventRecord) =>
      (photosByEvent[eventRecord.id] ?? []).map((photo) => ({
        event: eventRecord,
        photo,
        unresolvedComments: photo.comments.filter(
          (comment) => comment.resolvedAt === null,
        ),
      })),
    )
    .filter(
      ({ photo, unresolvedComments }) =>
        photo.heartCount > 0 || unresolvedComments.length > 0,
    )
    .sort((first, second) => {
      if (second.photo.heartCount !== first.photo.heartCount) {
        return second.photo.heartCount - first.photo.heartCount;
      }

      if (
        second.unresolvedComments.length !== first.unresolvedComments.length
      ) {
        return (
          second.unresolvedComments.length - first.unresolvedComments.length
        );
      }

      return first.photo.originalFilename.localeCompare(
        second.photo.originalFilename,
      );
    });

  return (
    <section className="editing-queue-section">
      <div className="section-heading">
        <div>
          <p className="section-label">Photographer workflow</p>
          <h2>Editing queue</h2>
        </div>

        <span className="queue-total">
          {queueItems.length} {queueItems.length === 1 ? "photo" : "photos"}
        </span>
      </div>

      {queueItems.length === 0 ? (
        <div className="editing-queue-empty">
          <h3>No pending edit requests</h3>
          <p>Photos with hearts or unresolved comments will appear here.</p>
        </div>
      ) : (
        <div className="editing-queue-list">
          {queueItems.map(({ event, photo, unresolvedComments }) => (
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
                      {unresolvedComments.length}{" "}
                      {unresolvedComments.length === 1 ? "note" : "notes"}
                    </span>
                  </div>
                </div>

                {photo.heartCount > 0 && (
                  <div className="queue-heart-request">
                    <span>
                      {photo.heartCount}{" "}
                      {photo.heartCount === 1 ? "person has" : "people have"}{" "}
                      requested an edit.
                    </span>

                    <button
                      type="button"
                      disabled={clearingHeartsPhotoId === photo.id}
                      onClick={() => void onClearHearts(event.id, photo)}
                    >
                      {clearingHeartsPhotoId === photo.id
                        ? "Clearing…"
                        : "Clear hearts"}
                    </button>
                  </div>
                )}

                {unresolvedComments.length > 0 && (
                  <div className="queue-comments">
                    {unresolvedComments.map((comment) => (
                      <article className="queue-comment" key={comment.id}>
                        <div>
                          <strong>{comment.displayName}</strong>

                          <p>{comment.body}</p>
                        </div>

                        <button
                          type="button"
                          disabled={resolvingCommentId === comment.id}
                          onClick={() =>
                            void onSetCommentResolved(
                              event.id,
                              photo.id,
                              comment,
                              true,
                            )
                          }
                        >
                          {resolvingCommentId === comment.id
                            ? "Resolving…"
                            : "Mark resolved"}
                        </button>
                      </article>
                    ))}
                  </div>
                )}
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}

export default EditingQueue;
