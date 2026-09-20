import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import { makeGalleryPhoto } from "../testing/factories";
import { createFetchJsonRouter } from "../testing/fetchJsonRouter";
import { downloadZip } from "client-zip";

/*
 * #242: in an in-app webview the ZIP cannot be handed to the viewer at all,
 * so building it would download every selected photo -- potentially hundreds
 * of megabytes over cellular -- to produce a file that is then dropped. The
 * load-bearing assertion here is the one about downloadZip *not* being
 * called; the save list appearing is the visible half of the same decision.
 */
vi.mock("../api", () => ({
  fetchJson: vi.fn(),
}));

vi.mock("client-zip", () => ({
  downloadZip: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);
const downloadZipMock = vi.mocked(downloadZip);

/*
 * WKWebView's untouched default UA, which is what Telegram's iOS browser
 * sends -- no vendor token of its own, and no Safari token either.
 */
const TELEGRAM_IOS_USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";

function renderGallery(): void {
  const router = createFetchJsonRouter();

  router.get(/\/api\/galleries\/share-token$/, () => ({
    event: {
      title: "Test Event",
      status: "ready",
      createdAt: "2026-01-01T00:00:00.000Z",
      rawRequestsEnabled: false,
    },
    photos: [
      makeGalleryPhoto({
        id: "photo-1",
        originalFilename: "DSC01015.ARW",
        imageUrl: "https://example.com/photo-1.jpg",
      }),
    ],
  }));
  fetchJsonMock.mockImplementation(router.fetchJson);

  render(<GalleryPage shareToken="share-token" />);
}

describe("GalleryPage ZIP download inside an in-app browser", () => {
  let originalUserAgent: PropertyDescriptor | undefined;

  beforeEach(() => {
    fetchJsonMock.mockReset();
    downloadZipMock.mockReset();
    originalUserAgent = Object.getOwnPropertyDescriptor(
      window.navigator,
      "userAgent",
    );
    Object.defineProperty(window.navigator, "userAgent", {
      configurable: true,
      get: () => TELEGRAM_IOS_USER_AGENT,
    });
  });

  afterEach(() => {
    if (originalUserAgent) {
      Object.defineProperty(window.navigator, "userAgent", originalUserAgent);
    }
    vi.restoreAllMocks();
  });

  it("skips the archive and offers per-photo links instead", async () => {
    renderGallery();

    await screen.findByText("Test Event");

    fireEvent.click(screen.getByRole("button", { name: "Select" }));
    fireEvent.click(screen.getByRole("button", { name: /^Select all/ }));
    fireEvent.click(screen.getByRole("button", { name: /^Download/ }));

    const saveLink = await screen.findByRole("link", { name: "DSC01015.ARW" });

    expect(downloadZipMock).not.toHaveBeenCalled();
    expect(saveLink.getAttribute("href")).toBe(
      "https://example.com/photo-1.jpg",
    );
    expect(saveLink.getAttribute("download")).toBe("DSC01015.ARW");
  });
});
