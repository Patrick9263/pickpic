import { useCallback, useEffect, useRef, useState } from "react";
import { getErrorMessage } from "../api";
import { formatStorageSize } from "../storageFormat";
import type {
  OperatorAccountRecord,
  OperatorAccountsResponse,
  StorageOrphanScan,
} from "../types";
import {
  EMPTY_ORPHAN_SCAN,
  formatDaysAgo,
  mergeOrphanScans,
  summarizeOperatorAccounts,
} from "./operatorHelpers";
import "../styles/OperatorPage.css";

type LoadState =
  | { status: "loading" }
  | { status: "ready"; data: OperatorAccountsResponse }
  /*
   * 403 is kept apart from every other failure because it is the expected
   * answer, not an error: this page has no link pointing at it, so the way most
   * people would ever reach it is by typing the URL out of curiosity.
   */
  | { status: "forbidden" }
  | { status: "error"; message: string };

function formatCount(value: number, noun: string): string {
  return `${value.toLocaleString()} ${noun}${value === 1 ? "" : "s"}`;
}

function AccountCard({
  account,
  now,
}: {
  account: OperatorAccountRecord;
  now: number;
}) {
  const isDormant = account.photoCount === 0;

  return (
    <li className="operator-account">
      <div className="operator-account-heading">
        <h3>{account.name}</h3>

        <span className="operator-tags">
          {account.status !== "active" && (
            <span className="operator-tag operator-tag-warn">
              {account.status}
            </span>
          )}

          <span className="operator-tag">{account.plan}</span>

          {isDormant && (
            <span className="operator-tag operator-tag-warn">
              never uploaded
            </span>
          )}
        </span>
      </div>

      <dl className="operator-metrics">
        <div>
          <dt>Events</dt>
          <dd>{account.eventCount.toLocaleString()}</dd>
        </div>

        <div>
          <dt>Photos</dt>
          <dd>{account.photoCount.toLocaleString()}</dd>
        </div>

        <div>
          <dt>Storage</dt>
          <dd>
            {formatStorageSize(account.storageBytes)}
            <span className="operator-metric-note">
              of {formatStorageSize(account.storageCapBytes)}
            </span>
          </dd>
        </div>

        <div>
          <dt>Last upload</dt>
          <dd>{formatDaysAgo(account.lastPhotoAt, now)}</dd>
        </div>
      </dl>

      <ul className="operator-users">
        {account.users.length === 0 && (
          <li className="operator-user operator-user-empty">
            No signed-up user — created outside the signup flow.
          </li>
        )}

        {account.users.map((user) => (
          <li className="operator-user" key={user.id}>
            <span className="operator-user-email">
              {user.email ?? "(no address)"}
            </span>

            <span className="operator-user-meta">
              {user.role} · {user.authProvider} · last seen{" "}
              {formatDaysAgo(user.lastSeenAt, now)}
            </span>
          </li>
        ))}
      </ul>

      <p className="operator-account-footer">
        Signed up {formatDaysAgo(account.createdAt, now)}
        {account.databaseId !== null && ` · database ${account.databaseId}`}
      </p>
    </li>
  );
}

type OrphanScanState =
  | { status: "idle" }
  | { status: "scanning"; scan: StorageOrphanScan }
  | { status: "done"; scan: StorageOrphanScan }
  | { status: "error"; message: string; scan: StorageOrphanScan };

/*
 * The R2 reconciliation report (#249). Started by hand rather than on page
 * load: a full scan lists the whole bucket, which is billed per call and grows
 * with every upload, and the question it answers ("is orphaned storage worth
 * cleaning up?") is not one that needs asking on every visit.
 *
 * The worker answers one bounded slice per request, so the loop lives here and
 * the running totals are shown as they grow -- a large bucket reads as
 * progress rather than as a request that seems to hang.
 */
