import { describe, expect, it, vi } from "vitest";
import {
  buildGalleryGroups,
  comparePhotos,
  createArchiveFilename,
  createIndividualSaveEntries,
  createUniqueDownloadNames,
  encodePendingRawBatch,
  formatApproximateByteSize,
  formatDayGroupLabel,
  formatZipDownloadNotice,
  getDefaultPreviewUrl,
  getOrCreateVisitorToken,
  getRawRequestState,
  isLikelyInAppBrowser,
  parsePendingRawBatch,
  readStorageItem,
  removeStorageItem,
  sanitizeDownloadFilename,
  selectPhotosById,
  selectReadyRawPhotos,
  selectRequestableRawPhotos,
  writeStorageItem,
} from "./galleryHelpers";
import { makeGalleryPhoto as makePhoto } from "../testing/factories";

function blockedStorageAccess(): never {
  throw new DOMException("Blocked", "SecurityError");
}

describe("sanitizeDownloadFilename", () => {
  it("strips filesystem-unsafe characters", () => {
    expect(sanitizeDownloadFilename('a/b\\c:d*e?f"g<h>i|j.jpg')).toBe(
      "a-b-c-d-e-f-g-h-i-j.jpg",
    );
  });

  it("strips control characters", () => {
    expect(sanitizeDownloadFilename("ab.jpg")).toBe("ab.jpg");
  });

  it("trims trailing dots and spaces", () => {
    expect(sanitizeDownloadFilename("photo.jpg. . ")).toBe("photo.jpg");
  });

  it("falls back to photo.jpg when nothing survives sanitizing", () => {
    // Entirely trailing dots/spaces are stripped rather than replaced.
    expect(sanitizeDownloadFilename("...")).toBe("photo.jpg");
  });
});

describe("createUniqueDownloadNames", () => {
  it("leaves distinct filenames unchanged", () => {
    expect(createUniqueDownloadNames(["a.jpg", "b.jpg"])).toEqual([
      "a.jpg",
      "b.jpg",
    ]);
  });

  it("suffixes duplicate filenames to keep them unique", () => {
    expect(createUniqueDownloadNames(["a.jpg", "a.jpg", "a.jpg"])).toEqual([
      "a.jpg",
      "a (2).jpg",
      "a (3).jpg",
    ]);
  });

  it("treats names as duplicates case-insensitively", () => {
    expect(createUniqueDownloadNames(["A.JPG", "a.jpg"])).toEqual([
      "A.JPG",
      "a (2).jpg",
    ]);
  });
});

describe("formatApproximateByteSize", () => {
  it("formats sub-megabyte sizes in KB", () => {
    expect(formatApproximateByteSize(500)).toBe("1 KB");
    expect(formatApproximateByteSize(42_000)).toBe("42 KB");
  });

  it("formats megabyte-scale sizes in MB", () => {
    expect(formatApproximateByteSize(5_500_000)).toBe("5.5 MB");
  });

  it("formats gigabyte-scale sizes in GB", () => {
    expect(formatApproximateByteSize(2_340_000_000)).toBe("2.34 GB");
  });
});

describe("createArchiveFilename", () => {
  it("slugifies the event title", () => {
    expect(createArchiveFilename("Summer Barbecue!")).toBe(
      "summer-barbecue-photos.zip",
    );
  });

  it("falls back to a generic name for an empty/unsafe title", () => {
    expect(createArchiveFilename("***")).toBe("pickpic-gallery-photos.zip");
  });
});

