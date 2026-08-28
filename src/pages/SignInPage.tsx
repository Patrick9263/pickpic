import { useEffect, useRef, useState, type FormEvent } from "react";
import { fetchJson } from "../api";

function readTokenFromLocation(): string | null {
  return new URLSearchParams(window.location.search).get("token");
}

function SignInPage() {
  const [token, setToken] = useState(readTokenFromLocation);
  const [isConsuming, setIsConsuming] = useState(token !== null);
  const [email, setEmail] = useState("");
  const [isSending, setIsSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const consumedTokenRef = useRef<string | null>(null);

  useEffect(() => {
    if (token === null || consumedTokenRef.current === token) {
      return;
    }

    // A magic-link token is single-use, so this request must not fire twice
    // for the same token -- including React StrictMode's dev-only double
    // effect invocation, which would otherwise burn the token on a request
    // the UI throws away and surface a false "link expired" error. Because
    // that guard already makes this a one-shot action, the fetch's own
    // completion is left unguarded (no per-invocation "cancelled" flag):
    // StrictMode tears down the effect that started the request before the
    // request resolves, and gating on that would silently drop a successful
    // sign-in.
    consumedTokenRef.current = token;
    setIsConsuming(true);
    setError(null);

    fetchJson("/api/auth/magic-link/consume", {
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
            : "This sign-in link is not valid.",
        );
        setToken(null);
        setIsConsuming(false);
      });
  }, [token]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const trimmedEmail = email.trim();

    if (!trimmedEmail) {
      setError("Enter an email address.");
      return;
    }

    setIsSending(true);
    setError(null);

    try {
      await fetchJson("/api/auth/magic-link", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email: trimmedEmail }),
      });

      setSent(true);
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Unable to send the sign-in email.",
      );
    } finally {
      setIsSending(false);
    }
  }

  return (
    <main className="home-page">
      <a className="brand" href="/" aria-label="PickPic home">
        PickPic
      </a>

      <h1>Sign in</h1>

      {isConsuming ? (
        <p>Signing you in…</p>
      ) : sent ? (
        <p>Check your email — we sent a sign-in link to {email}.</p>
      ) : (
        <form className="create-form sign-in-form" onSubmit={handleSubmit}>
          <label htmlFor="sign-in-email">Email address</label>

          <div className="form-row">
            <input
              id="sign-in-email"
              name="email"
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="you@example.com"
              disabled={isSending}
              autoComplete="email"
            />

            <button type="submit" disabled={isSending || !email.trim()}>
              {isSending ? "Sending…" : "Send sign-in link"}
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
    </main>
  );
}

export default SignInPage;
