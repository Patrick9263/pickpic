import { useCallback, useEffect, useState } from "react";
import { fetchJson } from "../api";
import { useSession } from "../hooks/useSession";
import { formatPlanLabel, formatStorageSize } from "../storageFormat";
import type {
  OperatorAccountSummary,
  OperatorAccountsResponse,
} from "../types";
import { formatLastUpload, summariseOperatorAccounts } from "./operatorHelpers";
import SignInPage from "./SignInPage";
import "../styles/OperatorPage.css";

/*
 * The cross-account view (#195). Cards rather than a wide table because this is
 * reached from the iPad as often as from a laptop, and a nine-column table is
 * unreadable at that width -- which is the whole reason this exists instead of
 * a D1 console.
 */
function AccountCard({
  account,
  now,
}: {
  account: OperatorAccountSummary;
  now: Date;
}) {
  const capShare =
    account.storageCapBytes > 0
      ? Math.min((account.storageBytes / account.storageCapBytes) * 100, 100)
      : 0;

  return (
    <li className="operator-account">
      <div className="operator-account-heading">
        <h3>{account.name}</h3>

        <span className="operator-account-plan">
          {formatPlanLabel(account.plan)}
          {account.status !== "active" && ` · ${account.status}`}
        </span>
      </div>

      <dl className="operator-account-stats">
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
            <span className="operator-account-cap">
              {" "}
              of {formatStorageSize(account.storageCapBytes)}
            </span>
          </dd>
        </div>

        <div>
          <dt>Last upload</dt>
          <dd>{formatLastUpload(account.lastPhotoUploadedAt, now)}</dd>
        </div>
      </dl>

      <div
        className="operator-account-meter"
        role="img"
        aria-label={`${capShare.toFixed(0)}% of the storage cap used`}
      >
        <span style={{ width: `${capShare.toFixed(1)}%` }} />
      </div>

      <ul className="operator-account-users">
        {account.users.length === 0 ? (
          <li className="operator-account-empty">
            No users — this account has never been signed in to.
          </li>
        ) : (
          account.users.map((user) => (
            <li key={user.id}>
              <span>{user.email ?? "(no address on file)"}</span>
              <span className="operator-account-user-meta">
                {user.role} · {user.authProvider}
              </span>
            </li>
          ))
        )}
      </ul>
    </li>
  );
}

function OperatorPage() {
  const { status, user, isOperator, signOut, signOutError } = useSession();

  const [accounts, setAccounts] = useState<OperatorAccountSummary[] | null>(
    null,
  );
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  /*
   * One instant for the whole render, so two accounts that uploaded at the same
   * moment never disagree by a second's worth of rounding.
   */
  const [now, setNow] = useState(() => new Date());

  const load = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetchJson<OperatorAccountsResponse>(
        "/api/admin/operator/accounts",
      );

      setAccounts(response.accounts);
      setNow(new Date());
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to load accounts.",
      );
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    if (isOperator) {
      void load();
    }
  }, [isOperator, load]);

  if (status === "loading") {
    return (
      <main className="home-page">
        <span className="brand">PickPic</span>
        <p>Loading…</p>
      </main>
    );
  }

  if (status === "signedOut" || user === null) {
    return <SignInPage />;
  }

  /*
   * A signed-in non-operator gets a plain refusal rather than a redirect: the
   * worker would refuse the data anyway, and silently bouncing someone who
   * typed the URL looks like the page is broken.
   */
  if (!isOperator) {
    return (
      <main className="home-page">
        <span className="brand">PickPic</span>
        <h1>Not available</h1>
        <p>This account doesn't have operator access.</p>
        <a className="home-admin-link" href="/">
          Return to the dashboard
        </a>
      </main>
    );
  }

  const totals = summariseOperatorAccounts(accounts ?? []);

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label="PickPic home">
          PickPic
        </a>

        <div className="header-account">
          <span>{user.email}</span>
          <button
            type="button"
            onClick={() => void signOut()}
            disabled={signOutError !== null}
          >
            Sign out
          </button>
        </div>
      </header>

      <main className="dashboard">
        <section className="hero">
          <p className="eyebrow">Operator</p>
          <h1>All accounts</h1>
          <p className="hero-description">
            <a className="account-back-link" href="/">
              ← Back to dashboard
            </a>
          </p>
        </section>

        <section className="panel operator-panel">
          <div className="section-heading">
            <div>
              <p className="section-label">Across every account</p>

              <h2>
                {totals.accountCount.toLocaleString()} account
                {totals.accountCount === 1 ? "" : "s"}
              </h2>

              <p className="section-description">
                {totals.userCount.toLocaleString()} user
                {totals.userCount === 1 ? "" : "s"} ·{" "}
                {totals.uploadingAccountCount.toLocaleString()} uploading ·{" "}
                {totals.idleAccountCount.toLocaleString()} idle ·{" "}
                {formatStorageSize(totals.totalStorageBytes)} stored
              </p>
            </div>

            <button
              type="button"
              onClick={() => void load()}
              disabled={isLoading}
            >
              {isLoading ? "Refreshing…" : "Refresh"}
            </button>
          </div>

          {accounts === null && isLoading && (
            <p className="section-description">Loading accounts…</p>
          )}

          {accounts !== null && accounts.length === 0 && (
            <p className="section-description">No accounts yet.</p>
          )}

          {accounts !== null && accounts.length > 0 && (
            <ul className="operator-accounts">
              {accounts.map((account) => (
                <AccountCard key={account.id} account={account} now={now} />
              ))}
            </ul>
          )}
        </section>

        {error && (
          <div className="error-message" role="alert">
            <span>{error}</span>
            <button type="button" onClick={() => void load()}>
              Try again
            </button>
          </div>
        )}

        {signOutError && (
          <div className="error-message" role="alert">
            <span>{signOutError}</span>
            <button type="button" onClick={() => window.location.reload()}>
              Reload to try again
            </button>
          </div>
        )}
      </main>
    </div>
  );
}

export default OperatorPage;
