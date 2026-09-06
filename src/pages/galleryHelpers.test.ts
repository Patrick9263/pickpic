import { describe, expect, it } from "vitest";
import {
  buildGalleryGroups,
  comparePhotos,
  createArchiveFilename,
  createUniqueDownloadNames,
  formatApproximateByteSize,
  formatDayGroupLabel,
  getDefaultPreviewUrl,
  sanitizeDownloadFilename,
} from "./galleryHelpers";
import type { GalleryPhotoRecord } from "../types";

function makePhoto(
  overrides: Partial<GalleryPhotoRecord> = {},
): GalleryPhotoRecord {
  return {
    id: "photo-1",
    eventId: "event-1",
    originalFilename: "DSC01015.ARW",
    contentType: "image/jpeg",
    byteSize: 1_000,
    createdAt: "2026-01-01T00:00:00.000Z",
    imageUrl: "https://example.com/photo-1.jpg",
    heartCount: 0,
    workflowStatus: "idle",
    finalPhoto: null,
    variants: { thumbnail: null, preview: null },
    capturedAt: null,
    latitude: null,
    longitude: null,
    comments: [],
    viewerHearted: false,
    ...overrides,
  };
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
