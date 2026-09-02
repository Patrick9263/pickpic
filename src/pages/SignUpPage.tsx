import { useEffect, useRef, useState, type FormEvent } from "react";
import { fetchJson } from "../api";

const MAX_ACCOUNT_NAME_LENGTH = 120;

function readTokenFromLocation(): string | null {
  return new URLSearchParams(window.location.search).get("token");
}

function SignUpPage() {
  const [token, setToken] = useState(readTokenFromLocation);
  const [isConsuming, setIsConsuming] = useState(token !== null);
  const [consumeFailed, setConsumeFailed] = useState(false);
  const [accountName, setAccountName] = useState("");
  const [email, setEmail] = useState("");
  const [inviteCode, setInviteCode] = useState("");
  const [isSending, setIsSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const consumedTokenRef = useRef<string | null>(null);

  useEffect(() => {
    if (token === null || consumedTokenRef.current === token) {
      return;
    }

    // A confirmation token is single-use, so this request must not fire twice
    // for the same token -- including React StrictMode's dev-only double
    // effect invocation, which would otherwise burn the token on a request
    // the UI throws away and surface a false "link expired" error. The stake
    // is higher here than on the sign-in page: the discarded request would
    // spend a signup rather than a sign-in. Because that guard already makes
    // this a one-shot action, the fetch's own completion is left unguarded (no
    // per-invocation "cancelled" flag): StrictMode tears down the effect that
    // started the request before the request resolves, and gating on that
    // would silently drop a successful signup.
    consumedTokenRef.current = token;
    setIsConsuming(true);
    setError(null);

    fetchJson("/api/auth/signup/consume", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ token }),
    })
      .then(() => {
        window.location.assign("/");
      })
      .catch((caughtError: unknown) => {
        setError(
          caughtError instanceof Error
            ? caughtError.message
            : "This confirmation link is not valid.",
        );
        setToken(null);
        setIsConsuming(false);
        setConsumeFailed(true);
      });
  }, [token]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const trimmedName = accountName.trim();
    const trimmedEmail = email.trim();
    const trimmedCode = inviteCode.trim();

    if (!trimmedName || !trimmedEmail || !trimmedCode) {
      setError("Fill in every field to create an account.");
      return;
    }

    setIsSending(true);
    setError(null);

    try {
      await fetchJson("/api/auth/signup", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: trimmedEmail,
          accountName: trimmedName,
          inviteCode: trimmedCode,
        }),
      });

      setSent(true);
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to send the confirmation email.",
      );
    } finally {
      setIsSending(false);
    }
  }

  return (
    <main className="home-page">
      {/* A plain link, not a click handler: App.tsx reads window.location.pathname
          once at render and has no history listener, so a pushState navigation
          would change the URL and render nothing new. */}
      <a className="brand" href="/" aria-label="PickPic home">
        PickPic
      </a>

      <h1>Create an account</h1>

      {isConsuming ? (
        <p>Creating your account…</p>
      ) : sent ? (
        // Deliberately vague about what was sent. An address that already has an
        // account is mailed a sign-in link instead, and this line has to be true
        // either way -- so it must not promise to finish setting anything up.
        <p>Check your email — we sent a link to {email}.</p>
      ) : (
        <form
          className="create-form sign-in-form sign-up-form"
          onSubmit={handleSubmit}
        >
          <label htmlFor="sign-up-name">Studio name</label>

          <div className="form-row">
            <input
              id="sign-up-name"
              name="accountName"
              type="text"
              value={accountName}
              onChange={(event) => setAccountName(event.target.value)}
              placeholder="Patrick Photography"
              maxLength={MAX_ACCOUNT_NAME_LENGTH}
              disabled={isSending}
              autoComplete="organization"
            />
          </div>

          {/* Not shown to clients or anywhere in the dashboard yet -- it's
              stored for later, so this sets expectations rather than
              promising a feature that doesn't exist. */}
          <p className="field-hint">
            Not shown to clients — just helps identify your account.
          </p>

          <span className="character-count">
            {accountName.length}/{MAX_ACCOUNT_NAME_LENGTH}
          </span>

          <label htmlFor="sign-up-email">Email address</label>

          <div className="form-row">
            <input
              id="sign-up-email"
              name="email"
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="you@example.com"
              disabled={isSending}
              autoComplete="email"
            />
          </div>

          <label htmlFor="sign-up-invite">Invite code</label>

          <div className="form-row">
            {/* Not type="password". This is a code somebody was handed rather
                than a memorised secret, and masking it only hides typos. */}
            <input
              id="sign-up-invite"
              name="inviteCode"
              type="text"
              value={inviteCode}
              onChange={(event) => setInviteCode(event.target.value)}
              disabled={isSending}
              autoComplete="off"
              spellCheck={false}
            />
          </div>

          <div className="form-row">
            <button
              type="submit"
              disabled={
                isSending ||
                !accountName.trim() ||
                !email.trim() ||
                !inviteCode.trim()
              }
            >
              {isSending ? "Sending…" : "Create account"}
            </button>
          </div>
        </form>
      )}

      {error && (
        <div className="error-message" role="alert">
          <span>{error}</span>
          <button type="button" onClick={() => setError(null)}>
            Dismiss
          </button>
        </div>
      )}

      {/* Every way consuming a link can fail -- expired, already claimed, session
          not started -- has the same next step, and it is not this form. */}
      {consumeFailed ? (
        <p>
          <a href="/sign-in">Go to sign in</a>
        </p>
      ) : (
        !isConsuming && (
          <p>
            Already have an account? <a href="/sign-in">Sign in</a>.
          </p>
        )
      )}
    </main>
  );
}

export default SignUpPage;
