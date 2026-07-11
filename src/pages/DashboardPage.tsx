import {
  useCallback,
  useEffect,
  useState,
  type ChangeEvent,
  type FormEvent,
} from "react";
import EditingQueue from "../components/EditingQueue";
import type {
  EventRecord,
  FinalPhotoRecord,
  PhotoRecord,
  PhotoWorkflowStatus,
  UploadBatchProgress,
} from "../types";
import EventCard from "../components/EventCard";
import { fetchJson } from "../api";
import { extractPhotoMetadata } from "../photoMetadata";

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
  duplicate: boolean;
  photo?: PhotoRecord;
  existingPhotoId?: string;
  duplicateVariant?: "original" | "final";
}

interface UploadFinalPhotoResponse {
  photoId: string;
  workflowStatus: PhotoWorkflowStatus;
  heartCount: number;
  finalPhoto: FinalPhotoRecord;
}

const MAX_JPEG_BYTES = 25 * 1024 * 1024;
const MAX_FINAL_JPEG_BYTES = 50 * 1024 * 1024;

async function loadPhotos(eventId: string): Promise<PhotoRecord[]> {
  const body = await fetchJson<PhotosResponse>(
    `/api/admin/events/${encodeURIComponent(eventId)}/photos`,
  );

  return body.photos;
}

