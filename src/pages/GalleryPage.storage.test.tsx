import { afterEach, beforeEach, describe, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import { makeGalleryPhoto } from "../testing/factories";
import { createFetchJsonRouter } from "../testing/fetchJsonRouter";

/*
 * Safari's "Block All Cookies" setting throws a SecurityError on merely
 * *accessing* window.localStorage, not just on getItem/setItem. Before this
 * fix that threw during GalleryPage's first render (its useState
 * initializers read localStorage directly) and, with no error boundary,
 * unmounted the whole tree into a blank page.
 */
vi.mock("../api", () => ({
  fetchJson: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

describe("GalleryPage with blocked storage", () => {
  let originalDescriptor: PropertyDescriptor | undefined;

  beforeEach(() => {
    fetchJsonMock.mockReset();
    originalDescriptor = Object.getOwnPropertyDescriptor(
      window,
      "localStorage",
    );
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get() {
        throw new DOMException("Blocked", "SecurityError");
      },
    });
  });

  afterEach(() => {
    if (originalDescriptor) {
      Object.defineProperty(window, "localStorage", originalDescriptor);
    }
    vi.restoreAllMocks();
  });

  it("still renders the gallery instead of going blank", async () => {
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

    await screen.findByText("Test Event");
  });
});