describe("getRawRequestState", () => {
  const download = {
    filename: "DSC01015.ARW",
    byteSize: 118_000_000,
    expiresAt: "2026-02-15T00:00:00.000Z",
  };

  /*
   * Defaults the confirmation flag so each case below states only the fields it
   * is actually about.
   */
  function state(
    fields: Partial<Parameters<typeof getRawRequestState>[0]>,
  ): ReturnType<typeof getRawRequestState> {
    return getRawRequestState({
      viewerRequestedRaw: false,
      viewerRawDownload: null,
      viewerRawDownloadedAt: null,
      viewerRawConfirmationPending: false,
      ...fields,
    });
  }

  it("reports none before the viewer has asked", () => {
    expect(state({ viewerRequestedRaw: false })).toBe("none");
  });

  it("reports confirming while the address is unproven", () => {
    expect(state({ viewerRawConfirmationPending: true })).toBe("confirming");
  });

  /*
   * A pending confirmation can outlive the request it was made for: asking
   * again after a reclaim writes a real row while the earlier pending row may
   * still be unexpired. Whatever exists on the server has to win, or the button
   * would offer to confirm something already requested.
   */
  it("prefers a real request over a stale pending confirmation", () => {
    expect(
      state({
        viewerRequestedRaw: true,
        viewerRawConfirmationPending: true,
      }),
    ).toBe("waiting");
  });

  it("reports waiting while the iPad has yet to deliver", () => {
    expect(state({ viewerRequestedRaw: true })).toBe("waiting");
  });

  it("reports ready once the RAW is available to this viewer", () => {
    expect(
      state({ viewerRequestedRaw: true, viewerRawDownload: download }),
    ).toBe("ready");
  });

  /*
   * Inside the grace period a collected RAW is still there, and offering the
   * download again is the whole reason that period exists -- a transfer that
   * died at 80% must not leave the viewer looking at "Downloaded".
   */
  it("stays ready during the grace period after a download", () => {
    expect(
      state({
        viewerRequestedRaw: true,
        viewerRawDownload: download,
        viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
      }),
    ).toBe("ready");
  });

  /*
   * The state that only exists because of the reclaim. Without
   * viewerRawDownloadedAt this is indistinguishable from "waiting", and a
   * viewer whose file was deleted would sit watching a request that had in
   * fact already been satisfied.
   */
  it("reports collected once the downloaded RAW has been reclaimed", () => {
    expect(
      state({
        viewerRequestedRaw: true,
        viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
      }),
    ).toBe("collected");
  });
});

describe("formatDayGroupLabel", () => {
  it("returns a human label for the unknown bucket", () => {
    expect(formatDayGroupLabel("unknown")).toBe("Date unavailable");
  });

  it("formats a YYYY-MM-DD key as a full date", () => {
    expect(formatDayGroupLabel("2026-01-15")).toContain("2026");
  });
});

describe("comparePhotos", () => {
  it("orders by capture time when both photos have it", () => {
    const earlier = makePhoto({ capturedAt: "2026-01-01T00:00:00.000Z" });
    const later = makePhoto({ capturedAt: "2026-01-02T00:00:00.000Z" });

    expect(comparePhotos(earlier, later)).toBeLessThan(0);
  });

  it("puts photos with capture time before those without", () => {
    const withCapture = makePhoto({ capturedAt: "2026-01-01T00:00:00.000Z" });
    const withoutCapture = makePhoto({ capturedAt: null });

    expect(comparePhotos(withCapture, withoutCapture)).toBeLessThan(0);
    expect(comparePhotos(withoutCapture, withCapture)).toBeGreaterThan(0);
  });

  it("falls back to a numeric filename comparison", () => {
    const photo2 = makePhoto({ originalFilename: "DSC2.ARW" });
    const photo10 = makePhoto({ originalFilename: "DSC10.ARW" });

    // Numeric sensitivity means "10" sorts after "2", not before it.
    expect(comparePhotos(photo2, photo10)).toBeLessThan(0);
  });
});

describe("buildGalleryGroups", () => {
  it("puts every photo in one group for 'all'", () => {
    const photos = [makePhoto({ id: "a" }), makePhoto({ id: "b" })];

    const groups = buildGalleryGroups(photos, "all");

    expect(groups).toHaveLength(1);
    expect(groups[0].photos).toHaveLength(2);
  });

  it("groups by captured day and sorts the unknown bucket last", () => {
    const withDay = makePhoto({
      id: "a",
      capturedAt: "2026-01-01T10:00:00.000Z",
    });
    const withoutDay = makePhoto({ id: "b", capturedAt: null });

    const groups = buildGalleryGroups([withoutDay, withDay], "day");

    expect(groups.map((group) => group.key)).toEqual(["2026-01-01", "unknown"]);
  });

  it("groups by rounded location and builds a map link", () => {
    const photo = makePhoto({ latitude: 40.7128, longitude: -74.006 });

    const groups = buildGalleryGroups([photo], "location");

    expect(groups).toHaveLength(1);
    expect(groups[0].key).toBe("40.71,-74.01");
    expect(groups[0].mapUrl).toContain("google.com/maps");
  });
});

