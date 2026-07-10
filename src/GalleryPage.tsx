import { useEffect, useState } from "react";
import "./GalleryPage.css";

interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
}

interface GalleryEvent {
  title: string;
  status: string;
  createdAt: string;
}

interface GalleryResponse {
  event: GalleryEvent;
  photos: PhotoRecord[];
}

interface ErrorResponse {
  error?: string;
}

interface GalleryPageProps {
  shareToken: string;
}

async function getErrorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as ErrorResponse;

    if (body.error) {
      return body.error;
    }
  } catch {
    // Use the fallback below.
  }

  return `Request failed with status ${response.status}.`;
}

function GalleryPage({ shareToken }: GalleryPageProps) {
  const [gallery, setGallery] = useState<GalleryResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [selectedPhoto, setSelectedPhoto] = useState<PhotoRecord | null>(null);

  useEffect(() => {
    let isCancelled = false;

    async function loadGallery(): Promise<void> {
      setIsLoading(true);
      setError(null);

      try {
        const response = await fetch(
          `/api/galleries/${encodeURIComponent(shareToken)}`,
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
          setError(
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
  }, [shareToken]);

  if (isLoading) {
    return (
      <main className="gallery-message">
        <span className="gallery-brand">PickPic</span>
        <h1>Loading gallery…</h1>
      </main>
    );
  }

  if (error || !gallery) {
    return (
      <main className="gallery-message">
        <a className="gallery-brand" href="/">
          PickPic
        </a>
        <h1>Gallery unavailable</h1>
        <p>{error ?? "This gallery could not be found."}</p>
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
        </div>
      </header>

      <main className="gallery-content">
        {gallery.photos.length === 0 ? (
          <div className="gallery-empty">
            <h2>No photos yet</h2>
            <p>The photographer is still preparing this gallery.</p>
          </div>
        ) : (
          <div className="gallery-grid">
            {gallery.photos.map((photo) => (
              <button
                className="gallery-photo-button"
                type="button"
                key={photo.id}
                onClick={() => setSelectedPhoto(photo)}
                aria-label={`Open ${photo.originalFilename}`}
              >
                <img
                  src={photo.imageUrl}
                  alt={photo.originalFilename}
                  loading="lazy"
                />
              </button>
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
            onClick={() => setSelectedPhoto(null)}
            aria-label="Close image"
          />

          <div className="lightbox-content">
            <button
              className="lightbox-close"
              type="button"
              onClick={() => setSelectedPhoto(null)}
              aria-label="Close image"
            >
              x
            </button>

            <img
              src={selectedPhoto.imageUrl}
              alt={selectedPhoto.originalFilename}
            />

            <p>{selectedPhoto.originalFilename}</p>
          </div>
        </div>
      )}
    </div>
  );
}

export default GalleryPage;
