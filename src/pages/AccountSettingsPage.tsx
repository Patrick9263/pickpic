import { useEffect, useState, type FormEvent } from "react";
import { fetchJson } from "../api";
import { useSession } from "../hooks/useSession";
import type { UpdateAccountResponse } from "../types";
import SignInPage from "./SignInPage";

function AccountSettingsPage() {
  const { status, account, user, refresh, signOut } = useSession();
  const [name, setName] = useState("");
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [justSaved, setJustSaved] = useState(false);

  useEffect(() => {
    if (account !== null) {
      setName(account.name);
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

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label="PickPic home">
          PickPic
        </a>

        <div className="header-account">
          <span>{user.email}</span>
          <button type="button" onClick={() => void signOut()}>
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

        {error && (
          <div className="error-message" role="alert">
            <span>{error}</span>
            <button type="button" onClick={() => setError(null)}>
              Dismiss
            </button>
          </div>
        )}
      </main>
    </div>
  );
}

export default AccountSettingsPage;
