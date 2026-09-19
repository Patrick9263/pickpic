import { useEffect, useState, type FormEvent } from "react";
import { fetchJson } from "../api";
import { useSession } from "../hooks/useSession";
import type { UpdateAccountResponse } from "../types";
import SignInPage from "./SignInPage";

const DAY_MS = 24 * 60 * 60 * 1000;

/*
 * Must match RAW_DELIVERY_TTL_MIN_MS/MAX_MS in worker/index.ts and the CHECK
 * constraint in migrations/0024_add_raw_delivery_ttl.sql (#225).
 */
const RAW_DELIVERY_TTL_MIN_DAYS = 2;
const RAW_DELIVERY_TTL_MAX_DAYS = 90;

function AccountSettingsPage() {
  const { status, account, user, refresh, signOut, signOutError } =
    useSession();
  const [name, setName] = useState("");
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [justSaved, setJustSaved] = useState(false);

  const [ttlDays, setTtlDays] = useState(0);
  const [isSavingTtl, setIsSavingTtl] = useState(false);
  const [ttlError, setTtlError] = useState<string | null>(null);
  const [ttlJustSaved, setTtlJustSaved] = useState(false);

  useEffect(() => {
    if (account !== null) {
      setName(account.name);
      setTtlDays(Math.round(account.rawDeliveryTtlMs / DAY_MS));
    }
  }, [account]);

  if (status === "loading") {
    return (
      <main className="home-page">
        <span className="brand">PickPic</span>
        <p>Loading…</p>
      </main>
    );
  }

  if (status === "signedOut" || user === null || account === null) {
    return <SignInPage />;
  }

  const trimmedName = name.trim();
  const nameIsValid = trimmedName.length > 0 && trimmedName.length <= 120;
  const nameHasChanged = trimmedName !== account.name;

  const currentTtlDays = Math.round(account.rawDeliveryTtlMs / DAY_MS);
  const ttlIsValid =
    Number.isInteger(ttlDays) &&
    ttlDays >= RAW_DELIVERY_TTL_MIN_DAYS &&
    ttlDays <= RAW_DELIVERY_TTL_MAX_DAYS;
  const ttlHasChanged = ttlDays !== currentTtlDays;
  const ttlIsLowered = ttlIsValid && ttlDays < currentTtlDays;

  async function submitAccountName(
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> {
    event.preventDefault();

    if (!nameIsValid || !nameHasChanged) {
      return;
    }

    setIsSaving(true);
    setError(null);
    setJustSaved(false);

    try {
      await fetchJson<UpdateAccountResponse>("/api/admin/account", {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ name: trimmedName }),
      });

      refresh();
      setJustSaved(true);
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to update the account.",
      );
    } finally {
      setIsSaving(false);
    }
  }

  async function submitRawDeliveryTtl(
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> {
    event.preventDefault();

    if (!ttlIsValid || !ttlHasChanged) {
      return;
    }

    setIsSavingTtl(true);
    setTtlError(null);
    setTtlJustSaved(false);

    try {
      await fetchJson<UpdateAccountResponse>("/api/admin/account", {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ rawDeliveryTtlMs: ttlDays * DAY_MS }),
      });

      refresh();
      setTtlJustSaved(true);
    } catch (caughtError) {
      setTtlError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to update the account.",
      );
    } finally {
      setIsSavingTtl(false);
    }
  }

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
          <p className="eyebrow">Account</p>
          <h1>Account settings</h1>
          <p className="hero-description">
            <a className="account-back-link" href="/">
              ← Back to dashboard
            </a>
          </p>
        </section>

        <section className="panel create-panel">
          <div>
            <p className="section-label">Your account</p>
            <h2>Name</h2>
            <p className="section-description">
              Not shown to clients — just helps identify your account.
            </p>
          </div>

          <form
            className="event-rename-form"
            onSubmit={(event) => void submitAccountName(event)}
          >
            <label htmlFor="account-name">Your name or studio</label>

            <input
              id="account-name"
              type="text"
              value={name}
              maxLength={120}
              autoComplete="off"
              disabled={isSaving}
              onChange={(event) => {
                setName(event.target.value);
                setJustSaved(false);
              }}
            />

            <div className="event-rename-footer">
              <span>{name.length}/120</span>

              <div className="event-rename-actions">
                <button
                  type="submit"
                  disabled={isSaving || !nameIsValid || !nameHasChanged}
                >
                  {isSaving ? "Saving…" : "Save"}
                </button>
              </div>
            </div>
          </form>

          {justSaved && <p className="section-description">Saved.</p>}
        </section>

        <section className="panel create-panel">
          <div>
            <p className="section-label">Storage</p>
            <h2>RAW retention</h2>
            <p className="section-description">
              How long a delivered RAW is kept before it's reclaimed, if nobody
              collects it. Reclaiming only happens the next time your iPad syncs
              that event — not immediately, since there's no scheduled sweep
              yet.
            </p>
          </div>

          <form
            className="event-rename-form"
            onSubmit={(event) => void submitRawDeliveryTtl(event)}
          >
            <label htmlFor="raw-delivery-ttl">Days to keep a RAW</label>

            <input
              id="raw-delivery-ttl"
              type="number"
              value={ttlDays}
              min={RAW_DELIVERY_TTL_MIN_DAYS}
              max={RAW_DELIVERY_TTL_MAX_DAYS}
              step={1}
              disabled={isSavingTtl}
              onChange={(event) => {
                setTtlDays(Number(event.target.value));
                setTtlJustSaved(false);
              }}
            />

            <div className="event-rename-footer">
              <span>
                {RAW_DELIVERY_TTL_MIN_DAYS}–{RAW_DELIVERY_TTL_MAX_DAYS} days
              </span>

              <div className="event-rename-actions">
                <button
                  type="submit"
                  disabled={isSavingTtl || !ttlIsValid || !ttlHasChanged}
                >
                  {isSavingTtl ? "Saving…" : "Save"}
                </button>
              </div>
            </div>
          </form>

          {ttlIsLowered && (
            <p className="section-description">
              Lowering this makes any RAW delivered more than {ttlDays} day
              {ttlDays === 1 ? "" : "s"} ago immediately eligible for reclaim on
              your next iPad sync.
            </p>
          )}

          {ttlJustSaved && <p className="section-description">Saved.</p>}
        </section>

        {ttlError && (
          <div className="error-message" role="alert">
            <span>{ttlError}</span>
            <button type="button" onClick={() => setTtlError(null)}>
              Dismiss
            </button>
          </div>
        )}

        {error && (
          <div className="error-message" role="alert">
            <span>{error}</span>
            <button type="button" onClick={() => setError(null)}>
              Dismiss
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

export default AccountSettingsPage;
