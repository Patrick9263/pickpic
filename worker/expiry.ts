/*
 * The one definition of "this event's live window is over" (#181). Past
 * events.expires_at a gallery is read-only: viewers can still look and
 * download, but it takes no new hearts, comments or RAW requests, and the
 * photographer can add no new proofs or finals.
 *
 * NULL means the event never expires, which is every event today -- nothing
 * writes the column until Checkout / pass credits exist (#183).
 *
 * An unparseable value fails *open*, i.e. is treated as not expired. Only
 * this worker writes the column, so a malformed value is our own bug, and
 * the consumer that will eventually act on this same answer is the purge
 * step (#185), which deletes R2 objects. Handing a paying customer extra
 * days is recoverable; deleting their gallery early is not.
 */
export function isEventExpired(
  expiresAt: string | null | undefined,
  now: number = Date.now(),
): boolean {
  if (expiresAt === null || expiresAt === undefined) {
    return false;
  }

  const expiresAtMs = Date.parse(expiresAt);

  if (Number.isNaN(expiresAtMs)) {
    return false;
  }

  return expiresAtMs <= now;
}
