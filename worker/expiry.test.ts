import { describe, expect, it } from "vitest";
import { isEventExpired } from "./expiry.ts";

const NOW = Date.parse("2026-09-30T12:00:00.000Z");

describe("isEventExpired", () => {
  it("never expires an event with no expires_at", () => {
    expect(isEventExpired(null, NOW)).toBe(false);
    expect(isEventExpired(undefined, NOW)).toBe(false);
  });

  it("is not expired before the deadline", () => {
    expect(isEventExpired("2026-09-30T12:00:00.001Z", NOW)).toBe(false);
  });

  it("is expired at the deadline itself", () => {
    expect(isEventExpired("2026-09-30T12:00:00.000Z", NOW)).toBe(true);
  });

  it("is expired after the deadline", () => {
    expect(isEventExpired("2026-06-01T00:00:00.000Z", NOW)).toBe(true);
  });

  it("fails open on a value it cannot parse", () => {
    expect(isEventExpired("", NOW)).toBe(false);
    expect(isEventExpired("not a date", NOW)).toBe(false);
  });
});
