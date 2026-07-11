import { useEffect, useMemo, useState, type FormEvent } from "react";
import type {
  EventStatus,
  GalleryPhotoRecord,
  ViewerPhotoCommentRecord,
} from "../types";
import { fetchJson } from "../api";
import "../styles/GalleryPage.css";

interface GalleryEvent {
  title: string;
  status: EventStatus;
  createdAt: string;
}

interface GalleryResponse {
  event: GalleryEvent;
  photos: GalleryPhotoRecord[];
}

interface HeartResponse {
  hearted: boolean;
  heartCount: number;
}

interface CommentResponse {
  comment: ViewerPhotoCommentRecord;
}

interface GalleryPageProps {
  shareToken: string;
}

type PhotoVersion = "original" | "final";

type GalleryGrouping = "all" | "day" | "location";

interface GalleryPhotoGroup {
  key: string;
  label: string;
  photos: GalleryPhotoRecord[];
  mapUrl: string | null;
}

const VISITOR_TOKEN_KEY = "pickpic-visitor-token";
const DISPLAY_NAME_KEY = "pickpic-display-name";

function getOrCreateVisitorToken(): string {
  const storedToken = window.localStorage.getItem(VISITOR_TOKEN_KEY);

  if (storedToken) {
    return storedToken;
  }

  const token = crypto.randomUUID();

  window.localStorage.setItem(VISITOR_TOKEN_KEY, token);

  return token;
}

function formatDayGroupLabel(dayKey: string): string {
  if (dayKey === "unknown") {
    return "Date unavailable";
  }

  const [year, month, day] = dayKey.split("-").map(Number);

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "full",
  }).format(new Date(year, month - 1, day));
}

function comparePhotos(
  first: GalleryPhotoRecord,
  second: GalleryPhotoRecord,
): number {
  if (first.capturedAt && second.capturedAt) {
    const captureDateComparison = first.capturedAt.localeCompare(
      second.capturedAt,
    );

    if (captureDateComparison !== 0) {
      return captureDateComparison;
    }
  } else if (first.capturedAt) {
    // Photos with capture metadata come before those without it.
    return -1;
  } else if (second.capturedAt) {
    return 1;
  }

  const filenameComparison = first.originalFilename.localeCompare(
    second.originalFilename,
    undefined,
    {
      numeric: true,
      sensitivity: "base",
    },
  );

  if (filenameComparison !== 0) {
    return filenameComparison;
  }

  // Final fallback if filenames are identical.
  return first.createdAt.localeCompare(second.createdAt);
}

function buildGalleryGroups(
  photos: GalleryPhotoRecord[],
  grouping: GalleryGrouping,
): GalleryPhotoGroup[] {
  const sortedPhotos = [...photos].sort(comparePhotos);

  if (grouping === "all") {
    return [
      {
        key: "all",
        label: "All photos",
        photos: sortedPhotos,
        mapUrl: null,
      },
    ];
  }

  const groups = new Map<string, GalleryPhotoRecord[]>();

  for (const photo of sortedPhotos) {
    let key: string;

    if (grouping === "day") {
      key = photo.capturedAt?.slice(0, 10) ?? "unknown";
    } else if (photo.latitude !== null && photo.longitude !== null) {
      /*
       * Public coordinates are already rounded by the
       * Worker, creating approximate nearby-area groups.
       */
      key = `${photo.latitude.toFixed(2)},` + photo.longitude.toFixed(2);
    } else {
      key = "unknown";
    }

    const groupPhotos = groups.get(key) ?? [];

    groupPhotos.push(photo);
    groups.set(key, groupPhotos);
  }

  const results = Array.from(groups.entries(), ([key, groupPhotos]) => {
    if (grouping === "day") {
      return {
        key,
        label: formatDayGroupLabel(key),
        photos: groupPhotos,
        mapUrl: null,
      };
    }

    if (key === "unknown") {
      return {
        key,
        label: "Location unavailable",
        photos: groupPhotos,
        mapUrl: null,
      };
    }

    const [latitudeText, longitudeText] = key.split(",");

    return {
      key,
      label: `Near ${latitudeText}, ` + longitudeText,
      photos: groupPhotos,
      mapUrl: "https://www.google.com/maps?q=" + encodeURIComponent(key),
    };
  });

  return results.sort((first, second) => {
    if (first.key === "unknown") {
      return 1;
    }

    if (second.key === "unknown") {
      return -1;
    }

    return first.key.localeCompare(second.key);
  });
}

