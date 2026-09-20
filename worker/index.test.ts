import { describe, expect, it } from "vitest";
import {
  buildStoredImageCacheKey,
  roundPublicCoordinate,
  safeDecodePathSegment,
} from "./index.ts";

describe("roundPublicCoordinate", () => {
  it("passes null through unchanged", () => {
    expect(roundPublicCoordinate(null)).toBe(null);
  });

  it("rounds to two decimal places", () => {
    expect(roundPublicCoordinate(40.712776)).toBe(40.71);
    expect(roundPublicCoordinate(-74.005974)).toBe(-74.01);
  });

  it("leaves values already at two decimal places unchanged", () => {
    expect(roundPublicCoordinate(1.5)).toBe(1.5);
  });
});

describe("safeDecodePathSegment", () => {
  it("decodes a valid percent-escaped segment", () => {
    expect(safeDecodePathSegment("hello%20world")).toBe("hello world");
  });

  it("passes a segment with no escapes through unchanged", () => {
    expect(safeDecodePathSegment("plain-token")).toBe("plain-token");
  });

  it("returns null for a malformed percent-escape", () => {
    expect(safeDecodePathSegment("%zz")).toBe(null);
  });

  it("returns null for a truncated percent-escape", () => {
    expect(safeDecodePathSegment("abc%2")).toBe(null);
  });
});

describe("buildStoredImageCacheKey", () => {
  /*
   * caches.default only accepts keys inside the zone serving the request, so
   * the key has to inherit the request's origin rather than name a fixed host.
   */
  it("keeps the request's own origin", () => {
    expect(
      buildStoredImageCacheKey(
        "https://pickpic.photos/api/galleries/tok/photos/p1/image",
        "events/e1/photos/p1/preview.jpg",
      ),
    ).toBe(
      "https://pickpic.photos/__image-object/" +
        "events%2Fe1%2Fphotos%2Fp1%2Fpreview.jpg",
    );
  });

  /*
   * The storage key is one encoded path segment, so its slashes cannot spill
   * into the key's own path and let two different objects collide -- or let a
   * key resolve onto a real route.
   */
  it("encodes the storage key into a single segment", () => {
    const key = buildStoredImageCacheKey(
      "https://pickpic.photos/api/galleries/tok/photos/p1/image",
      "events/e1/photos/p1/variants/original/u1/thumbnail.jpg",
    );

    expect(new URL(key).pathname.split("/")).toHaveLength(3);
  });

  /*
   * Share token and the `?v=` variant cache-buster are both dropped: the
   * storage key already changes whenever the bytes do (every upload path mints
   * a fresh UUID), and keying on the object instead means a rotated share token
   * still hits -- safely, because the status gate ran before this was called.
   */
  it("ignores the share token and query string of the request", () => {
    expect(
      buildStoredImageCacheKey(
        "https://pickpic.photos/api/galleries/old-token/photos/p1" +
          "/variants/original/thumbnail?v=2026-01-01T00%3A00%3A00Z",
        "events/e1/photos/p1/preview.jpg",
      ),
    ).toBe(
      buildStoredImageCacheKey(
        "https://pickpic.photos/api/galleries/new-token/photos/p1/image",
        "events/e1/photos/p1/preview.jpg",
      ),
    );
  });

  it("gives different storage keys different cache keys", () => {
    const base = "https://pickpic.photos/api/galleries/tok/photos/p1/image";

    expect(
      buildStoredImageCacheKey(base, "events/e1/photos/p1/preview.jpg"),
    ).not.toBe(
      buildStoredImageCacheKey(base, "events/e1/photos/p1/finals/u1.jpg"),
    );
  });
});
