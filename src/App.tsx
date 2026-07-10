import { useEffect, useState, type ChangeEvent, type FormEvent } from "react";
import "./App.css";
import GalleryPage from "./GalleryPage";

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
}

interface EventsResponse {
  events: EventRecord[];
}

interface PhotosResponse {
  photos: PhotoRecord[];
}

interface CreateEventResponse {
  event: EventRecord;
}

interface CreatePhotoResponse {
  photo: PhotoRecord;
}

interface ErrorResponse {
  error?: string;
}

const MAX_JPEG_BYTES = 25 * 1024 * 1024;

async function getErrorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as ErrorResponse;

    if (body.error) {
      return body.error;
    }
  } catch {
    // Fall through to the generic message.
  }

  return `Request failed with status ${response.status}.`;
}

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

function DashboardPage() {
  const [events, setEvents] = useState<EventRecord[]>([]);
  const [photosByEvent, setPhotosByEvent] = useState<
    Record<string, PhotoRecord[]>
  >({});
  const [title, setTitle] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isCreating, setIsCreating] = useState(false);
  const [uploadingEventId, setUploadingEventId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copiedEventId, setCopiedEventId] = useState<string | null>(null);
  const [deletingPhotoId, setDeletingPhotoId] = useState<string | null>(null);

  async function loadPhotos(eventId: string): Promise<PhotoRecord[]> {
    const response = await fetch(
      `/api/events/${encodeURIComponent(eventId)}/photos`,
    );

    if (!response.ok) {
      throw new Error(await getErrorMessage(response));
    }

    const body = (await response.json()) as PhotosResponse;
    return body.photos;
  }

  async function loadEvents(): Promise<void> {
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/events");

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const body = (await response.json()) as EventsResponse;

      const photoEntries = await Promise.all(
        body.events.map(async (eventRecord) => {
          const photos = await loadPhotos(eventRecord.id);
          return [eventRecord.id, photos] as const;
        }),
      );

      setEvents(body.events);
      setPhotosByEvent(Object.fromEntries(photoEntries));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to load events.",
      );
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    void loadEvents();
  }, []);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const trimmedTitle = title.trim();

    if (!trimmedTitle) {
      setError("Enter an event title.");
      return;
    }

    setIsCreating(true);
    setError(null);

    try {
      const response = await fetch("/api/events", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          title: trimmedTitle,
        }),
      });

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const body = (await response.json()) as CreateEventResponse;

      setEvents((currentEvents) => [body.event, ...currentEvents]);
      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [body.event.id]: [],
      }));
      setTitle("");
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to create the event.",
      );
    } finally {
      setIsCreating(false);
    }
  }

  async function handlePhotoSelection(
    eventId: string,
    changeEvent: ChangeEvent<HTMLInputElement>,
  ): Promise<void> {
    const file = changeEvent.currentTarget.files?.[0];

    // Allow selecting the same file again after an error.
    changeEvent.currentTarget.value = "";

    if (!file) {
      return;
    }

    const isJpeg =
      file.type === "image/jpeg" ||
      file.name.toLowerCase().endsWith(".jpg") ||
      file.name.toLowerCase().endsWith(".jpeg");

    if (!isJpeg) {
      setError("PickPic currently supports JPG and JPEG files only.");
      return;
    }

    if (file.size > MAX_JPEG_BYTES) {
      setError("The JPEG must be 25 MB or smaller.");
      return;
    }

    setUploadingEventId(eventId);
    setError(null);

    try {
      const response = await fetch(
        `/api/events/${encodeURIComponent(eventId)}/photos`,
        {
          method: "POST",
          headers: {
            "Content-Type": "image/jpeg",
            "X-File-Name": encodeURIComponent(file.name),
          },
          body: file,
        },
      );

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const body = (await response.json()) as CreatePhotoResponse;

      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [eventId]: [body.photo, ...(currentPhotos[eventId] ?? [])],
      }));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to upload the photo.",
      );
    } finally {
      setUploadingEventId(null);
    }
  }

  async function handleDeletePhoto(
    eventId: string,
    photo: PhotoRecord,
  ): Promise<void> {
    const shouldDelete = window.confirm(
      `Delete "${photo.originalFilename}" from this event?`,
    );

    if (!shouldDelete) {
      return;
    }

    setDeletingPhotoId(photo.id);
    setError(null);

    try {
      const response = await fetch(
        `/api/photos/${encodeURIComponent(photo.id)}`,
        {
          method: "DELETE",
        },
      );

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [eventId]: (currentPhotos[eventId] ?? []).filter(
          (currentPhoto) => currentPhoto.id !== photo.id,
        ),
      }));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to delete the photo.",
      );
    } finally {
      setDeletingPhotoId(null);
    }
  }

  async function copyShareLink(eventRecord: EventRecord): Promise<void> {
    const shareUrl = `${window.location.origin}/g/${eventRecord.shareToken}`;

    try {
      await navigator.clipboard.writeText(shareUrl);
      setCopiedEventId(eventRecord.id);

      window.setTimeout(() => {
        setCopiedEventId((currentId) =>
          currentId === eventRecord.id ? null : currentId,
        );
      }, 2000);
    } catch {
      setError("Unable to copy the gallery link.");
    }
  }

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label="PickPic home">
          PickPic
        </a>

        <span className="environment-badge">Local development</span>
      </header>

      <main className="dashboard">
        <section className="hero">
          <p className="eyebrow">Photographer dashboard</p>
          <h1>Turn your photos into a gallery your friends can help curate.</h1>
          <p className="hero-description">
            Create an event, upload JPG previews, and prepare a gallery link for
            sharing.
          </p>
        </section>

        <section className="panel create-panel">
          <div>
            <p className="section-label">New gallery</p>
            <h2>Create an event</h2>
            <p className="section-description">
              Use a trip, party, or shoot name that your friends will recognize.
            </p>
          </div>

          <form className="create-form" onSubmit={handleSubmit}>
            <label htmlFor="event-title">Event title</label>

            <div className="form-row">
              <input
                id="event-title"
                name="event-title"
                type="text"
                value={title}
                onChange={(event) => setTitle(event.target.value)}
                placeholder="Summer barbecue"
                maxLength={120}
                disabled={isCreating}
                autoComplete="off"
              />

              <button type="submit" disabled={isCreating || !title.trim()}>
                {isCreating ? "Creating…" : "Create event"}
              </button>
            </div>

            <span className="character-count">{title.length}/120</span>
          </form>
        </section>

        {error && (
          <div className="error-message" role="alert">
            <span>{error}</span>
            <button type="button" onClick={() => setError(null)}>
              Dismiss
            </button>
          </div>
        )}

        <section className="events-section">
          <div className="section-heading">
            <div>
              <p className="section-label">Your galleries</p>
              <h2>Events</h2>
            </div>

            <button
              className="secondary-button"
              type="button"
              onClick={() => void loadEvents()}
              disabled={isLoading}
            >
              {isLoading ? "Refreshing…" : "Refresh"}
            </button>
          </div>

          <div aria-live="polite">
            {isLoading && events.length === 0 ? (
              <div className="empty-state">
                <h3>Loading events…</h3>
              </div>
            ) : events.length === 0 ? (
              <div className="empty-state">
                <h3>No events yet</h3>
                <p>Create your first PickPic gallery above.</p>
              </div>
            ) : (
              <div className="event-grid">
                {events.map((eventRecord) => {
                  const shareUrl = `${window.location.origin}/g/${eventRecord.shareToken}`;
                  const wasCopied = copiedEventId === eventRecord.id;
                  const isUploading = uploadingEventId === eventRecord.id;
                  const photos = photosByEvent[eventRecord.id] ?? [];

                  return (
                    <article className="event-card" key={eventRecord.id}>
                      <div className="event-card-header">
                        <span className="status-badge">
                          {eventRecord.status}
                        </span>

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
                          <dd>0</dd>
                        </div>
                      </dl>

                      <div className="upload-controls">
                        <input
                          className="visually-hidden"
                          id={`photo-upload-${eventRecord.id}`}
                          type="file"
                          accept="image/jpeg,.jpg,.jpeg"
                          disabled={isUploading}
                          onChange={(event) =>
                            void handlePhotoSelection(eventRecord.id, event)
                          }
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

                        <span className="upload-help">
                          Maximum file size: 25 MB
                        </span>
                      </div>

                      {photos.length > 0 && (
                        <div className="photo-list">
                          {photos.map((photo) => (
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

                                <small>{formatFileSize(photo.byteSize)}</small>

                                <button
                                  className="delete-photo-button"
                                  type="button"
                                  disabled={deletingPhotoId === photo.id}
                                  onClick={() =>
                                    void handleDeletePhoto(
                                      eventRecord.id,
                                      photo,
                                    )
                                  }
                                >
                                  {deletingPhotoId === photo.id
                                    ? "Deleting…"
                                    : "Delete"}
                                </button>
                              </div>
                            </article>
                          ))}
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
                })}
              </div>
            )}
          </div>
        </section>
      </main>
    </div>
  );
}

function App() {
  const galleryMatch = window.location.pathname.match(/^\/g\/([^/]+)\/?$/);

  if (galleryMatch) {
    return <GalleryPage shareToken={decodeURIComponent(galleryMatch[1])} />;
  }

  return <DashboardPage />;
}

export default App;
