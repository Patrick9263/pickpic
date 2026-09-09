import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import { makeGalleryPhoto } from "../testing/factories";
import { createFetchJsonRouter } from "../testing/fetchJsonRouter";

/*
 * A RAW file request is a distinct kind of ask from a heart -- a heart is an
 * edit request, this is a request for the untouched original -- so it gets
 * its own render-and-click coverage rather than being assumed to work
 * because hearting does (#180).
 */
vi.mock("../api", () => ({
  fetchJson: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

describe("GalleryPage RAW file requests", () => {
  beforeEach(() => {
    window.localStorage.clear();
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("lets a viewer request the RAW file for a photo when the event allows it", async () => {
    const photo = makeGalleryPhoto();

    const router = createFetchJsonRouter();
    router.get(/\/api\/galleries\/share-token$/, () => ({
      event: {
        title: "Test Event",
        status: "ready",
        createdAt: "2026-01-01T00:00:00.000Z",
        rawRequestsEnabled: true,
      },
      photos: [photo],
    }));
    router.put(/\/raw-request$/, () => ({ requested: true }));
    fetchJsonMock.mockImplementation(router.fetchJson);

    vi.spyOn(window, "prompt").mockReturnValue("Ada Lovelace");

    render(<GalleryPage shareToken="share-token" />);

    const rawRequestButton = await screen.findByRole("button", {
      name: /Request the original RAW file for DSC01015\.ARW/i,
    });

    expect(rawRequestButton.getAttribute("aria-pressed")).toBe("false");

    fireEvent.click(rawRequestButton);

    const updatedButton = await screen.findByRole("button", {
      name: /Cancel RAW file request for DSC01015\.ARW/i,
    });

    expect(updatedButton.getAttribute("aria-pressed")).toBe("true");

    const rawRequest = router.calls.find((call) =>
      call.url.includes("/raw-request"),
    );

    expect(rawRequest?.url).toContain(
      "/api/galleries/share-token/photos/photo-1/raw-request",
    );
    expect(rawRequest?.method).toBe("PUT");
  });

  it("does not render a RAW request button when the event has not opted in", async () => {
    const photo = makeGalleryPhoto();

    const router = createFetchJsonRouter();
    router.get(/\/api\/galleries\/share-token$/, () => ({
      event: {
        title: "Test Event",
        status: "ready",
        createdAt: "2026-01-01T00:00:00.000Z",
        rawRequestsEnabled: false,
      },
      photos: [photo],
    }));
    fetchJsonMock.mockImplementation(router.fetchJson);

    render(<GalleryPage shareToken="share-token" />);

    await screen.findByRole("button", {
      name: /Request an edit of DSC01015\.ARW/i,
    });

    expect(screen.queryByRole("button", { name: /RAW file/i })).toBe(null);
  });
});