describe("selectPhotosById", () => {
  it("resolves selection against the full photo list, ignoring the current filter", () => {
    const photos = [
      makePhoto({ id: "photo-1" }),
      makePhoto({ id: "photo-2" }),
      makePhoto({ id: "photo-3" }),
    ];
    const selectedIds = new Set(["photo-1", "photo-2", "photo-3"]);

    // Simulates selecting all photos, then narrowing to a filter that only
    // shows one of them (e.g. "Liked") before downloading.
    const narrowedView = photos.filter((photo) => photo.id === "photo-2");

    expect(selectPhotosById(narrowedView, selectedIds)).toHaveLength(1);
    expect(selectPhotosById(photos, selectedIds)).toHaveLength(3);
  });

  it("drops ids for photos no longer in the gallery", () => {
    const photos = [makePhoto({ id: "photo-1" })];
    const selectedIds = new Set(["photo-1", "deleted-photo"]);

    expect(
      selectPhotosById(photos, selectedIds).map((photo) => photo.id),
    ).toEqual(["photo-1"]);
  });
});

describe("formatZipDownloadNotice", () => {
  it("returns the base notice unchanged when nothing failed", () => {
    expect(formatZipDownloadNotice("Download started.", [])).toBe(
      "Download started.",
    );
  });

  it("appends a singular note naming the one failed file", () => {
    expect(formatZipDownloadNotice("Download started.", ["DSC01015.jpg"])).toBe(
      "Download started. 1 photo could not be included: DSC01015.jpg.",
    );
  });

  it("appends a plural note listing every failed file", () => {
    expect(
      formatZipDownloadNotice("Download started.", [
        "DSC01015.jpg",
        "DSC01016.jpg",
      ]),
    ).toBe(
      "Download started. 2 photos could not be included: DSC01015.jpg, DSC01016.jpg.",
    );
  });
});

describe("getDefaultPreviewUrl", () => {
  it("prefers the final photo's preview variant when present", () => {
    const photo = makePhoto({
      imageUrl: "https://example.com/original.jpg",
      finalPhoto: {
        originalFilename: "final.jpg",
        contentType: "image/jpeg",
        byteSize: 2_000,
        uploadedAt: "2026-01-01T00:00:00.000Z",
        imageUrl: "https://example.com/final.jpg",
        variants: {
          thumbnail: null,
          preview: {
            imageUrl: "https://example.com/final-preview.jpg",
            contentType: "image/jpeg",
            byteSize: 500,
            width: 100,
            height: 100,
            createdAt: "2026-01-01T00:00:00.000Z",
          },
        },
      },
    });

    expect(getDefaultPreviewUrl(photo)).toBe(
      "https://example.com/final-preview.jpg",
    );
  });

  it("falls back to the original image URL when no variant exists", () => {
    const photo = makePhoto({ imageUrl: "https://example.com/original.jpg" });

    expect(getDefaultPreviewUrl(photo)).toBe(
      "https://example.com/original.jpg",
    );
  });
});

describe("readStorageItem", () => {
  it("returns the stored value", () => {
    const storage = { getItem: vi.fn().mockReturnValue("stored") };

    expect(readStorageItem(() => storage, "key")).toBe("stored");
  });

  it("returns null when merely accessing storage throws", () => {
    // Mirrors Safari's "Block All Cookies": accessing window.localStorage
    // itself throws a SecurityError, before any method is even called.
    expect(readStorageItem(blockedStorageAccess, "key")).toBeNull();
  });

  it("returns null when getItem throws", () => {
    const storage = {
      getItem: vi.fn(() => {
        throw new DOMException("Blocked", "SecurityError");
      }),
    };

    expect(readStorageItem(() => storage, "key")).toBeNull();
  });
});

describe("writeStorageItem", () => {
  it("writes through to storage", () => {
    const setItem = vi.fn();

    writeStorageItem(() => ({ setItem }), "key", "value");

    expect(setItem).toHaveBeenCalledWith("key", "value");
  });

  it("silently no-ops when accessing storage throws", () => {
    expect(() =>
      writeStorageItem(blockedStorageAccess, "key", "value"),
    ).not.toThrow();
  });

  it("silently no-ops when setItem throws", () => {
    const storage = {
      setItem: vi.fn(() => {
        throw new DOMException("Blocked", "SecurityError");
      }),
    };

    expect(() => writeStorageItem(() => storage, "key", "value")).not.toThrow();
  });
});

