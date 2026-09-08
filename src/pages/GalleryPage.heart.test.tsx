import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import { makeGalleryPhoto } from "../testing/factories";
import { createFetchJsonRouter } from "../testing/fetchJsonRouter";

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

describe("GalleryPage hearting", () => {
  beforeEach(() => {
    window.localStorage.clear();
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("lets a viewer heart a photo as an edit request", async () => {
    const photo = makeGalleryPhoto();

    const router = createFetchJsonRouter();
    router.get(/\/api\/galleries\/share-token$/, () => ({
      event: {
        title: "Test Event",
        status: "ready",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
      photos: [photo],
    }));
    router.put(/\/heart$/, () => ({ hearted: true, heartCount: 1 }));
    fetchJsonMock.mockImplementation(router.fetchJson);

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

    const heartRequest = router.calls.find((call) =>
      call.url.includes("/heart"),
    );

    expect(heartRequest?.url).toContain(
      "/api/galleries/share-token/photos/photo-1/heart",
    );
    expect(heartRequest?.method).toBe("PUT");
  });

  it("does not send a heart request when the gallery is closed", async () => {
    const photo = makeGalleryPhoto();

    const router = createFetchJsonRouter();
    router.get(/\/api\/galleries\/share-token$/, () => ({
      event: {
        title: "Closed Event",
        status: "completed",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
      photos: [photo],
    }));
    fetchJsonMock.mockImplementation(router.fetchJson);

    render(<GalleryPage shareToken="share-token" />);

    const heartButton = await screen.findByRole("button", {
      name: /Gallery closed/i,
    });

    expect((heartButton as HTMLButtonElement).disabled).toBe(true);
  });
});
