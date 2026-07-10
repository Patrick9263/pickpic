import { useEffect, useState, type FormEvent } from "react";
import "./App.css";

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

interface EventsResponse {
  events: EventRecord[];
}

interface CreateEventResponse {
  event: EventRecord;
}

interface ErrorResponse {
  error?: string;
}

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

function App() {
  const [events, setEvents] = useState<EventRecord[]>([]);
  const [title, setTitle] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copiedEventId, setCopiedEventId] = useState<string | null>(null);

  async function loadEvents(): Promise<void> {
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/events");

      if (!response.ok) {
        throw new Error(await getErrorMessage(response));
      }

      const body = (await response.json()) as EventsResponse;
      setEvents(body.events);
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
            Create an event now. Photo uploads, hearts, comments, and editing
            requests will be added next.
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
                          <dd>0</dd>
                        </div>

                        <div>
                          <dt>Edit requests</dt>
                          <dd>0</dd>
                        </div>
                      </dl>

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

export default App;
