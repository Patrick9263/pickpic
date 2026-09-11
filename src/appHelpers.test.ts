import { describe, expect, it } from "vitest";
import { describeRawRelease, safeDecodeShareToken } from "./appHelpers";

describe("safeDecodeShareToken", () => {
  it("decodes a normally encoded token", () => {
    expect(safeDecodeShareToken("share%20token")).toBe("share token");
  });

  it("falls back to the raw token when decoding throws", () => {
    expect(safeDecodeShareToken("%zz")).toBe("%zz");
  });
});

describe("describeRawRelease", () => {
  it("reports a release that freed storage", () => {
    expect(
      describeRawRelease({ releasedPhotoCount: 3, awaitingPhotoCount: 0 }),
    ).toBe("Released 3 collected RAW files.");
  });

  it("singularises a release of one file", () => {
    expect(
      describeRawRelease({ releasedPhotoCount: 1, awaitingPhotoCount: 0 }),
    ).toBe("Released 1 collected RAW file.");
  });

  /*
   * The case the button would otherwise look broken in: the photographer
   * clicked, nothing was eligible, and the reason is that nobody has collected
   * anything yet rather than that the request failed.
   */
  it("explains a release that freed nothing but left files waiting", () => {
    expect(
      describeRawRelease({ releasedPhotoCount: 0, awaitingPhotoCount: 2 }),
    ).toBe(
      "No collected RAW files to release. 2 RAW files are still waiting to be collected.",
    );
  });

  it("reports an event with nothing outstanding at all", () => {
    expect(
      describeRawRelease({ releasedPhotoCount: 0, awaitingPhotoCount: 0 }),
    ).toBe("No collected RAW files to release.");
  });

  it("reports a partial release", () => {
    expect(
      describeRawRelease({ releasedPhotoCount: 2, awaitingPhotoCount: 1 }),
    ).toBe(
      "Released 2 collected RAW files. 1 RAW file is still waiting to be collected.",
    );
  });
});