async function calculateFileSha256(file: File): Promise<string> {
  const fileData = await file.arrayBuffer();

  const digest = await crypto.subtle.digest("SHA-256", fileData);

  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
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
  const [clearingHeartsPhotoId, setClearingHeartsPhotoId] = useState<
    string | null
  >(null);
  const [updatingWorkflowPhotoId, setUpdatingWorkflowPhotoId] = useState<
    string | null
  >(null);
  const [uploadingFinalPhotoId, setUploadingFinalPhotoId] = useState<
    string | null
  >(null);
  const [uploadProgressByEvent, setUploadProgressByEvent] = useState<
    Record<string, UploadBatchProgress>
  >({});

  const loadEvents = useCallback(async (): Promise<void> => {
    setIsLoading(true);
    setError(null);

    try {
      const body = await fetchJson<EventsResponse>("/api/admin/events");

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
  }, []);

  useEffect(() => {
    void loadEvents();
  }, [loadEvents]);

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
      const body = await fetchJson<CreateEventResponse>("/api/admin/events", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          title: trimmedTitle,
        }),
      });

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
    const selectedFiles = Array.from(changeEvent.currentTarget.files ?? []);

    changeEvent.currentTarget.value = "";

    if (selectedFiles.length === 0) {
      return;
    }

    const validFiles: File[] = [];
    let failedCount = 0;

    for (const file of selectedFiles) {
      const lowerFilename = file.name.toLowerCase();

      const isJpeg =
        file.type === "image/jpeg" ||
        lowerFilename.endsWith(".jpg") ||
        lowerFilename.endsWith(".jpeg");

      if (!isJpeg || file.size > MAX_JPEG_BYTES) {
        failedCount += 1;
        continue;
      }

      validFiles.push(file);
    }

    if (validFiles.length === 0) {
      setError(
        "No valid JPG files were selected. Files must be 25 MB or smaller.",
      );
      return;
    }

    let uploadedCount = 0;
    let skippedCount = 0;

    setUploadingEventId(eventId);
    setError(null);

    setUploadProgressByEvent((currentProgress) => ({
      ...currentProgress,
      [eventId]: {
        total: selectedFiles.length,
        processed: failedCount,
        uploaded: 0,
        skipped: 0,
        failed: failedCount,
        currentFilename: null,
      },
    }));

    for (const file of validFiles) {
      setUploadProgressByEvent((currentProgress) => ({
        ...currentProgress,
        [eventId]: {
          ...currentProgress[eventId],
          currentFilename: file.name,
        },
      }));

      try {
        const [sourceSha256, photoMetadata] = await Promise.all([
          calculateFileSha256(file),
          extractPhotoMetadata(file),
        ]);

        const headers = new Headers({
          "Content-Type": "image/jpeg",
          "X-File-Name": encodeURIComponent(file.name),
          "X-File-SHA256": sourceSha256,
        });

        if (photoMetadata.capturedAt) {
          headers.set("X-PickPic-Captured-At", photoMetadata.capturedAt);
        }

        if (
          photoMetadata.latitude !== null &&
          photoMetadata.longitude !== null
        ) {
          headers.set("X-PickPic-Latitude", photoMetadata.latitude.toString());

          headers.set(
            "X-PickPic-Longitude",
            photoMetadata.longitude.toString(),
          );
        }

        const body = await fetchJson<CreatePhotoResponse>(
          `/api/admin/events/${encodeURIComponent(eventId)}/photos`,
          {
            method: "POST",
            headers,
            body: file,
          },
        );

        if (body.duplicate) {
          skippedCount += 1;
        } else if (body.photo) {
          uploadedCount += 1;

          /*
           * Add each successful upload immediately so the
           * dashboard and public gallery can grow progressively.
           */
          setPhotosByEvent((currentPhotos) => ({
            ...currentPhotos,
            [eventId]: [body.photo!, ...(currentPhotos[eventId] ?? [])],
          }));
        } else {
          throw new Error("The upload response did not contain a photo.");
        }
      } catch (caughtError) {
        failedCount += 1;

        console.error(`Unable to upload ${file.name}:`, caughtError);
      } finally {
        setUploadProgressByEvent((currentProgress) => {
          const existingProgress = currentProgress[eventId];

          return {
            ...currentProgress,
            [eventId]: {
              ...existingProgress,
              processed: existingProgress.processed + 1,
              uploaded: uploadedCount,
              skipped: skippedCount,
              failed: failedCount,
              currentFilename: null,
            },
          };
        });
      }
    }

    setUploadingEventId(null);

    if (failedCount > 0) {
      setError(
        `${failedCount} ${
          failedCount === 1 ? "file was" : "files were"
        } not uploaded. Some files may be invalid, too large, or may have encountered an upload error.`,
      );
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
      await fetchJson<{ deletedPhotoId: string }>(
        `/api/admin/photos/${encodeURIComponent(photo.id)}`,
        {
          method: "DELETE",
        },
      );

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

  async function handleClearHearts(
    eventId: string,
    photo: PhotoRecord,
  ): Promise<void> {
    const shouldClear = window.confirm(
      `Clear all ${photo.heartCount} ${
        photo.heartCount === 1 ? "heart" : "hearts"
      } from "${photo.originalFilename}"?`,
    );

    if (!shouldClear) {
      return;
    }

    setClearingHeartsPhotoId(photo.id);
    setError(null);

    try {
      await fetchJson<{
        photoId: string;
        heartCount: number;
      }>(`/api/admin/photos/${encodeURIComponent(photo.id)}/hearts`, {
        method: "DELETE",
      });

      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [eventId]: (currentPhotos[eventId] ?? []).map((currentPhoto) =>
          currentPhoto.id === photo.id
            ? {
                ...currentPhoto,
                heartCount: 0,
              }
            : currentPhoto,
        ),
      }));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to clear the hearts.",
      );
    } finally {
      setClearingHeartsPhotoId(null);
    }
  }

  async function handleSetPhotoWorkflowStatus(
    eventId: string,
    photo: PhotoRecord,
    workflowStatus: PhotoWorkflowStatus,
  ): Promise<void> {
    if (workflowStatus === "final" && photo.heartCount > 0) {
      const shouldContinue = window.confirm(
        `Mark "${photo.originalFilename}" as final? ` +
          `This will clear its ${photo.heartCount} current ` +
          `${photo.heartCount === 1 ? "heart" : "hearts"}.`,
      );

      if (!shouldContinue) {
        return;
      }
    }

    setUpdatingWorkflowPhotoId(photo.id);
    setError(null);

    try {
      const response = await fetchJson<{
        photoId: string;
        workflowStatus: PhotoWorkflowStatus;
        heartCount: number;
      }>(`/api/photos/${encodeURIComponent(photo.id)}/workflow`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          status: workflowStatus,
        }),
      });

      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [eventId]: (currentPhotos[eventId] ?? []).map((currentPhoto) =>
          currentPhoto.id === photo.id
            ? {
                ...currentPhoto,
                workflowStatus: response.workflowStatus,
                heartCount: response.heartCount,
              }
            : currentPhoto,
        ),
      }));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to update the photo status.",
      );
    } finally {
      setUpdatingWorkflowPhotoId(null);
    }
  }

  async function handleFinalPhotoSelection(
    eventId: string,
    photo: PhotoRecord,
    changeEvent: ChangeEvent<HTMLInputElement>,
  ): Promise<void> {
    const file = changeEvent.currentTarget.files?.[0];

    changeEvent.currentTarget.value = "";

    if (!file) {
      return;
    }

    const isJpeg =
      file.type === "image/jpeg" ||
      file.name.toLowerCase().endsWith(".jpg") ||
      file.name.toLowerCase().endsWith(".jpeg");

    if (!isJpeg) {
      setError("PickPic currently supports JPG and JPEG final files only.");
      return;
    }

    if (file.size > MAX_FINAL_JPEG_BYTES) {
      setError("The final JPEG must be 50 MB or smaller.");
      return;
    }

    if (photo.finalPhoto) {
      const shouldReplace = window.confirm(
        `Replace the current final image for ` + `"${photo.originalFilename}"?`,
      );

      if (!shouldReplace) {
        return;
      }
    }

    setUploadingFinalPhotoId(photo.id);
    setError(null);

    try {
      const finalSha256 = await calculateFileSha256(file);
      const response = await fetchJson<UploadFinalPhotoResponse>(
        `/api/admin/photos/${encodeURIComponent(photo.id)}/final`,
        {
          method: "PUT",
          headers: {
            "Content-Type": "image/jpeg",
            "X-File-Name": encodeURIComponent(file.name),
            "X-File-SHA256": finalSha256,
          },
          body: file,
        },
      );

      setPhotosByEvent((currentPhotos) => ({
        ...currentPhotos,
        [eventId]: (currentPhotos[eventId] ?? []).map((currentPhoto) =>
          currentPhoto.id === photo.id
            ? {
                ...currentPhoto,
                workflowStatus: response.workflowStatus,
                heartCount: response.heartCount,
                finalPhoto: response.finalPhoto,
              }
            : currentPhoto,
        ),
      }));
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to upload the final image.",
      );
    } finally {
      setUploadingFinalPhotoId(null);
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

        <EditingQueue
          events={events}
          photosByEvent={photosByEvent}
          updatingWorkflowPhotoId={updatingWorkflowPhotoId}
          clearingHeartsPhotoId={clearingHeartsPhotoId}
          onSetPhotoWorkflowStatus={handleSetPhotoWorkflowStatus}
          onClearHearts={handleClearHearts}
          uploadingFinalPhotoId={uploadingFinalPhotoId}
          onFinalPhotoSelection={handleFinalPhotoSelection}
        />

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
                  const editRequestCount = photos.filter(
                    (photo) => photo.heartCount > 0,
                  ).length;

                  return (
                    <EventCard
                      key={eventRecord.id}
                      eventRecord={eventRecord}
                      shareUrl={shareUrl}
                      wasCopied={wasCopied}
                      isUploading={isUploading}
                      editRequestCount={editRequestCount}
                      photos={photos}
                      handlePhotoSelection={handlePhotoSelection}
                      handleDeletePhoto={handleDeletePhoto}
                      copyShareLink={copyShareLink}
                      deletingPhotoId={deletingPhotoId}
                      clearingHeartsPhotoId={clearingHeartsPhotoId}
                      handleClearHearts={handleClearHearts}
                      updatingWorkflowPhotoId={updatingWorkflowPhotoId}
                      handleSetPhotoWorkflowStatus={
                        handleSetPhotoWorkflowStatus
                      }
                      uploadingFinalPhotoId={uploadingFinalPhotoId}
                      handleFinalPhotoSelection={handleFinalPhotoSelection}
                      uploadProgress={
                        uploadProgressByEvent[eventRecord.id] ?? null
                      }
                      uploadsDisabled={uploadingEventId !== null}
                    />
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

export default DashboardPage;