function StorageOrphanPanel() {
  const [state, setState] = useState<OrphanScanState>({ status: "idle" });
  const [scannedAt, setScannedAt] = useState(() => Date.now());

  /* Bumped per run, so a scan restarted mid-flight cannot interleave slices. */
  const runRef = useRef(0);

  useEffect(
    () => () => {
      runRef.current += 1;
    },
    [],
  );

  const scan = useCallback(async () => {
    const run = ++runRef.current;
    let running = EMPTY_ORPHAN_SCAN;
    let cursor: string | null = null;

    setScannedAt(Date.now());
    setState({ status: "scanning", scan: running });

    try {
      do {
        const query = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
        const response = await fetch(`/api/operator/storage-orphans${query}`);

        if (run !== runRef.current) {
          return;
        }

        if (!response.ok) {
          setState({
            status: "error",
            message: await getErrorMessage(response),
            scan: running,
          });
          return;
        }

        const slice = (await response.json()) as StorageOrphanScan;

        if (run !== runRef.current) {
          return;
        }

        running = mergeOrphanScans(running, slice);
        cursor = slice.cursor;

        setState({ status: cursor ? "scanning" : "done", scan: running });
      } while (cursor);
    } catch (caughtError) {
      if (run !== runRef.current) {
        return;
      }

      setState({
        status: "error",
        message:
          caughtError instanceof Error
            ? caughtError.message
            : "Unable to scan storage.",
        scan: running,
      });
    }
  }, []);

  const result = state.status === "idle" ? null : state.scan;

  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <p className="section-label">Storage</p>
          <h2>Orphaned objects</h2>
          <p className="section-description">
            R2 objects under events/ that no photo or variant row points at.
            They never count toward any account&rsquo;s storage, so the bill is
            the only other place they show up. Read-only.
          </p>
        </div>

        <div className="section-actions">
          <button
            className="secondary-button"
            type="button"
            disabled={state.status === "scanning"}
            onClick={() => void scan()}
          >
            {state.status === "scanning"
              ? "Scanning…"
              : state.status === "idle"
                ? "Scan"
                : "Scan again"}
          </button>
        </div>
      </div>

      {state.status === "error" && (
        <div className="error-message operator-notice" role="alert">
          <span>{state.message} Totals below cover only what was scanned.</span>
        </div>
      )}

      {result && (
        <>
          <dl className="operator-metrics operator-orphan-metrics">
            <div>
              <dt>Scanned</dt>
              <dd>
                {formatCount(result.scannedObjects, "object")}
                <span className="operator-metric-note">
                  {formatStorageSize(result.scannedBytes)}
                </span>
              </dd>
            </div>

            <div>
              <dt>Orphaned</dt>
              <dd>
                {formatCount(result.orphanCount, "object")}
                <span className="operator-metric-note">
                  {formatStorageSize(result.orphanBytes)}
                </span>
              </dd>
            </div>

            <div>
              <dt>Older than 24h</dt>
              <dd>
                {formatCount(result.staleOrphanCount, "object")}
                <span className="operator-metric-note">
                  {formatStorageSize(result.staleOrphanBytes)} · not an
                  in-flight upload
                </span>
              </dd>
            </div>

            <div>
              <dt>Event deleted</dt>
              <dd>
                {formatCount(result.missingEventOrphanCount, "object")}
                <span className="operator-metric-note">
                  {formatStorageSize(result.missingEventOrphanBytes)}
                </span>
              </dd>
            </div>
          </dl>

          {result.sample.length > 0 && (
            <ul className="operator-users operator-orphan-samples">
              {result.sample.map((orphan) => (
                <li className="operator-user" key={orphan.key}>
                  <span className="operator-user-email">{orphan.key}</span>
                  <span className="operator-user-meta">
                    {formatStorageSize(orphan.size)} · uploaded{" "}
                    {formatDaysAgo(orphan.uploaded, scannedAt)}
                    {!orphan.eventExists && " · event deleted"}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}

function OperatorPage() {
  const [state, setState] = useState<LoadState>({ status: "loading" });

  /*
   * Pinned when the response lands rather than read per render, so every "3
   * days ago" on the page is measured from the same instant as the data it
   * describes.
   */
  const [loadedAt, setLoadedAt] = useState(() => Date.now());

  const load = useCallback(async () => {
    setState({ status: "loading" });

    try {
      const response = await fetch("/api/operator/accounts");

      if (response.status === 403) {
        const message = await getErrorMessage(response);
        if (message === "Operator access is required.") {
          setState({ status: "forbidden" });
        } else {
          setState({ status: "error", message });
        }
        return;
      }

      if (!response.ok) {
        setState({ status: "error", message: await getErrorMessage(response) });
        return;
      }

      setLoadedAt(Date.now());
      setState({
        status: "ready",
        data: (await response.json()) as OperatorAccountsResponse,
      });
    } catch (caughtError) {
      setState({
        status: "error",
        message:
          caughtError instanceof Error
            ? caughtError.message
            : "Unable to load accounts.",
      });
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const summary =
    state.status === "ready"
      ? {
          totals: summarizeOperatorAccounts(state.data.accounts),

          /*
           * From the server rather than from totals.accountCount: the two
           * differ only when the list was truncated, and "how many beta testers
           * are there" has to stay right in exactly that case.
           */
          accountCount: state.data.accountCount,
        }
      : null;

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label="PickPic home">
          PickPic
        </a>

        <span className="environment-badge">Operator</span>
      </header>

      <main className="dashboard operator-page">
        <section className="hero">
          <p className="eyebrow">Operator</p>
          <h1>All accounts</h1>

          {summary && (
            <p className="hero-description">
              {formatCount(summary.accountCount, "account")},{" "}
              {formatCount(summary.totals.userCount, "user")},{" "}
              {formatCount(summary.totals.eventCount, "event")},{" "}
              {formatCount(summary.totals.photoCount, "photo")} ·{" "}
              {formatStorageSize(summary.totals.storageBytes)} stored ·{" "}
              {summary.totals.dormantCount} never uploaded
            </p>
          )}
        </section>

        {state.status === "loading" && (
          <section className="panel">
            <p className="section-description">Loading…</p>
          </section>
        )}

        {state.status === "forbidden" && (
          <section className="panel">
            <p className="section-label">Not available</p>
            <h2>This account is not an operator</h2>
            <p className="section-description">
              Operator access is granted by hand, directly in the database —
              there is no route that can grant it, on purpose.
            </p>
          </section>
        )}

        {state.status === "error" && (
          <div className="error-message" role="alert">
            <span>{state.message}</span>
            <button type="button" onClick={() => void load()}>
              Try again
            </button>
          </div>
        )}

        {state.status === "ready" && (
          <section className="panel">
            <div className="section-heading">
              <div>
                <p className="section-label">Accounts</p>
                <h2>Newest first</h2>
                <p className="section-description">
                  Storage is the running counter each account&rsquo;s own
                  dashboard reconciles, so it can lag for one nobody has opened
                  lately.
                </p>
              </div>

              <div className="section-actions">
                <button
                  className="secondary-button"
                  type="button"
                  onClick={() => void load()}
                >
                  Refresh
                </button>
              </div>
            </div>

            {state.data.truncated && (
              <p className="section-description operator-notice">
                Showing the {state.data.accounts.length} newest of{" "}
                {state.data.accountCount}.
              </p>
            )}

            <ul className="operator-accounts">
              {state.data.accounts.map((account) => (
                <AccountCard
                  account={account}
                  key={account.id}
                  now={loadedAt}
                />
              ))}
            </ul>
          </section>
        )}

        {/* Behind "ready" so a non-operator never sees a scan button that can only 403. */}
        {state.status === "ready" && <StorageOrphanPanel />}
      </main>
    </div>
  );
}

export default OperatorPage;
