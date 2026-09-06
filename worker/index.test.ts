import { describe, expect, it } from "vitest";
import { roundPublicCoordinate } from "./index.ts";

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
