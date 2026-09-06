import { describe, expect, it } from "vitest";
import { getMissingVariantSources } from "./dashboardHelpers";
import type { PhotoRecord } from "../types";

const completeVariantSet = {
  thumbnail: {
    imageUrl: "https://example.com/thumb.jpg",
    contentType: "image/jpeg",
    byteSize: 100,
    width: 10,
    height: 10,
    createdAt: "2026-01-01T00:00:00.000Z",
  },
  preview: {
    imageUrl: "https://example.com/preview.jpg",
    contentType: "image/jpeg",
    byteSize: 200,
    width: 20,
    height: 20,
    createdAt: "2026-01-01T00:00:00.000Z",
  },
};

const missingVariantSet = { thumbnail: null, preview: null };

function makePhoto(overrides: Partial<PhotoRecord> = {}): PhotoRecord {
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
    variants: completeVariantSet,
    capturedAt: null,
    latitude: null,
    longitude: null,
    comments: [],
    ...overrides,
  };
}

describe("getMissingVariantSources", () => {
  it("returns nothing when the original has complete variants and there is no final", () => {
    expect(getMissingVariantSources(makePhoto())).toEqual([]);
  });

  it("flags the original when its variants are incomplete", () => {
    const photo = makePhoto({ variants: missingVariantSet });

    expect(getMissingVariantSources(photo)).toEqual(["original"]);
  });

  it("flags the final when it exists with incomplete variants", () => {
    const photo = makePhoto({
      finalPhoto: {
        originalFilename: "final.jpg",
        contentType: "image/jpeg",
        byteSize: 2_000,
        uploadedAt: "2026-01-01T00:00:00.000Z",
        imageUrl: "https://example.com/final.jpg",
        variants: missingVariantSet,
      },
    });

    expect(getMissingVariantSources(photo)).toEqual(["final"]);
  });

  it("flags both sources when both are incomplete", () => {
    const photo = makePhoto({
      variants: missingVariantSet,
      finalPhoto: {
        originalFilename: "final.jpg",
        contentType: "image/jpeg",
        byteSize: 2_000,
        uploadedAt: "2026-01-01T00:00:00.000Z",
        imageUrl: "https://example.com/final.jpg",
        variants: missingVariantSet,
      },
    });

    expect(getMissingVariantSources(photo)).toEqual(["original", "final"]);
  });

  it("does not flag a final with complete variants", () => {
    const photo = makePhoto({
      finalPhoto: {
        originalFilename: "final.jpg",
        contentType: "image/jpeg",
        byteSize: 2_000,
        uploadedAt: "2026-01-01T00:00:00.000Z",
        imageUrl: "https://example.com/final.jpg",
        variants: completeVariantSet,
      },
    });

    expect(getMissingVariantSources(photo)).toEqual([]);
  });
});
