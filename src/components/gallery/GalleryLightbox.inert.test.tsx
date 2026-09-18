import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "../../pages/GalleryPage";
import { fetchJson } from "../../api";
import { makeGalleryPhoto } from "../../testing/factories";
import { createFetchJsonRouter } from "../../testing/fetchJsonRouter";

/*
 * #291: aria-modal="true" on the lightbox claims the rest of the page is
 * hidden, but nothing enforced that -- Tab could walk focus into the
 * scroll-locked gallery behind the backdrop. Covering the `inert` toggle
 * directly (rather than simulating Tab, which jsdom doesn't implement) is
 * what actually guards the fix: it fails if the effect's dependency list or
 * cleanup ever regresses.
 */
vi.mock("../../api", () => ({
  fetchJson: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

describe("GalleryLightbox focus containment", () => {
  beforeEach(() => {
    window.localStorage.clear();
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("marks the gallery behind it inert while open, and restores it on close", async () => {
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
    fetchJsonMock.mockImplementation(router.fetchJson);

    render(<GalleryPage shareToken="share-token" />);

    const openButton = await screen.findByRole("button", {
      name: /Open DSC01015\.ARW/i,
    });

    const header = document.querySelector<HTMLElement>(".gallery-header");
    const content = document.querySelector<HTMLElement>(".gallery-content");
    expect(header?.inert).toBeFalsy();
    expect(content?.inert).toBeFalsy();

    fireEvent.click(openButton);

    const closeButton = await screen.findByRole("button", {
      name: /Close photo viewer/i,
    });

    expect(header?.inert).toBe(true);
    expect(content?.inert).toBe(true);

    fireEvent.click(closeButton);

    expect(header?.inert).toBeFalsy();
    expect(content?.inert).toBeFalsy();
  });
});
