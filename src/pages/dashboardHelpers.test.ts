import { describe, expect, it } from "vitest";
import {
  collectFulfilledPhotoEntries,
  getMissingVariantSources,
  getQueueDisplayImage,
} from "./dashboardHelpers";
import { makePhoto } from "../testing/factories";
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

describe("getMissingVariantSources", () => {
  it("returns nothing when the original has complete variants and there is no final", () => {
    expect(
      getMissingVariantSources(makePhoto({ variants: completeVariantSet })),
    ).toEqual([]);
  });

  it("flags the original when its variants are incomplete", () => {
    const photo = makePhoto({ variants: missingVariantSet });

    expect(getMissingVariantSources(photo)).toEqual(["original"]);
  });

  it("flags the final when it exists with incomplete variants", () => {
    const photo = makePhoto({
      variants: completeVariantSet,
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
      variants: completeVariantSet,
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

describe("getQueueDisplayImage", () => {
  it("uses the original's thumbnail when not showing the final", () => {
    const photo = makePhoto({
      imageUrl: "https://example.com/proof.jpg",
      variants: completeVariantSet,
    });

    expect(getQueueDisplayImage(photo, false)).toEqual({
      thumbnailUrl: "https://example.com/thumb.jpg",
      width: 10,
      height: 10,
      fullImageUrl: "https://example.com/proof.jpg",
    });
  });

  it("falls back to the full proof when no thumbnail variant exists", () => {
    const photo = makePhoto({
      imageUrl: "https://example.com/proof.jpg",
      variants: missingVariantSet,
    });

    expect(getQueueDisplayImage(photo, false)).toEqual({
      thumbnailUrl: "https://example.com/proof.jpg",
      width: undefined,
      height: undefined,
      fullImageUrl: "https://example.com/proof.jpg",
    });
  });

  it("shows the delivered final, not the pre-edit proof, for a revision request", () => {
    const photo = makePhoto({
      imageUrl: "https://example.com/proof.jpg",
      variants: completeVariantSet,
      workflowStatus: "final",
      finalPhoto: {
        originalFilename: "final.jpg",
        contentType: "image/jpeg",
        byteSize: 2_000,
        uploadedAt: "2026-01-01T00:00:00.000Z",
        imageUrl: "https://example.com/final.jpg",
        variants: {
          thumbnail: {
            imageUrl: "https://example.com/final-thumb.jpg",
            contentType: "image/jpeg",
            byteSize: 150,
            width: 15,
            height: 15,
            createdAt: "2026-01-01T00:00:00.000Z",
          },
          preview: null,
        },
      },
    });

    expect(getQueueDisplayImage(photo, true)).toEqual({
      thumbnailUrl: "https://example.com/final-thumb.jpg",
      width: 15,
      height: 15,
      fullImageUrl: "https://example.com/final.jpg",
    });
  });

  it("falls back to the proof if a revision is requested but no final exists", () => {
    const photo = makePhoto({
      imageUrl: "https://example.com/proof.jpg",
      variants: completeVariantSet,
      finalPhoto: null,
    });

    expect(getQueueDisplayImage(photo, true)).toEqual({
      thumbnailUrl: "https://example.com/thumb.jpg",
      width: 10,
      height: 10,
      fullImageUrl: "https://example.com/proof.jpg",
    });
  });
});

describe("collectFulfilledPhotoEntries", () => {
  it("collects every entry when all requests succeed", () => {
    const photoA = [makePhoto({ id: "photo-a" })];
    const photoB = [makePhoto({ id: "photo-b" })];

    const { entries, hasFailure } = collectFulfilledPhotoEntries([
      { status: "fulfilled", value: ["event-a", photoA] },
      { status: "fulfilled", value: ["event-b", photoB] },
    ]);

    expect(entries).toEqual([
      ["event-a", photoA],
      ["event-b", photoB],
    ]);
    expect(hasFailure).toBe(false);
  });

  it("keeps the successful entries and flags the failure when one request rejects", () => {
    const photoA = [makePhoto({ id: "photo-a" })];

    const { entries, hasFailure } = collectFulfilledPhotoEntries([
      { status: "fulfilled", value: ["event-a", photoA] },
      { status: "rejected", reason: new Error("network error") },
    ]);

    expect(entries).toEqual([["event-a", photoA]]);
    expect(hasFailure).toBe(true);
  });

  it("returns no entries and flags the failure when every request rejects", () => {
    const results: PromiseSettledResult<readonly [string, PhotoRecord[]]>[] = [
      { status: "rejected", reason: new Error("network error") },
      { status: "rejected", reason: new Error("timeout") },
    ];

    const { entries, hasFailure } = collectFulfilledPhotoEntries(results);

    expect(entries).toEqual([]);
    expect(hasFailure).toBe(true);
  });
});