function GalleryPage({ shareToken }: GalleryPageProps) {
  const [visitorToken] = useState(getOrCreateVisitorToken);
  const [displayName, setDisplayName] = useState(
    () => window.localStorage.getItem(DISPLAY_NAME_KEY) ?? "",
  );
  const [gallery, setGallery] = useState<GalleryResponse | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [togglingPhotoId, setTogglingPhotoId] = useState<string | null>(null);
  const [commentText, setCommentText] = useState("");
  const [isSubmittingComment, setIsSubmittingComment] = useState(false);
  const [commentActionId, setCommentActionId] = useState<string | null>(null);
  const selectedPhoto =
    gallery?.photos.find((photo) => photo.id === selectedPhotoId) ?? null;
  const [selectedVersion, setSelectedVersion] =
    useState<PhotoVersion>("original");
  const [grouping, setGrouping] = useState<GalleryGrouping>("all");
  const photoGroups = useMemo(
    () => (gallery ? buildGalleryGroups(gallery.photos, grouping) : []),
    [gallery, grouping],
  );

  useEffect(() => {
    let isCancelled = false;

    async function loadGallery(): Promise<void> {
      setIsLoading(true);
      setLoadError(null);

      try {
        const body = await fetchJson<GalleryResponse>(
          `/api/galleries/${encodeURIComponent(shareToken)}`,
          {
            headers: {
              "X-PickPic-Visitor": visitorToken,
            },
          },
        );

        if (!isCancelled) {
          setGallery(body);
        }
      } catch (caughtError) {
        if (!isCancelled) {
          setLoadError(
            caughtError instanceof Error
              ? caughtError.message
              : "Unable to load this gallery.",
          );
        }
      } finally {
        if (!isCancelled) {
          setIsLoading(false);
        }
      }
    }

    void loadGallery();

    return () => {
      isCancelled = true;
    };
  }, [shareToken, visitorToken]);

  async function resolveDisplayName(): Promise<string | null> {
    const existingName = displayName.trim();

    if (existingName) {
      return existingName;
    }

    const enteredName = window.prompt("What should the photographer call you?");

    if (enteredName === null) {
      return null;
    }

    const resolvedName = enteredName.trim();

    if (resolvedName.length === 0 || resolvedName.length > 80) {
      setActionError("Your name must be between 1 and 80 characters.");

      return null;
    }

    window.localStorage.setItem(DISPLAY_NAME_KEY, resolvedName);

    setDisplayName(resolvedName);

    return resolvedName;
  }

  async function toggleHeart(photo: GalleryPhotoRecord): Promise<void> {
    let resolvedDisplayName = displayName.trim();

    if (!photo.viewerHearted) {
      const resolvedName = await resolveDisplayName();

      if (!resolvedName) {
        return;
      }

      resolvedDisplayName = resolvedName;
    }

    setTogglingPhotoId(photo.id);
    setActionError(null);

    try {
      const method = photo.viewerHearted ? "DELETE" : "PUT";

      const body = await fetchJson<HeartResponse>(
        `/api/galleries/${encodeURIComponent(
          shareToken,
        )}/photos/${encodeURIComponent(photo.id)}/heart`,
        {
          method,
          headers: {
            "X-PickPic-Visitor": visitorToken,
            ...(method === "PUT"
              ? {
                  "Content-Type": "application/json",
                }
              : {}),
          },
          body:
            method === "PUT"
              ? JSON.stringify({
                  displayName: resolvedDisplayName,
                })
              : undefined,
        },
      );

      setGallery((currentGallery) => {
        if (!currentGallery) {
          return currentGallery;
        }

        return {
          ...currentGallery,
          photos: currentGallery.photos.map((currentPhoto) =>
            currentPhoto.id === photo.id
              ? {
                  ...currentPhoto,
                  viewerHearted: body.hearted,
                  heartCount: body.heartCount,
                }
              : currentPhoto,
          ),
        };
      });
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to update this edit request.",
      );
    } finally {
      setTogglingPhotoId(null);
    }
  }

  async function submitComment(
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> {
    event.preventDefault();

    if (!selectedPhoto) {
      return;
    }

    const trimmedComment = commentText.trim();

    if (trimmedComment.length === 0 || trimmedComment.length > 1000) {
      setActionError("Your comment must be between 1 and 1000 characters.");

      return;
    }

    const resolvedDisplayName = await resolveDisplayName();

    if (!resolvedDisplayName) {
      return;
    }

    setIsSubmittingComment(true);
    setActionError(null);

    try {
      const responseBody = await fetchJson<CommentResponse>(
        `/api/galleries/${encodeURIComponent(
          shareToken,
        )}/photos/${encodeURIComponent(selectedPhoto.id)}/comments`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-PickPic-Visitor": visitorToken,
          },
          body: JSON.stringify({
            displayName: resolvedDisplayName,
            body: trimmedComment,
          }),
        },
      );

      setGallery((currentGallery) => {
        if (!currentGallery) {
          return currentGallery;
        }

        return {
          ...currentGallery,
          photos: currentGallery.photos.map((photo) =>
            photo.id === selectedPhoto.id
              ? {
                  ...photo,
                  comments: [...photo.comments, responseBody.comment],
                }
              : photo,
          ),
        };
      });

      setCommentText("");
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to add your comment.",
      );
    } finally {
      setIsSubmittingComment(false);
    }
  }

  async function editComment(comment: ViewerPhotoCommentRecord): Promise<void> {
    if (!selectedPhoto || !comment.viewerOwned) {
      return;
    }

    const enteredBody = window.prompt("Edit your comment:", comment.body);

    if (enteredBody === null) {
      return;
    }

    const body = enteredBody.trim();

    if (body.length === 0 || body.length > 1000) {
      setActionError("Your comment must be between 1 and 1000 characters.");

      return;
    }

    setCommentActionId(comment.id);
    setActionError(null);

    try {
      const responseBody = await fetchJson<CommentResponse>(
        `/api/galleries/${encodeURIComponent(
          shareToken,
        )}/photos/${encodeURIComponent(
          selectedPhoto.id,
        )}/comments/${encodeURIComponent(comment.id)}`,
        {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            "X-PickPic-Visitor": visitorToken,
          },
          body: JSON.stringify({ body }),
        },
      );

      setGallery((currentGallery) => {
        if (!currentGallery) {
          return currentGallery;
        }

        return {
          ...currentGallery,
          photos: currentGallery.photos.map((photo) =>
            photo.id === selectedPhoto.id
              ? {
                  ...photo,
                  comments: photo.comments.map((currentComment) =>
                    currentComment.id === comment.id
                      ? responseBody.comment
                      : currentComment,
                  ),
                }
              : photo,
          ),
        };
      });
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to edit your comment.",
      );
    } finally {
      setCommentActionId(null);
    }
  }

  async function deleteComment(
    comment: ViewerPhotoCommentRecord,
  ): Promise<void> {
    if (!selectedPhoto || !comment.viewerOwned) {
      return;
    }

    const shouldDelete = window.confirm("Delete this comment?");

    if (!shouldDelete) {
      return;
    }

    setCommentActionId(comment.id);
    setActionError(null);

    try {
      await fetchJson<{
        deletedCommentId: string;
      }>(
        `/api/galleries/${encodeURIComponent(
          shareToken,
        )}/photos/${encodeURIComponent(
          selectedPhoto.id,
        )}/comments/${encodeURIComponent(comment.id)}`,
        {
          method: "DELETE",
          headers: {
            "X-PickPic-Visitor": visitorToken,
          },
        },
      );

      setGallery((currentGallery) => {
        if (!currentGallery) {
          return currentGallery;
        }

        return {
          ...currentGallery,
          photos: currentGallery.photos.map((photo) =>
            photo.id === selectedPhoto.id
              ? {
                  ...photo,
                  comments: photo.comments.filter(
                    (currentComment) => currentComment.id !== comment.id,
                  ),
                }
              : photo,
          ),
        };
      });
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to delete your comment.",
      );
    } finally {
      setCommentActionId(null);
    }
  }

  function closeLightbox(): void {
    setSelectedPhotoId(null);
    setCommentText("");
    setActionError(null);
    setSelectedVersion("original");
  }

  function openPhoto(photo: GalleryPhotoRecord): void {
    setSelectedPhotoId(photo.id);
    setSelectedVersion(photo.finalPhoto ? "final" : "original");
  }
  const selectedImageUrl = selectedPhoto
    ? selectedVersion === "final" && selectedPhoto.finalPhoto
      ? selectedPhoto.finalPhoto.imageUrl
      : selectedPhoto.imageUrl
    : null;

  if (isLoading) {
    return (
      <main className="gallery-message">
        <span className="gallery-brand">PickPic</span>

        <h1>Loading gallery…</h1>
      </main>
    );
  }

  if (loadError || !gallery) {
    return (
      <main className="gallery-message">
        <a className="gallery-brand" href="/">
          PickPic
        </a>

        <h1>Gallery unavailable</h1>

        <p>{loadError ?? "This gallery could not be found."}</p>
      </main>
    );
  }

  return (
    <div className="public-gallery">
      <header className="gallery-header">
        <a className="gallery-brand" href="/">
          PickPic
        </a>

        <div className="gallery-heading">
          <p className="gallery-label">Shared gallery</p>

          <h1>{gallery.event.title}</h1>

          <p>
            {gallery.photos.length}{" "}
            {gallery.photos.length === 1 ? "photo" : "photos"}
          </p>

          <p className="gallery-instructions">
            Heart a photo to request an edit or another revision.
          </p>

          <div
            className="gallery-grouping-controls"
            role="group"
            aria-label="Group photos"
          >
            {(
              [
                ["all", "All"],
                ["day", "Day"],
                ["location", "Location"],
              ] as const
            ).map(([value, label]) => (
              <button
                key={value}
                type="button"
                className={grouping === value ? "gallery-grouping-active" : ""}
                aria-pressed={grouping === value}
                onClick={() => setGrouping(value)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      </header>

      <main className="gallery-content">
        {actionError && (
          <div className="gallery-action-error" role="alert">
            <span>{actionError}</span>

            <button type="button" onClick={() => setActionError(null)}>
              Dismiss
            </button>
          </div>
        )}

        {gallery.photos.length === 0 ? (
          <div className="gallery-empty">
            <h2>No photos yet</h2>

            <p>The photographer is still preparing this gallery.</p>
          </div>
        ) : (
          <div className="gallery-groups">
            {photoGroups.map((group) => (
              <section className="gallery-photo-group" key={group.key}>
                {grouping !== "all" && (
                  <header className="gallery-group-header">
                    <div>
                      <h2>{group.label}</h2>

                      <span>
                        {group.photos.length}{" "}
                        {group.photos.length === 1 ? "photo" : "photos"}
                      </span>
                    </div>

                    {group.mapUrl && (
                      <a href={group.mapUrl} target="_blank" rel="noreferrer">
                        View area
                      </a>
                    )}
                  </header>
                )}
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
                            photo.viewerHearted
                              ? "gallery-heart-button-active"
                              : ""
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
              </section>
            ))}
          </div>
        )}
      </main>

      {selectedPhoto && (
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
              ×
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
                      selectedVersion === "original"
                        ? "photo-version-active"
                        : ""
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
                  selectedPhoto.viewerHearted
                    ? "lightbox-heart-button-active"
                    : ""
                }`}
                type="button"
                disabled={togglingPhotoId === selectedPhoto.id}
                onClick={() => void toggleHeart(selectedPhoto)}
                aria-pressed={selectedPhoto.viewerHearted}
              >
                <span aria-hidden="true">♥</span>

                <span>
                  {selectedPhoto.viewerHearted
                    ? "Edit requested"
                    : "Request edit"}
                </span>

                <span>{selectedPhoto.heartCount}</span>
              </button>
            </div>

            <section className="photo-comments">
              <h2>Comments and edit notes</h2>

              {selectedPhoto.comments.length === 0 ? (
                <p className="no-comments">No comments yet.</p>
              ) : (
                <div className="comment-list">
                  {selectedPhoto.comments.map((comment) => (
                    <article key={comment.id}>
                      <div className="comment-heading">
                        <strong>{comment.displayName}</strong>

                        {comment.viewerOwned && (
                          <div className="comment-actions">
                            <button
                              type="button"
                              disabled={commentActionId === comment.id}
                              onClick={() => void editComment(comment)}
                            >
                              Edit
                            </button>

                            <button
                              type="button"
                              disabled={commentActionId === comment.id}
                              onClick={() => void deleteComment(comment)}
                            >
                              Delete
                            </button>
                          </div>
                        )}
                      </div>

                      <p>{comment.body}</p>

                      {comment.updatedAt !== comment.createdAt && (
                        <small>Edited</small>
                      )}
                    </article>
                  ))}
                </div>
              )}

              <form
                className="comment-form"
                onSubmit={(event) => void submitComment(event)}
              >
                <label htmlFor={`comment-${selectedPhoto.id}`}>
                  Leave a comment or edit note
                </label>

                <textarea
                  id={`comment-${selectedPhoto.id}`}
                  value={commentText}
                  onChange={(event) => setCommentText(event.target.value)}
                  maxLength={1000}
                  placeholder="For example: Can you remove the stain from my shirt?"
                  disabled={isSubmittingComment}
                />

                <div className="comment-form-footer">
                  <span>{commentText.length}/1000</span>

                  <button
                    type="submit"
                    disabled={
                      isSubmittingComment || commentText.trim().length === 0
                    }
                  >
                    {isSubmittingComment ? "Posting…" : "Post comment"}
                  </button>
                </div>
              </form>
            </section>
          </div>
        </div>
      )}
    </div>
  );
}

export default GalleryPage;
