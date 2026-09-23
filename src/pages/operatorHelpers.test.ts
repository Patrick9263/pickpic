import { describe, expect, it } from "vitest";
import type { OperatorAccountRecord } from "../types";
import {
  EMPTY_ORPHAN_SCAN,
  formatDaysAgo,
  mergeOrphanScans,
  ORPHAN_SAMPLE_LIMIT,
  summarizeOperatorAccounts,
} from "./operatorHelpers";

const DAY_MS = 24 * 60 * 60 * 1000;

const NOW = Date.parse("2026-09-21T12:00:00.000Z");

function account(
  overrides: Partial<OperatorAccountRecord> = {},
): OperatorAccountRecord {
  return {
    id: "account-1",
    name: "Studio",
    status: "active",
    plan: "free",
    createdAt: "2026-09-01T00:00:00.000Z",
    databaseId: null,
    storageBytes: 0,
    storageCapBytes: 1000,
    rawDeliveryTtlMs: 604800000,
    eventCount: 0,
    photoCount: 0,
    lastEventAt: null,
    lastPhotoAt: null,
    users: [],
    ...overrides,
  };
}

describe("summarizeOperatorAccounts", () => {
  it("returns zeroes for an empty list", () => {
    expect(summarizeOperatorAccounts([])).toEqual({
      accountCount: 0,
      userCount: 0,
      eventCount: 0,
      photoCount: 0,
      storageBytes: 0,
      dormantCount: 0,
    });
  });

  it("folds counts across accounts", () => {
    const totals = summarizeOperatorAccounts([
      account({
        id: "a",
        eventCount: 2,
        photoCount: 40,
        storageBytes: 1000,
        users: [
          {
            id: "u1",
            email: "a@example.com",
            role: "owner",
            authProvider: "email",
            createdAt: "2026-09-01T00:00:00.000Z",
            lastSeenAt: null,
          },
        ],
      }),
      account({ id: "b", eventCount: 1, photoCount: 5, storageBytes: 500 }),
    ]);

    expect(totals).toEqual({
      accountCount: 2,
      userCount: 1,
      eventCount: 3,
      photoCount: 45,
      storageBytes: 1500,
      dormantCount: 0,
    });
  });

  it("counts an account with events but no photos as dormant", () => {
    // Creating an event is a tap; uploading is the thing that says the pipeline
    // actually worked for someone, which is why photoCount is the test.
    const totals = summarizeOperatorAccounts([
      account({ eventCount: 3, photoCount: 0 }),
    ]);

    expect(totals.dormantCount).toBe(1);
  });
});

describe("formatDaysAgo", () => {
  it("reports a missing timestamp as never", () => {
    expect(formatDaysAgo(null, NOW)).toBe("never");
  });

  it("reports an unparseable timestamp as unknown", () => {
    expect(formatDaysAgo("not a date", NOW)).toBe("unknown");
  });

  it("reports the same day as today", () => {
    expect(formatDaysAgo("2026-09-21T01:00:00.000Z", NOW)).toBe("today");
  });

  it("does not report a future timestamp as a negative day count", () => {
    expect(formatDaysAgo("2026-09-25T00:00:00.000Z", NOW)).toBe("today");
  });

  it("reports one day as yesterday", () => {
    expect(formatDaysAgo(new Date(NOW - DAY_MS).toISOString(), NOW)).toBe(
      "yesterday",
    );
  });

  it("reports whole days beyond that", () => {
    expect(formatDaysAgo(new Date(NOW - 9 * DAY_MS).toISOString(), NOW)).toBe(
      "9 days ago",
    );
  });
});

function orphanSample(key: string) {
  return {
    key,
    size: 1,
    uploaded: "2026-09-01T00:00:00.000Z",
    eventExists: true,
  };
}

describe("mergeOrphanScans", () => {
  it("sums every counter and resumes from the newer slice's cursor", () => {
    const slice = {
      ...EMPTY_ORPHAN_SCAN,
      scannedObjects: 10,
      scannedBytes: 100,
      orphanCount: 2,
      orphanBytes: 20,
      staleOrphanCount: 1,
      staleOrphanBytes: 5,
      missingEventOrphanCount: 1,
      missingEventOrphanBytes: 7,
    };

    const merged = mergeOrphanScans(
      mergeOrphanScans(EMPTY_ORPHAN_SCAN, { ...slice, cursor: "a" }),
      { ...slice, cursor: null },
    );

    expect(merged).toEqual({
      scannedObjects: 20,
      scannedBytes: 200,
      orphanCount: 4,
      orphanBytes: 40,
      staleOrphanCount: 2,
      staleOrphanBytes: 10,
      missingEventOrphanCount: 2,
      missingEventOrphanBytes: 14,
      sample: [],
      cursor: null,
    });
  });

  it("keeps the earliest samples and stops at the limit", () => {
    const first = Array.from({ length: ORPHAN_SAMPLE_LIMIT - 1 }, (_, index) =>
      orphanSample(`first-${index}`),
    );

    const merged = mergeOrphanScans(
      { ...EMPTY_ORPHAN_SCAN, sample: first },
      {
        ...EMPTY_ORPHAN_SCAN,
        sample: [orphanSample("second-0"), orphanSample("second-1")],
      },
    );

    expect(merged.sample).toHaveLength(ORPHAN_SAMPLE_LIMIT);
    expect(merged.sample.at(-1)?.key).toBe("second-0");
  });
});
