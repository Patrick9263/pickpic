import { describe, expect, it } from "vitest";
import type { OperatorAccountSummary } from "../types";
import { formatLastUpload, summariseOperatorAccounts } from "./operatorHelpers";

function account(
  overrides: Partial<OperatorAccountSummary> = {},
): OperatorAccountSummary {
  return {
    id: "account-1",
    name: "Account",
    status: "active",
    plan: "free",
    storageBytes: 0,
    storageCapBytes: 2_000_000_000,
    eventCount: 0,
    photoCount: 0,
    lastPhotoUploadedAt: null,
    createdAt: "2026-09-01T00:00:00.000Z",
    users: [],
    ...overrides,
  };
}

describe("summariseOperatorAccounts", () => {
  it("returns zeroes for an empty list", () => {
    expect(summariseOperatorAccounts([])).toEqual({
      accountCount: 0,
      userCount: 0,
      uploadingAccountCount: 0,
      idleAccountCount: 0,
      totalStorageBytes: 0,
    });
  });

  it("counts users and storage across accounts", () => {
    const totals = summariseOperatorAccounts([
      account({
        id: "a",
        photoCount: 12,
        storageBytes: 1000,
        users: [
          {
            id: "u1",
            email: "one@example.com",
            role: "owner",
            authProvider: "email",
            createdAt: "2026-09-01T00:00:00.000Z",
          },
          {
            id: "u2",
            email: "one@icloud.com",
            role: "owner",
            authProvider: "apple",
            createdAt: "2026-09-02T00:00:00.000Z",
          },
        ],
      }),
      account({
        id: "b",
        storageBytes: 500,
        users: [
          {
            id: "u3",
            email: "two@example.com",
            role: "owner",
            authProvider: "email",
            createdAt: "2026-09-03T00:00:00.000Z",
          },
        ],
      }),
    ]);

    expect(totals).toEqual({
      accountCount: 2,
      userCount: 3,
      uploadingAccountCount: 1,
      idleAccountCount: 1,
      totalStorageBytes: 1500,
    });
  });

  /*
   * An account that made an event and then uploaded nothing is precisely the
   * "signed up and never used it" case, so it must not read as active.
   */
  it("counts an account with events but no photos as idle", () => {
    const totals = summariseOperatorAccounts([
      account({ eventCount: 3, photoCount: 0 }),
    ]);

    expect(totals.uploadingAccountCount).toBe(0);
    expect(totals.idleAccountCount).toBe(1);
  });
});

describe("formatLastUpload", () => {
  const now = new Date("2026-09-21T12:00:00.000Z");

  it("reports an account that never uploaded", () => {
    expect(formatLastUpload(null, now)).toBe("Never");
  });

  it("reports an unparseable timestamp rather than NaN", () => {
    expect(formatLastUpload("not a date", now)).toBe("Unknown");
  });

  it("collapses the last hour", () => {
    expect(formatLastUpload("2026-09-21T11:30:00.000Z", now)).toBe("Just now");
  });

  it("reports a future timestamp as just now rather than negative", () => {
    expect(formatLastUpload("2026-09-22T00:00:00.000Z", now)).toBe("Just now");
  });

  it("reports hours within the day", () => {
    expect(formatLastUpload("2026-09-21T03:00:00.000Z", now)).toBe("9h ago");
  });

  it("reports days up to the cutoff", () => {
    expect(formatLastUpload("2026-09-18T12:00:00.000Z", now)).toBe("3d ago");
    expect(formatLastUpload("2026-08-23T12:00:00.000Z", now)).toBe("29d ago");
  });

  it("falls back to a date past the cutoff", () => {
    expect(formatLastUpload("2026-06-19T12:00:00.000Z", now)).toBe(
      "2026-06-19",
    );
  });
});
