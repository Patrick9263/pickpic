/*
 * Pulled out of App.tsx so the malformed-share-link path (a `%` sequence
 * decodeURIComponent can't parse, e.g. `/g/%zz`) is unit-testable without
 * rendering the router.
 */
export function safeDecodeShareToken(rawToken: string): string {
  try {
    return decodeURIComponent(rawToken);
  } catch {
    // Falls through to the raw token, which simply won't match any share
    // link and lets GalleryPage's normal "Gallery unavailable" state
    // handle it, instead of throwing a URIError during render.
    return rawToken;
  }
}

/*
 * The dashboard's report after a manual RAW release (#219). Pulled out here
 * because the interesting cases are the ones with nothing to report: a release
 * that frees nothing because every RAW is still uncollected has to say so, or
 * the button reads as broken rather than as correctly declining to take a file
 * away from a viewer who has not had it yet.
 */
export function describeRawRelease(summary: {
  releasedPhotoCount: number;
  awaitingPhotoCount: number;
}): string {
  const waiting =
    summary.awaitingPhotoCount === 0
      ? ""
      : ` ${summary.awaitingPhotoCount === 1 ? "1 RAW file is" : `${summary.awaitingPhotoCount} RAW files are`} still waiting to be collected.`;

  if (summary.releasedPhotoCount === 0) {
    return `No collected RAW files to release.${waiting}`;
  }

  const released =
    summary.releasedPhotoCount === 1
      ? "Released 1 collected RAW file."
      : `Released ${summary.releasedPhotoCount} collected RAW files.`;

  return `${released}${waiting}`;
}

/*
 * The confirmation dialog for "Stop offering originals for this event" (#282),
 * a force-clear that revokes every RAW request nobody has downloaded yet,
 * regardless of collection status. Pulled out here for the same reason as
 * describeRawRelease above: the interesting case is naming the real human
 * cost -- how many strangers are about to have their pending delivery
 * revoked -- rather than a generic "are you sure?" that would understate it.
 */
export function describeStopOfferingRawsConfirmation(
  waitingCount: number,
  eventTitle: string,
): string {
  const tail =
    "Your files are still on the iPad -- turn originals back on and " +
    "they'll upload again if asked for.";

  if (waitingCount === 0) {
    return (
      `Stop offering originals for "${eventTitle}"? Viewers won't be able ` +
      `to request them until you turn requests back on. ${tail}`
    );
  }

  const viewers =
    waitingCount === 1 ? "1 viewer is" : `${waitingCount} viewers are`;

  return (
    `${viewers} waiting for originals from "${eventTitle}". They'll stop ` +
    `waiting, and this gallery will stop offering originals. ${tail}`
  );
}
