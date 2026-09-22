import { useState } from "react";
import { fetchJson } from "../api";
import {
  getOrCreateVisitorToken,
  parsePendingRawBatch,
  PENDING_RAW_BATCH_KEY,
  readStorageItem,
  removeStorageItem,
  VISITOR_TOKEN_KEY,
} from "./galleryHelpers";

function readTokenFromLocation(): string | null {
  return new URLSearchParams(window.location.search).get("t");
}

interface ConfirmResponse {
  photoId: string;
}

interface RawRequestBatchResponse {
  requested: number;
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

      await finishPendingBatch(result.photoId);

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

  /*
   * The rest of a batch request (#271): addRawRequestsBatch only ever mails
   * one confirmation, for one anchor photo, so once that link is confirmed
   * this browser -- if it is the one that submitted the batch -- finishes the
   * remaining photos itself. The address is proven the moment the confirm
   * call above succeeds, so this goes straight through with no further mail.
   *
   * Silently gives up on any mismatch (wrong gallery, no pending batch, a
   * confirmed photo that isn't the recorded anchor) rather than surfacing an
   * error -- the anchor photo's own request already succeeded, and a batch
   * left behind by a different device is expected, not a bug. The viewer can
   * always re-select the rest now that the address is confirmed.
   */
  async function finishPendingBatch(confirmedPhotoId: string): Promise<void> {
    const pendingBatch = parsePendingRawBatch(
      readStorageItem(() => window.localStorage, PENDING_RAW_BATCH_KEY),
      shareToken,
    );

    if (
      pendingBatch === null ||
      !pendingBatch.photoIds.includes(confirmedPhotoId)
    ) {
      return;
    }

    // Consumed unconditionally, whether or not anything is left to request --
    // a stale entry left behind after a mismatch would otherwise be retried
    // against the next unrelated confirmation for this gallery.
    removeStorageItem(() => window.localStorage, PENDING_RAW_BATCH_KEY);

    const remainingPhotoIds = pendingBatch.photoIds.filter(
      (photoId) => photoId !== confirmedPhotoId,
    );

    if (remainingPhotoIds.length === 0) {
      return;
    }

    const visitorToken = getOrCreateVisitorToken(
      () => window.localStorage,
      VISITOR_TOKEN_KEY,
      () => crypto.randomUUID(),
    );

    try {
      await fetchJson<RawRequestBatchResponse>(
        `/api/galleries/${encodeURIComponent(shareToken)}/raw-requests`,
        {
          method: "PUT",
          headers: {
            "X-PickPic-Visitor": visitorToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            displayName: pendingBatch.displayName,
            email: pendingBatch.email,
            photoIds: remainingPhotoIds,
          }),
        },
      );
    } catch {
      // Best-effort: the anchor photo is already requested and the viewer is
      // about to land back in the gallery, where every one of these photos
      // is still selectable for another try.
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