describe("removeStorageItem", () => {
  it("removes the stored value", () => {
    const removeItem = vi.fn();

    removeStorageItem(() => ({ removeItem }), "key");

    expect(removeItem).toHaveBeenCalledWith("key");
  });

  it("silently no-ops when accessing storage throws", () => {
    expect(() => removeStorageItem(blockedStorageAccess, "key")).not.toThrow();
  });

  it("silently no-ops when removeItem throws", () => {
    const storage = {
      removeItem: vi.fn(() => {
        throw new DOMException("Blocked", "SecurityError");
      }),
    };

    expect(() => removeStorageItem(() => storage, "key")).not.toThrow();
  });
});

describe("getOrCreateVisitorToken", () => {
  it("returns the stored token without generating a new one", () => {
    const storage = {
      getItem: vi.fn().mockReturnValue("existing-token"),
      setItem: vi.fn(),
    };
    const generateToken = vi.fn();

    const token = getOrCreateVisitorToken(() => storage, "key", generateToken);

    expect(token).toBe("existing-token");
    expect(generateToken).not.toHaveBeenCalled();
    expect(storage.setItem).not.toHaveBeenCalled();
  });

  it("generates and stores a new token when none exists", () => {
    const setItem = vi.fn();
    const storage = { getItem: vi.fn().mockReturnValue(null), setItem };

    const token = getOrCreateVisitorToken(
      () => storage,
      "key",
      () => "new-token",
    );

    expect(token).toBe("new-token");
    expect(setItem).toHaveBeenCalledWith("key", "new-token");
  });

  it("falls back to a session-only token when storage is fully blocked", () => {
    const token = getOrCreateVisitorToken(
      blockedStorageAccess,
      "key",
      () => "session-token",
    );

    expect(token).toBe("session-token");
  });
});

describe("isLikelyInAppBrowser", () => {
  it("recognises real browsers as capable of downloading", () => {
    const realBrowsers = [
      // iOS Safari
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      // Chrome on iOS -- a WKWebView, but with a download manager of its own
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.0.0 Mobile/15E148 Safari/604.1",
      // Firefox on iOS
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/133.0 Mobile/15E148 Safari/605.1.15",
      // Chrome on Android
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
      // Desktop Safari
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    ];

    for (const userAgent of realBrowsers) {
      expect(isLikelyInAppBrowser(userAgent)).toBe(false);
    }
  });

  it("recognises webviews that stamp a vendor token", () => {
    const stampedWebviews = [
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/450.0.0.0]",
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36 Instagram 320.0.0.0",
      "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36 MicroMessenger/8.0.0",
    ];

    for (const userAgent of stampedWebviews) {
      expect(isLikelyInAppBrowser(userAgent)).toBe(true);
    }
  });

  /*
   * The case #242 names as the one that defeats UA sniffing: Telegram's iOS
   * browser adds no token of its own, so it is caught by the absence of a
   * Safari token in WKWebView's untouched default UA instead.
   */
  it("recognises an untagged iOS webview by its missing Safari token", () => {
    expect(
      isLikelyInAppBrowser(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
      ),
    ).toBe(true);
  });

  it("recognises Android's system WebView marker", () => {
    expect(
      isLikelyInAppBrowser(
        "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP31; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36",
      ),
    ).toBe(true);
  });

  it("treats an empty user agent as an ordinary browser", () => {
    expect(isLikelyInAppBrowser("")).toBe(false);
  });
});

describe("createIndividualSaveEntries", () => {
  it("prefers the final photo's name and URL when one exists", () => {
    const entries = createIndividualSaveEntries([
      makePhoto({
        id: "photo-1",
        originalFilename: "DSC01015.ARW",
        imageUrl: "https://example.com/original-1.jpg",
        finalPhoto: {
          originalFilename: "DSC01015-edited.jpg",
          contentType: "image/jpeg",
          byteSize: 2_000,
          uploadedAt: "2026-01-02T00:00:00.000Z",
          imageUrl: "https://example.com/final-1.jpg",
          variants: { thumbnail: null, preview: null },
        },
      }),
    ]);

    expect(entries).toEqual([
      {
        photoId: "photo-1",
        filename: "DSC01015-edited.jpg",
        imageUrl: "https://example.com/final-1.jpg",
      },
    ]);
  });

  /*
   * The per-photo list and the ZIP entries have to agree, so the same
   * de-duplication the archive uses applies here too.
   */
  it("de-duplicates names the same way the archive does", () => {
    const entries = createIndividualSaveEntries([
      makePhoto({ id: "photo-1", originalFilename: "DSC01015.ARW" }),
      makePhoto({ id: "photo-2", originalFilename: "DSC01015.ARW" }),
    ]);

    expect(entries.map((entry) => entry.filename)).toEqual([
      "DSC01015.ARW",
      "DSC01015 (2).ARW",
    ]);
  });
});

