import { describe, expect, it } from "vitest";
import { safeDecodeShareToken } from "./appHelpers";

describe("safeDecodeShareToken", () => {
  it("decodes a normally encoded token", () => {
    expect(safeDecodeShareToken("share%20token")).toBe("share token");
  });

  it("falls back to the raw token when decoding throws", () => {
    expect(safeDecodeShareToken("%zz")).toBe("%zz");
  });
});
