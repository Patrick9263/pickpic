import { describe, expect, it } from "vitest";
import {
  describeRawRelease,
  describeStopOfferingRawsConfirmation,
  safeDecodeShareToken,
} from "./appHelpers";

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

describe("describeStopOfferingRawsConfirmation", () => {
  it("names the real waiting count", () => {
    expect(describeStopOfferingRawsConfirmation(3, "Smith Wedding")).toBe(
      '3 viewers are waiting for originals from "Smith Wedding". ' +
        "They'll stop waiting, and this gallery will stop offering " +
        "originals. Your files are still on the iPad -- turn originals " +
        "back on and they'll upload again if asked for.",
    );
  });

  it("singularises a single waiting viewer", () => {
    expect(describeStopOfferingRawsConfirmation(1, "Smith Wedding")).toBe(
      '1 viewer is waiting for originals from "Smith Wedding". ' +
        "They'll stop waiting, and this gallery will stop offering " +
        "originals. Your files are still on the iPad -- turn originals " +
        "back on and they'll upload again if asked for.",
    );
  });

  /*
   * Nothing is actually at risk in this case, so the wording shouldn't claim
   * a viewer will be revoked -- but the action is still worth a confirm
   * since it silently flips rawRequestsEnabled off.
   */
  it("skips the revocation framing when nobody is waiting", () => {
    expect(describeStopOfferingRawsConfirmation(0, "Smith Wedding")).toBe(
      'Stop offering originals for "Smith Wedding"? Viewers won\'t be ' +
        "able to request them until you turn requests back on. Your " +
        "files are still on the iPad -- turn originals back on and " +
        "they'll upload again if asked for.",
    );
  });
});
