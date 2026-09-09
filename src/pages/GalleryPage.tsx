import { downloadZip } from "client-zip";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";
import type {
  GalleryPhotoRecord,
  GalleryStatus,
  ViewerPhotoCommentRecord,
} from "../types";
import { fetchJson } from "../api";
import "../styles/GalleryPage.css";
import GalleryGrid from "../components/gallery/GalleryGrid";
import GalleryLightbox from "../components/gallery/GalleryLightbox";
import type { PhotoVersion } from "../components/gallery/types";
import {
  buildGalleryGroups,
  createArchiveFilename,
  createUniqueDownloadNames,
  formatApproximateByteSize,
  getDefaultPreviewUrl,
  getOrCreateVisitorToken,
  readStorageItem,
  selectPhotosById,
  writeStorageItem,
  type GalleryGrouping,
} from "./galleryHelpers";
interface GalleryEvent {
  title: string;
  status: GalleryStatus;
  createdAt: string;
  rawRequestsEnabled: boolean;
}

interface GalleryResponse {
  event: GalleryEvent;
  photos: GalleryPhotoRecord[];
}

interface HeartResponse {
  hearted: boolean;
  heartCount: number;
}

interface RawRequestResponse {
  requested: boolean;
}

interface CommentResponse {
  comment: ViewerPhotoCommentRecord;
}

interface GalleryPageProps {
  shareToken: string;
}

type GalleryFilter = "all" | "liked" | "finals";
const VISITOR_TOKEN_KEY = "pickpic-visitor-token";
const DISPLAY_NAME_KEY = "pickpic-display-name";

