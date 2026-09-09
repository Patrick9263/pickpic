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
