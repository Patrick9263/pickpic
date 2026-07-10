import { useEffect, useState, type FormEvent } from "react";
import "../styles/GalleryPage.css";
import type { PhotoCommentRecord, PhotoRecord } from "../types";

interface GalleryEvent {
  title: string;
  status: string;
  createdAt: string;
}

interface GalleryResponse {
  event: GalleryEvent;
  photos: PhotoRecord[];
}

interface HeartResponse {
  hearted: boolean;
  heartCount: number;
}

interface CommentResponse {
  comment: PhotoCommentRecord;
}

interface ErrorResponse {
  error?: string;
}

interface GalleryPageProps {
  shareToken: string;
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

async function getErrorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as ErrorResponse;

    if (body.error) {
      return body.error;
    }
  } catch {
    // Use the fallback message below.
  }

  return `Request failed with status ${response.status}.`;
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

  useEffect(() => {
    let isCancelled = false;

    async function loadGallery(): Promise<void> {
      setIsLoading(true);
      setLoadError(null);

      try {
        const response = await fetch(
          `/api/galleries/${encodeURIComponent(shareToken)}`,
          {
            headers: {
              "X-PickPic-Visitor": visitorToken,
            },
          },
        );

        if (!response.ok) {
          throw new Error(await getErrorMessage(response));
        }

        const body = (await response.json()) as GalleryResponse;

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

  async function toggleHeart(photo: PhotoRecord): Promise<void> {
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

      const response = await fetch(
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

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const body = (await response.json()) as HeartResponse;

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
      const response = await fetch(
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

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const responseBody = (await response.json()) as CommentResponse;

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

  async function editComment(comment: PhotoCommentRecord): Promise<void> {
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
      const response = await fetch(
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

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const responseBody = (await response.json()) as CommentResponse;

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

  async function deleteComment(comment: PhotoCommentRecord): Promise<void> {
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
      const response = await fetch(
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

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

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
  }

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
            Heart a photo to request that the photographer edit it.
          </p>
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
          <div className="gallery-grid">
            {gallery.photos.map((photo) => {
              const isToggling = togglingPhotoId === photo.id;

              return (
                <article className="gallery-photo-card" key={photo.id}>
                  <button
                    className="gallery-photo-button"
                    type="button"
                    onClick={() => setSelectedPhotoId(photo.id)}
                    aria-label={`Open ${photo.originalFilename}`}
                  >
                    <img
                      src={photo.imageUrl}
                      alt={photo.originalFilename}
                      loading="lazy"
                    />
                  </button>

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
              src={selectedPhoto.imageUrl}
              alt={selectedPhoto.originalFilename}
            />

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