describe("selectRequestableRawPhotos", () => {
  const ready = {
    filename: "DSC01015.ARW",
    byteSize: 100_000,
    expiresAt: "2026-02-15T00:00:00.000Z",
  };

  it("returns nothing once RAW requests are disabled, however the photos look", () => {
    const photos = [
      makePhoto({ id: "photo-1" }),
      makePhoto({ id: "photo-2", viewerRequestedRaw: true }),
    ];

    expect(selectRequestableRawPhotos(photos, false)).toEqual([]);
  });

  /*
   * Mirrors the inline per-photo button's own rule (getRawRequestState's
   * comment): only "none" invites a brand new ask. Everything already
   * confirming, waiting, ready or collected is excluded from a fresh batch
   * request rather than made unselectable, so a mixed selection still shows
   * an accurate count.
   */
  it("excludes every state except none", () => {
    const photos = [
      makePhoto({ id: "photo-none" }),
      makePhoto({ id: "photo-confirming", viewerRawConfirmationPending: true }),
      makePhoto({ id: "photo-waiting", viewerRequestedRaw: true }),
      makePhoto({
        id: "photo-ready",
        viewerRequestedRaw: true,
        viewerRawDownload: ready,
      }),
      makePhoto({
        id: "photo-collected",
        viewerRequestedRaw: true,
        viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
      }),
    ];

    expect(
      selectRequestableRawPhotos(photos, true).map((photo) => photo.id),
    ).toEqual(["photo-none"]);
  });
});

describe("selectReadyRawPhotos", () => {
  const ready = {
    filename: "DSC01015.ARW",
    byteSize: 100_000,
    expiresAt: "2026-02-15T00:00:00.000Z",
  };

  it("returns only photos with a live download", () => {
    const photos = [
      makePhoto({ id: "photo-none" }),
      makePhoto({
        id: "photo-ready",
        viewerRequestedRaw: true,
        viewerRawDownload: ready,
      }),
      makePhoto({
        id: "photo-collected",
        viewerRequestedRaw: true,
        viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
      }),
    ];

    expect(selectReadyRawPhotos(photos).map((photo) => photo.id)).toEqual([
      "photo-ready",
    ]);
  });

  it("returns an empty list when nothing is ready", () => {
    expect(selectReadyRawPhotos([makePhoto()])).toEqual([]);
  });
});

describe("encodePendingRawBatch / parsePendingRawBatch", () => {
  const batch = {
    shareToken: "share-1",
    photoIds: ["photo-1", "photo-2"],
    displayName: "Guest",
    email: "guest@example.com",
  };

  it("round-trips a batch through encode and parse", () => {
    expect(
      parsePendingRawBatch(encodePendingRawBatch(batch), "share-1"),
    ).toEqual(batch);
  });

  it("returns null when nothing is stored", () => {
    expect(parsePendingRawBatch(null, "share-1")).toBeNull();
  });

  it("returns null on malformed JSON", () => {
    expect(parsePendingRawBatch("not json", "share-1")).toBeNull();
  });

  /*
   * The one mismatch that matters most: a batch left over from a different
   * gallery must never be picked up by this one's confirmation page.
   */
  it("returns null when the share token doesn't match", () => {
    expect(
      parsePendingRawBatch(encodePendingRawBatch(batch), "share-2"),
    ).toBeNull();
  });

  it("returns null when photoIds is empty", () => {
    const raw = encodePendingRawBatch({ ...batch, photoIds: [] });

    expect(parsePendingRawBatch(raw, "share-1")).toBeNull();
  });

  it("returns null on a shape missing required fields", () => {
    expect(
      parsePendingRawBatch(
        JSON.stringify({ shareToken: "share-1" }),
        "share-1",
      ),
    ).toBeNull();
  });
});
