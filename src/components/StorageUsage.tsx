import type { EventStorageRecord, StorageUsageRecord } from "../types";
import "../styles/StorageUsage.css";

interface StorageUsageProps {
  storage: StorageUsageRecord | null;
  isLoading: boolean;
  onRefresh: () => void;
}

// Decimal (1000-based), matching the iPad app's ByteCountFormatter(.file)
// output so the two faces show the same figure for the same bytes.
function formatStorageSize(byteSize: number): string {
  if (byteSize < 1000) {
    return `${byteSize} B`;
  }

  if (byteSize < 1000 * 1000) {
    return `${Math.round(byteSize / 1000)} KB`;
  }

  if (byteSize < 1000 * 1000 * 1000) {
    return `${(byteSize / (1000 * 1000)).toFixed(1)} MB`;
  }

  return `${(byteSize / (1000 * 1000 * 1000)).toFixed(2)} GB`;
}

function formatCount(value: number, noun: string): string {
  return `${value.toLocaleString()} ${noun}${value === 1 ? "" : "s"}`;
}

const PLAN_LABELS: Record<string, string> = {
  free: "Free",
  solo: "Solo",
  studio: "Studio",
};

function formatPlanLabel(plan: string): string {
  return PLAN_LABELS[plan] ?? plan;
}

function StorageUsage({ storage, isLoading, onRefresh }: StorageUsageProps) {
  const events: EventStorageRecord[] = storage?.events ?? [];

  const largestEventBytes = events.reduce(
    (largest, eventStorage) => Math.max(largest, eventStorage.totalBytes),
    0,
  );

  return (
    <section className="panel storage-panel">
      <div className="section-heading">
        <div>
          <p className="section-label">Cloudflare storage</p>

          <h2>
            {storage ? formatStorageSize(storage.totalBytes) : "—"} stored
          </h2>

          <p className="section-description">
            Every proof, final, and preview PickPic keeps in R2, broken down by
            the shoot holding it.
          </p>
        </div>

        <div className="section-actions">
          <button
            className="secondary-button"
            type="button"
            onClick={onRefresh}
            disabled={isLoading}
          >
            {isLoading ? "Measuring…" : "Refresh"}
          </button>
        </div>
      </div>

      {storage && (
        <div className="storage-plan">
          <div className="storage-plan-heading">
            <span className="storage-plan-name">
              {formatPlanLabel(storage.plan)} plan
            </span>

            <span>
              {formatStorageSize(
                Math.max(storage.capBytes - storage.totalBytes, 0),
              )}{" "}
              of {formatStorageSize(storage.capBytes)} remaining
            </span>
          </div>

          <span className="storage-bar">
            <span
              className="storage-bar-fill"
              style={{
                width: `${Math.min((storage.totalBytes / storage.capBytes) * 100, 100).toFixed(1)}%`,
              }}
            />
          </span>
        </div>
      )}

      {storage && (
        <dl className="storage-totals">
          <div>
            <dt>Proofs</dt>
            <dd>{formatStorageSize(storage.proofBytes)}</dd>
            <small>{formatCount(storage.photoCount, "photo")}</small>
          </div>

          <div>
            <dt>Finals</dt>
            <dd>{formatStorageSize(storage.finalBytes)}</dd>
            <small>{formatCount(storage.finalCount, "edit")}</small>
          </div>

          <div>
            <dt>Thumbnails &amp; previews</dt>
            <dd>{formatStorageSize(storage.variantBytes)}</dd>
            <small>{formatCount(storage.variantCount, "variant")}</small>
          </div>
        </dl>
      )}

      <div aria-live="polite">
        {!storage && isLoading ? (
          <p className="storage-placeholder">Measuring stored photos…</p>
        ) : events.length === 0 ? (
          <p className="storage-placeholder">
            Nothing is stored yet. Upload a shoot and it will appear here.
          </p>
        ) : (
          <div
            className="storage-table-scroll"
            role="region"
            aria-label="Storage by event"
            tabIndex={0}
          >
            <table className="storage-table">
              <thead>
                <tr>
                  <th scope="col">Event</th>
                  <th scope="col">Photos</th>
                  <th scope="col">Proofs</th>
                  <th scope="col">Finals</th>
                  <th scope="col">Previews</th>
                  <th scope="col">Total</th>
                </tr>
              </thead>

              <tbody>
                {events.map((eventStorage) => {
                  /*
                   * Scaled against the largest event rather than the
                   * total, so the smaller shoots stay visible next to
                   * a dominant one.
                   */
                  const share =
                    largestEventBytes === 0
                      ? 0
                      : (eventStorage.totalBytes / largestEventBytes) * 100;

                  return (
                    <tr key={eventStorage.eventId}>
                      <th scope="row">
                        <span className="storage-event-title">
                          {eventStorage.title}
                        </span>

                        <span className="storage-event-status">
                          {eventStorage.status}
                        </span>

                        <span className="storage-bar">
                          <span
                            className="storage-bar-fill"
                            style={{ width: `${share.toFixed(1)}%` }}
                          />
                        </span>
                      </th>

                      <td>
                        {eventStorage.photoCount.toLocaleString()}
                        {eventStorage.finalCount > 0 && (
                          <small>
                            {" "}
                            + {eventStorage.finalCount.toLocaleString()} final
                          </small>
                        )}
                      </td>

                      <td>{formatStorageSize(eventStorage.proofBytes)}</td>
                      <td>{formatStorageSize(eventStorage.finalBytes)}</td>
                      <td>{formatStorageSize(eventStorage.variantBytes)}</td>

                      <td className="storage-total-cell">
                        {formatStorageSize(eventStorage.totalBytes)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <p className="storage-caveat">
        These sizes come from what the database recorded for each stored file,
        not from R2 itself, so they can drift if a delete ever half-failed.
      </p>
    </section>
  );
}

export default StorageUsage;
