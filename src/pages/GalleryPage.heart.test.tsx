import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import type { GalleryPhotoRecord } from "../types";

/*
 * "A heart is an edit request, not a social reaction" (CLAUDE.md) is the
 * core data-model framing this app is built on, so it is the one
 * interactive path worth a full render-and-click test rather than just
 * unit-testing the extracted helpers.
 */
vi.mock("../api", () => ({
  fetchJson: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

function makePhoto(
  overrides: Partial<GalleryPhotoRecord> = {},
): GalleryPhotoRecord {
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
    variants: { thumbnail: null, preview: null },
    capturedAt: null,
    latitude: null,
    longitude: null,
    comments: [],
    viewerHearted: false,
    ...overrides,
  };
}

describe("GalleryPage hearting", () => {
  beforeEach(() => {
    window.localStorage.clear();
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("lets a viewer heart a photo as an edit request", async () => {
    const photo = makePhoto();

    fetchJsonMock.mockImplementation(async (input, init) => {
      const url = String(input);

      if (init?.method === "PUT" && url.includes("/heart")) {
        return { hearted: true, heartCount: 1 };
      }

      return {
        event: {
          title: "Test Event",
          status: "ready",
          createdAt: "2026-01-01T00:00:00.000Z",
        },
        photos: [photo],
      };
    });

    vi.spyOn(window, "prompt").mockReturnValue("Ada Lovelace");

    render(<GalleryPage shareToken="share-token" />);

    const heartButton = await screen.findByRole("button", {
      name: /Request an edit of DSC01015\.ARW/i,
    });

    expect(heartButton.getAttribute("aria-pressed")).toBe("false");

    fireEvent.click(heartButton);

    const updatedHeartButton = await screen.findByRole("button", {
      name: /Remove edit request for DSC01015\.ARW/i,
    });

    expect(updatedHeartButton.getAttribute("aria-pressed")).toBe("true");
    expect(updatedHeartButton.textContent).toContain("1");

    const heartRequest = fetchJsonMock.mock.calls.find(([input]) =>
      String(input).includes("/heart"),
    );

    expect(heartRequest?.[0]).toContain(
      "/api/galleries/share-token/photos/photo-1/heart",
    );
    expect(heartRequest?.[1]).toMatchObject({ method: "PUT" });
  });

  it("does not send a heart request when the gallery is closed", async () => {
    const photo = makePhoto();

    fetchJsonMock.mockResolvedValue({
      event: {
        title: "Closed Event",
        status: "completed",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
      photos: [photo],
    });

    render(<GalleryPage shareToken="share-token" />);

    const heartButton = await screen.findByRole("button", {
      name: /Gallery closed/i,
    });

    expect((heartButton as HTMLButtonElement).disabled).toBe(true);
  });
});
