import { describe, expect, it } from "vitest";
import { roundPublicCoordinate, safeDecodePathSegment } from "./index.ts";

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
