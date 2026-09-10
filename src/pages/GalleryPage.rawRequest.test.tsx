import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
  type Mock,
} from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import GalleryPage from "./GalleryPage";
import { fetchJson } from "../api";
import { makeGalleryPhoto } from "../testing/factories";
import { createFetchJsonRouter } from "../testing/fetchJsonRouter";
import { userPrompts } from "../testing/browserStubs";

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

/*
 * The RAW download bypasses fetchJson -- it reads bytes, not JSON -- so it
 * needs the three browser pieces jsdom either lacks or cannot observe: global
 * fetch, URL.createObjectURL, and the anchor click that actually saves the
 * file. Returning the recorded clicks is what lets a test assert the download
 * filename, which is the part a viewer sees.
 */
function stubBinaryDownload(options?: { status?: number }): {
  fetchMock: Mock;
  createObjectURL: Mock;
  clicks: HTMLAnchorElement[];
} {
  const status = options?.status ?? 200;

  const fetchMock = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    blob: () => Promise.resolve(new Blob([new Uint8Array([1, 2, 3])])),
  });

  vi.stubGlobal("fetch", fetchMock);

  const createObjectURL = vi.fn().mockReturnValue("blob:raw-download");

  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    writable: true,
    value: createObjectURL,
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    writable: true,
    value: vi.fn(),
  });

  const clicks: HTMLAnchorElement[] = [];

  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(
    function recordClick(this: HTMLAnchorElement) {
      clicks.push(this);
    },
  );

  return { fetchMock, createObjectURL, clicks };
}

describe("GalleryPage RAW file requests", () => {
  beforeEach(() => {
    window.localStorage.clear();
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
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
    router.put(/\/raw-request$/, () => ({
      requested: true,
      rawDownload: null,
      rawDownloadedAt: null,
    }));
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

  /*
   * The third state, and the one #209 exists for. A fulfilled request turns
   * the button from a status into an action, and the action is a plain
   * `fetch` rather than the fetchJson client every other gallery call uses --
   * the response is bytes, not JSON.
   */
  it("offers a download once the viewer's own RAW has been delivered", async () => {
    const photo = makeGalleryPhoto({
      viewerRequestedRaw: true,
      viewerRawDownload: {
        filename: "DSC01015.ARW",
        byteSize: 118_000_000,
        expiresAt: "2026-02-15T00:00:00.000Z",
      },
    });

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
    fetchJsonMock.mockImplementation(router.fetchJson);

    const { fetchMock, createObjectURL, clicks } = stubBinaryDownload();

    render(<GalleryPage shareToken="share-token" />);

    const downloadButton = await screen.findByRole("button", {
      name: /Download the original RAW file for DSC01015\.ARW/i,
    });

    /*
     * Not a toggle any more, so it must not claim a pressed state -- a screen
     * reader announcing "not pressed" on a download would be nonsense.
     */
    expect(downloadButton.getAttribute("aria-pressed")).toBe(null);
    expect(downloadButton.getAttribute("aria-label")).toContain("118 MB");

    fireEvent.click(downloadButton);

    await vi.waitFor(() => {
      expect(createObjectURL).toHaveBeenCalled();
    });

    const [requestUrl, requestInit] = fetchMock.mock.calls[0] as [
      string,
      RequestInit & { headers: Record<string, string> },
    ];

    expect(requestUrl).toBe("/api/galleries/share-token/photos/photo-1/raw");
    expect(requestInit.headers["X-PickPic-Visitor"]).toEqual(
      expect.any(String),
    );

    /*
     * The visitor token is a header, which is exactly why this cannot be a
     * plain download link and has to go through a Blob.
     */
    expect(requestUrl).not.toContain("visitor");
    expect(clicks[0]?.download).toBe("DSC01015.ARW");
  });

  /*
   * The fourth state, which only exists because the RAW is reclaimed after
   * collection: the viewer has already had this file and it is gone again.
   * The button has to re-request rather than cancel, or a viewer who lost the
   * download would delete their own claim on it.
   */
  it("re-requests rather than cancels once a collected RAW has been reclaimed", async () => {
    const photo = makeGalleryPhoto({
      viewerRequestedRaw: true,
      viewerRawDownload: null,
      viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
    });

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
    router.put(/\/raw-request$/, () => ({
      requested: true,
      rawDownload: null,
      rawDownloadedAt: null,
    }));
    fetchJsonMock.mockImplementation(router.fetchJson);

    userPrompts("Ada Lovelace");

    render(<GalleryPage shareToken="share-token" />);

    const againButton = await screen.findByRole("button", {
      name: /Already downloaded; request the RAW file for DSC01015\.ARW again/i,
    });

    fireEvent.click(againButton);

    await screen.findByRole("button", {
      name: /Cancel RAW file request for DSC01015\.ARW/i,
    });

    const rawRequest = router.calls.find((call) =>
      call.url.includes("/raw-request"),
    );

    expect(rawRequest?.method).toBe("PUT");
  });

  it("drops a stale download and offers to ask again when the RAW is already gone", async () => {
    const photo = makeGalleryPhoto({
      viewerRequestedRaw: true,
      viewerRawDownload: {
        filename: "DSC01015.ARW",
        byteSize: 118_000_000,
        expiresAt: "2026-02-15T00:00:00.000Z",
      },
      viewerRawDownloadedAt: "2026-02-02T00:00:00.000Z",
    });

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
    fetchJsonMock.mockImplementation(router.fetchJson);

    stubBinaryDownload({ status: 404 });

    render(<GalleryPage shareToken="share-token" />);

    fireEvent.click(
      await screen.findByRole("button", {
        name: /Download the original RAW file for DSC01015\.ARW/i,
      }),
    );

    await screen.findByRole("button", {
      name: /Already downloaded; request the RAW file for DSC01015\.ARW again/i,
    });
  });
});
