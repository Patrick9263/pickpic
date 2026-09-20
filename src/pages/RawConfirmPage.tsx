import { useState } from "react";
import { fetchJson } from "../api";

function readTokenFromLocation(): string | null {
  return new URLSearchParams(window.location.search).get("t");
}

interface ConfirmResponse {
  photoId: string;
}

/*
 * Mirrors SignInPage's pattern for the identical reason (#193, and #323 for
 * this route specifically): a mail scanner follows every URL in the
 * confirmation email with an unattended GET, so a page that redeemed the
 * token on load would be burned before the recipient ever saw it. Redemption
 * only happens behind a press.
 */
function RawConfirmPage({ shareToken }: { shareToken: string }) {
  const [token] = useState(readTokenFromLocation);
  const [isConfirming, setIsConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConfirm() {
    if (token === null || isConfirming) {
      return;
    }

    setIsConfirming(true);
    setError(null);

    try {
      const result = await fetchJson<ConfirmResponse>(
        `/api/galleries/${encodeURIComponent(shareToken)}/raw-confirm`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ token }),
        },
      );

      // Deliberately leaves isConfirming set -- the navigation is already in
      // flight, and clearing it would flash the button over a page on its
      // way out.
      window.location.assign(
        `/g/${encodeURIComponent(shareToken)}?photo=${encodeURIComponent(result.photoId)}`,
      );
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "This confirmation link is not valid.",
      );
      setIsConfirming(false);
    }
  }

  return (
    <main className="home-page">
      <a
        className="brand"
        href={`/g/${encodeURIComponent(shareToken)}`}
        aria-label="Back to gallery"
      >
        PickPic
      </a>

      <h1>Confirm your request</h1>

      {token === null ? (
        <p>This confirmation link is missing its token.</p>
      ) : (
        <div className="sign-in-confirm">
          <p>Confirm this address to request the original file.</p>

          <button type="button" onClick={handleConfirm} disabled={isConfirming}>
            {isConfirming ? "Confirming…" : "Confirm my request"}
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
    </main>
  );
}

export default RawConfirmPage;