function GalleryPage({ shareToken }: GalleryPageProps) {
  const [visitorToken] = useState(() =>
    getOrCreateVisitorToken(
      () => window.localStorage,
      VISITOR_TOKEN_KEY,
      () => crypto.randomUUID(),
    ),
  );
  const [displayName, setDisplayName] = useState(
    () => readStorageItem(() => window.localStorage, DISPLAY_NAME_KEY) ?? "",
  );
  const [gallery, setGallery] = useState<GalleryResponse | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [downloadProgress, setDownloadProgress] = useState<{
    completed: number;
    total: number;
  } | null>(null);
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [togglingPhotoId, setTogglingPhotoId] = useState<string | null>(null);
  const [togglingRawRequestPhotoId, setTogglingRawRequestPhotoId] = useState<
    string | null
  >(null);
  const [commentText, setCommentText] = useState("");
  const [isSubmittingComment, setIsSubmittingComment] = useState(false);
  const [commentActionId, setCommentActionId] = useState<string | null>(null);
  const selectedPhoto =
    gallery?.photos.find((photo) => photo.id === selectedPhotoId) ?? null;
  const [selectedVersion, setSelectedVersion] =
    useState<PhotoVersion>("original");
  const [grouping, setGrouping] = useState<GalleryGrouping>("all");
  const [filter, setFilter] = useState<GalleryFilter>("all");
  const [isSelecting, setIsSelecting] = useState(false);
  const [selectedPhotoIds, setSelectedPhotoIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [retainedLikedPhotoId, setRetainedLikedPhotoId] = useState<
    string | null
  >(null);
  const lastVisiblePhotoIndexRef = useRef(0);
  const filteredPhotos = useMemo(() => {
    if (!gallery) {
      return [];
    }
    switch (filter) {
      case "liked":
        return gallery.photos.filter((photo) => photo.heartCount > 0);

      case "finals":
        return gallery.photos.filter((photo) => photo.finalPhoto !== null);

      default:
        return gallery.photos;
    }
  }, [filter, gallery]);

  const photoGroups = useMemo(
    () => buildGalleryGroups(filteredPhotos, grouping),
    [filteredPhotos, grouping],
  );
  const visiblePhotos = useMemo(
    () => photoGroups.flatMap((group) => group.photos),
    [photoGroups],
  );

  const downloadableVisiblePhotos = visiblePhotos;

  const allVisibleSelected =
    downloadableVisiblePhotos.length > 0 &&
    downloadableVisiblePhotos.every((photo) => selectedPhotoIds.has(photo.id));
  const selectedDownloadByteSize = useMemo(
    () =>
      selectPhotosById(gallery?.photos ?? [], selectedPhotoIds).reduce(
        (totalByteSize, photo) =>
          totalByteSize + (photo.finalPhoto?.byteSize ?? photo.byteSize),
        0,
      ),
    [selectedPhotoIds, gallery],
  );

  const priorityPhotoIds = useMemo(
    () => new Set(visiblePhotos.slice(0, 3).map((photo) => photo.id)),
    [visiblePhotos],
  );
  const interactionsEnabled = gallery?.event.status === "ready";
  const rawRequestsEnabled = gallery?.event.rawRequestsEnabled ?? false;
  const selectedPhotoIndex =
    selectedPhotoId === null
      ? -1
      : visiblePhotos.findIndex((photo) => photo.id === selectedPhotoId);
  const isRetainingSelectedLikedPhoto =
    selectedPhoto !== null &&
    selectedPhotoId === retainedLikedPhotoId &&
    selectedPhotoIndex < 0;
  const lightboxPhotoIndex =
    selectedPhotoIndex >= 0
      ? selectedPhotoIndex
      : isRetainingSelectedLikedPhoto
        ? Math.min(lastVisiblePhotoIndexRef.current, visiblePhotos.length)
        : -1;
  const lightboxPhotoCount =
    visiblePhotos.length + (isRetainingSelectedLikedPhoto ? 1 : 0);
  const previousPhoto = isRetainingSelectedLikedPhoto
    ? lightboxPhotoIndex > 0
      ? visiblePhotos[lightboxPhotoIndex - 1]
      : null
    : selectedPhotoIndex > 0
      ? visiblePhotos[selectedPhotoIndex - 1]
      : null;
  const nextPhoto = isRetainingSelectedLikedPhoto
    ? lightboxPhotoIndex < visiblePhotos.length
      ? visiblePhotos[lightboxPhotoIndex]
      : null
    : selectedPhotoIndex >= 0 && selectedPhotoIndex < visiblePhotos.length - 1
      ? visiblePhotos[selectedPhotoIndex + 1]
      : null;
  const canGoPrevious = previousPhoto !== null;
  const canGoNext = nextPhoto !== null;
  const previousPhotoImageUrl = previousPhoto
    ? getDefaultPreviewUrl(previousPhoto)
    : null;
  const nextPhotoImageUrl = nextPhoto ? getDefaultPreviewUrl(nextPhoto) : null;
  useEffect(() => {
    if (selectedPhotoIndex >= 0) {
      lastVisiblePhotoIndexRef.current = selectedPhotoIndex;
    }
  }, [selectedPhotoIndex]);

  useEffect(() => {
    if (
      selectedPhotoId === null ||
      selectedPhotoIndex >= 0 ||
      isRetainingSelectedLikedPhoto
    ) {
      return;
    }

    if (visiblePhotos.length === 0) {
      setSelectedPhotoId(null);
      setSelectedVersion("original");
      setCommentText("");
      return;
    }
    const replacementIndex = Math.min(
      lastVisiblePhotoIndexRef.current,
      visiblePhotos.length - 1,
    );
    const replacementPhoto = visiblePhotos[replacementIndex];

    setSelectedPhotoId(replacementPhoto.id);
    setSelectedVersion(replacementPhoto.finalPhoto ? "final" : "original");
    setCommentText("");
    setActionError(null);
  }, [
    isRetainingSelectedLikedPhoto,
    selectedPhotoId,
    selectedPhotoIndex,
    visiblePhotos,
  ]);
  useEffect(() => {
    const imageUrls = [previousPhotoImageUrl, nextPhotoImageUrl].filter(
      (imageUrl): imageUrl is string => imageUrl !== null,
    );

    for (const imageUrl of imageUrls) {
      const image = new Image();

      image.decoding = "async";
      image.src = imageUrl;
    }
  }, [previousPhotoImageUrl, nextPhotoImageUrl]);

  /*
   * Only the newest request may write state. The initial load and a background
   * refresh can overlap, and without this a slow earlier response would land
   * last and reinstate a stale gallery.
   */
  const galleryRequestIdRef = useRef(0);

  const loadGallery = useCallback(
    async (options: { silent: boolean }): Promise<void> => {
      const requestId = galleryRequestIdRef.current + 1;

      galleryRequestIdRef.current = requestId;

      /*
       * A silent refresh must not touch the spinner or the error banner: the
       * viewer is already looking at a usable gallery, so a failed refresh
       * should leave it exactly as it was rather than replacing it with an
       * error. The next refresh will pick the change up.
       */
      if (!options.silent) {
        setIsLoading(true);
        setLoadError(null);
      }

      try {
        const body = await fetchJson<GalleryResponse>(
          `/api/galleries/${encodeURIComponent(shareToken)}`,
          {
            headers: {
              "X-PickPic-Visitor": visitorToken,
            },
          },
        );

        if (galleryRequestIdRef.current === requestId) {
          setGallery(body);
        }
      } catch (caughtError) {
        if (!options.silent && galleryRequestIdRef.current === requestId) {
          setLoadError(
            caughtError instanceof Error
              ? caughtError.message
              : "Unable to load this gallery.",
          );
        }
      } finally {
        if (!options.silent && galleryRequestIdRef.current === requestId) {
          setIsLoading(false);
        }
      }
    },
    [shareToken, visitorToken],
  );

  useEffect(() => {
    void loadGallery({ silent: false });
  }, [loadGallery]);

  /*
   * Uploads are deliberately progressive and hearts arrive from other viewers,
   * so a tab opened during the event goes stale as it sits: proofs still
   * uploading never appear, finals never appear, other viewers' heart counts
   * never move, and -- because `interactionsEnabled` is derived from this
   * response -- a gallery closed since mount still looks open and lets the
   * viewer heart into a rejection.
   *
   * Viewers are mostly on phones, and a phone viewer does not reload; they
   * background the tab and come back to it. `visibilitychange` is therefore the
   * moment that matters, and it is preferable to polling, which would keep
   * hitting the worker for tabs nobody is looking at.
   */
  useEffect(() => {
    function handleVisibilityChange(): void {
      if (document.visibilityState === "visible") {
        void loadGallery({ silent: true });
      }
    }

    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [loadGallery]);
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

    writeStorageItem(() => window.localStorage, DISPLAY_NAME_KEY, resolvedName);

    setDisplayName(resolvedName);

    return resolvedName;
  }

  async function toggleHeart(photo: GalleryPhotoRecord): Promise<void> {
    if (!interactionsEnabled) {
      setActionError(
        "This gallery is closed and no longer accepts edit requests.",
      );
      return;
    }
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
      if (filter === "liked" && selectedPhotoId === photo.id) {
        if (body.heartCount === 0) {
          setRetainedLikedPhotoId(photo.id);
        } else {
          setRetainedLikedPhotoId((currentPhotoId) =>
            currentPhotoId === photo.id ? null : currentPhotoId,
          );
        }
      }

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

  async function toggleRawRequest(photo: GalleryPhotoRecord): Promise<void> {
    if (!interactionsEnabled) {
      setActionError(
        "This gallery is closed and no longer accepts RAW file requests.",
      );
      return;
    }
    let resolvedDisplayName = displayName.trim();
    if (!photo.viewerRequestedRaw) {
      const resolvedName = await resolveDisplayName();

      if (!resolvedName) {
        return;
      }

      resolvedDisplayName = resolvedName;
    }

    setTogglingRawRequestPhotoId(photo.id);
    setActionError(null);

    try {
      const method = photo.viewerRequestedRaw ? "DELETE" : "PUT";
      const body = await fetchJson<RawRequestResponse>(
        `/api/galleries/${encodeURIComponent(
          shareToken,
        )}/photos/${encodeURIComponent(photo.id)}/raw-request`,
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
                  viewerRequestedRaw: body.requested,
                }
              : currentPhoto,
          ),
        };
      });
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to update this RAW file request.",
      );
    } finally {
      setTogglingRawRequestPhotoId(null);
    }
  }
  async function submitComment(
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> {
    event.preventDefault();

    if (!interactionsEnabled) {
      setActionError("This gallery is closed and no longer accepts comments.");
      return;
    }

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
    if (!interactionsEnabled) {
      setActionError("Comments cannot be changed after the gallery is closed.");

      return;
    }
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
    if (!interactionsEnabled) {
      setActionError("Comments cannot be changed after the gallery is closed.");
      return;
    }
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
    const photoIdToRestore = selectedPhotoId;

    setRetainedLikedPhotoId(null);
    setSelectedPhotoId(null);
    setCommentText("");
    setActionError(null);
    setSelectedVersion("original");

    if (photoIdToRestore) {
      window.requestAnimationFrame(() => {
        const photoButton = document.querySelector<HTMLButtonElement>(
          `[data-gallery-photo-id="${photoIdToRestore}"]`,
        );

        photoButton?.focus();
      });
    }
  }
  function openPhoto(photo: GalleryPhotoRecord): void {
    setRetainedLikedPhotoId(null);
    setSelectedPhotoId(photo.id);

    setSelectedVersion(photo.finalPhoto ? "final" : "original");
  }

  function showLightboxPhoto(photo: GalleryPhotoRecord): void {
    setRetainedLikedPhotoId(null);
    setSelectedPhotoId(photo.id);
    setSelectedVersion(photo.finalPhoto ? "final" : "original");
    setCommentText("");
    setActionError(null);
  }
  function showPreviousPhoto(): void {
    if (!previousPhoto) {
      return;
    }

    showLightboxPhoto(previousPhoto);
  }

  function showNextPhoto(): void {
    if (!nextPhoto) {
      return;
    }

    showLightboxPhoto(nextPhoto);
  }

  function enterSelectionMode(): void {
    setSelectedPhotoId(null);
    setSelectedPhotoIds(new Set());
    setActionError(null);
    setIsSelecting(true);
  }
  function exitSelectionMode(): void {
    setSelectedPhotoIds(new Set());
    setActionError(null);
    setIsSelecting(false);
  }

  function togglePhotoSelection(photo: GalleryPhotoRecord): void {
    setSelectedPhotoIds((currentIds) => {
      const nextIds = new Set(currentIds);

      if (nextIds.has(photo.id)) {
        nextIds.delete(photo.id);
      } else {
        nextIds.add(photo.id);
      }

      return nextIds;
    });
  }
  function selectAllVisiblePhotos(): void {
    setSelectedPhotoIds(
      new Set(downloadableVisiblePhotos.map((photo) => photo.id)),
    );
  }

  function clearSelectedPhotos(): void {
    setSelectedPhotoIds(new Set());
  }

  async function downloadSelectedPhotos(): Promise<void> {
    if (!gallery || selectedPhotoIds.size === 0 || downloadProgress !== null) {
      if (selectedPhotoIds.size === 0) {
        setActionError("Select at least one photo to download.");
      }

      return;
    }
    const selectedPhotos = selectPhotosById(gallery.photos, selectedPhotoIds);

    if (selectedPhotos.length === 0) {
      setActionError("The selected photos are no longer available.");
      return;
    }

    const entryNames = createUniqueDownloadNames(
      selectedPhotos.map(
        (photo) => photo.finalPhoto?.originalFilename ?? photo.originalFilename,
      ),
    );

    setActionError(null);
    setDownloadProgress({ completed: 0, total: selectedPhotos.length });
    try {
      async function* createZipInputs() {
        for (const [index, photo] of selectedPhotos.entries()) {
          const downloadUrl = photo.finalPhoto?.imageUrl ?? photo.imageUrl;
          const downloadFilename =
            photo.finalPhoto?.originalFilename ?? photo.originalFilename;
          const downloadDate = photo.finalPhoto?.uploadedAt ?? photo.createdAt;

          const response = await fetch(downloadUrl, {
            cache: "no-store",
          });

          if (!response.ok || !response.body) {
            throw new Error(`Unable to download ${downloadFilename}.`);
          }
          yield {
            name: entryNames[index],
            lastModified: new Date(downloadDate),
            input: response.body,
          };

          setDownloadProgress({
            completed: index + 1,
            total: selectedPhotos.length,
          });
        }
      }
      /*
       * Build the archive in the viewer's browser instead of inside the
       * Cloudflare Worker. The Worker Free CPU allowance is too small for
       * calculating CRC-32 across a larger set of selected JPEGs,
       * which can terminate a streamed response and leave an invalid ZIP.
       */
      const zipBlob = await downloadZip(createZipInputs()).blob();
      const objectUrl = URL.createObjectURL(zipBlob);
      const link = document.createElement("a");
      link.href = objectUrl;
      link.download = createArchiveFilename(gallery.event.title);

      document.body.append(link);
      link.click();
      link.remove();

      window.setTimeout(() => URL.revokeObjectURL(objectUrl), 60_000);
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to create the ZIP download.",
      );
    } finally {
      setDownloadProgress(null);
    }
  }
  const selectedImageUrl = selectedPhoto
    ? selectedVersion === "final" && selectedPhoto.finalPhoto
      ? (selectedPhoto.finalPhoto.variants.preview?.imageUrl ??
        selectedPhoto.finalPhoto.imageUrl)
      : (selectedPhoto.variants.preview?.imageUrl ?? selectedPhoto.imageUrl)
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
            {filter === "all"
              ? `${gallery.photos.length} ${
                  gallery.photos.length === 1 ? "photo" : "photos"
                }`
              : `${filteredPhotos.length} of ${gallery.photos.length} photos`}
          </p>
          <p className="gallery-instructions">
            {interactionsEnabled
              ? "Heart a photo to request an edit or another revision."
              : "This gallery is closed. Photos and downloads remain available, but new edit requests and comments are disabled."}
          </p>

          <div className="gallery-toolbar">
            <div className="gallery-toolbar-section">
              <span className="gallery-toolbar-label">Show</span>
              <div
                className="gallery-filter-controls"
                aria-label="Filter gallery photos"
              >
                {(
                  [
                    ["all", "All"],
                    ["liked", "Liked"],
                    ["finals", "Finals"],
                  ] as const
                ).map(([value, label]) => (
                  <button
                    className={
                      filter === value ? "gallery-filter-active" : undefined
                    }
                    key={value}
                    type="button"
                    aria-pressed={filter === value}
                    onClick={() => setFilter(value)}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
            <div className="gallery-toolbar-section">
              <span className="gallery-toolbar-label">Group</span>
              <div
                className="gallery-grouping-controls"
                aria-label="Group gallery photos"
              >
                {(
                  [
                    ["all", "All"],
                    ["day", "Day"],
                    ["location", "Location"],
                  ] as const
                ).map(([value, label]) => (
                  <button
                    className={
                      grouping === value ? "gallery-grouping-active" : undefined
                    }
                    key={value}
                    type="button"
                    aria-pressed={grouping === value}
                    onClick={() => setGrouping(value)}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
            <button
              className={[
                "gallery-select-button",
                isSelecting ? "gallery-select-button-cancel" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              type="button"
              onClick={isSelecting ? exitSelectionMode : enterSelectionMode}
            >
              {isSelecting ? "Cancel" : "Select"}
            </button>
          </div>
        </div>
      </header>
      {!interactionsEnabled && (
        <div className="gallery-closed-banner" role="status">
          <strong>Gallery closed</strong>

          <span>You can continue viewing and downloading photos.</span>
        </div>
      )}

      <main className="gallery-content">
        {actionError && (
          <div className="gallery-action-error" role="alert">
            <span>{actionError}</span>
            <button type="button" onClick={() => setActionError(null)}>
              Dismiss
            </button>
          </div>
        )}

        {isSelecting && (
          <div className="gallery-selection-bar">
            <div className="gallery-selection-summary">
              <strong>
                {selectedPhotoIds.size}{" "}
                {selectedPhotoIds.size === 1 ? "photo" : "photos"} selected
              </strong>
              <span>
                {selectedDownloadByteSize > 0
                  ? `Approx. ${formatApproximateByteSize(selectedDownloadByteSize)} download`
                  : "Selected photos are ready to download."}
              </span>
            </div>
            <div className="gallery-selection-actions">
              <button
                className="gallery-select-all-button"
                type="button"
                disabled={downloadableVisiblePhotos.length === 0}
                onClick={
                  allVisibleSelected
                    ? clearSelectedPhotos
                    : selectAllVisiblePhotos
                }
              >
                {allVisibleSelected
                  ? "Clear selection"
                  : `Select all (${downloadableVisiblePhotos.length})`}
              </button>
              <button
                className="gallery-download-button"
                type="button"
                disabled={
                  selectedPhotoIds.size === 0 || downloadProgress !== null
                }
                onClick={() => void downloadSelectedPhotos()}
              >
                {downloadProgress
                  ? `Preparing ZIP (${downloadProgress.completed}/${downloadProgress.total})`
                  : `Download${
                      selectedPhotoIds.size > 0
                        ? ` (${selectedPhotoIds.size})`
                        : ""
                    }`}
              </button>
            </div>
          </div>
        )}
        {gallery.photos.length === 0 ? (
          <div className="gallery-empty">
            <h2>No photos yet</h2>
            <p>The photographer is still preparing this gallery.</p>
          </div>
        ) : filteredPhotos.length === 0 ? (
          <div className="gallery-empty">
            <h2>
              {filter === "liked" ? "No liked photos" : "No final photos"}
            </h2>
            <p>
              {filter === "liked"
                ? "No photos have been liked yet."
                : "The photographer has not uploaded any final photos yet."}
            </p>
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
                <GalleryGrid
                  group={group}
                  togglingPhotoId={togglingPhotoId}
                  openPhoto={openPhoto}
                  toggleHeart={toggleHeart}
                  togglingRawRequestPhotoId={togglingRawRequestPhotoId}
                  toggleRawRequest={toggleRawRequest}
                  rawRequestsEnabled={rawRequestsEnabled}
                  priorityPhotoIds={priorityPhotoIds}
                  interactionsEnabled={interactionsEnabled}
                  isSelecting={isSelecting}
                  selectedPhotoIds={selectedPhotoIds}
                  togglePhotoSelection={togglePhotoSelection}
                />
              </section>
            ))}
          </div>
        )}
      </main>
      {selectedPhoto && (
        <GalleryLightbox
          selectedPhoto={selectedPhoto}
          closeLightbox={closeLightbox}
          selectedImageUrl={selectedImageUrl}
          selectedVersion={selectedVersion}
          setSelectedVersion={setSelectedVersion}
          togglingPhotoId={togglingPhotoId}
          toggleHeart={toggleHeart}
          togglingRawRequestPhotoId={togglingRawRequestPhotoId}
          toggleRawRequest={toggleRawRequest}
          rawRequestsEnabled={rawRequestsEnabled}
          commentActionId={commentActionId}
          commentText={commentText}
          isSubmittingComment={isSubmittingComment}
          setCommentText={setCommentText}
          editComment={editComment}
          deleteComment={deleteComment}
          submitComment={submitComment}
          photoIndex={lightboxPhotoIndex}
          photoCount={lightboxPhotoCount}
          canGoPrevious={canGoPrevious}
          canGoNext={canGoNext}
          onPrevious={showPreviousPhoto}
          onNext={showNextPhoto}
          interactionsEnabled={interactionsEnabled}
        />
      )}
    </div>
  );
}
export default GalleryPage;
