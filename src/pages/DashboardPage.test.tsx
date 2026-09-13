import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen } from "@testing-library/react";
import DashboardPage from "./DashboardPage";
import { fetchJson, getErrorMessage } from "../api";
import {
  createFetchJsonRouter,
  type FetchJsonRouter,
} from "../testing/fetchJsonRouter";
import { makeEvent, makePhoto, makeStorageUsage } from "../testing/factories";
import {
  stubClipboardWriteText,
  userCancels,
  userConfirms,
} from "../testing/browserStubs";
import type { EventRecord, PhotoRecord } from "../types";

function makeReadyTripEvent(overrides: Partial<EventRecord> = {}): EventRecord {
  return makeEvent({
    id: "event-1",
    title: "Trip",
    status: "ready",
    ...overrides,
  });
}

vi.mock("../api", () => ({
  fetchJson: vi.fn(),
  getErrorMessage: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function setUpDashboard(
  options: {
    events?: EventRecord[];
    photosByEvent?: Record<string, PhotoRecord[]>;
  } = {},
): FetchJsonRouter {
  const events = options.events ?? [];
  const photosByEvent = options.photosByEvent ?? {};
  const router = createFetchJsonRouter();

  router.get<{ events: EventRecord[] }>(/\/api\/admin\/events$/, { events });

  for (const eventRecord of events) {
    router.get<{ photos: PhotoRecord[] }>(
      new RegExp(`/api/admin/events/${escapeRegExp(eventRecord.id)}/photos$`),
      { photos: photosByEvent[eventRecord.id] ?? [] },
    );
  }

  router.get(/\/api\/admin\/storage$/, { storage: makeStorageUsage() });

  fetchJsonMock.mockImplementation(router.fetchJson);

  return router;
}

describe("DashboardPage", () => {
  beforeEach(() => {
    fetchJsonMock.mockReset();
    vi.mocked(getErrorMessage).mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("adds a newly created event to the top of the list", async () => {
    const existingEvent = makeEvent({
      id: "event-existing",
      title: "Existing Event",
      status: "ready",
    });

    const router = setUpDashboard({ events: [existingEvent] });

    const createdEvent = makeEvent({
      id: "event-new",
      title: "Summer Barbecue",
    });

    router.post<{ event: EventRecord }>(/\/api\/admin\/events$/, {
      event: createdEvent,
    });

    const { container } = render(<DashboardPage />);

    await screen.findByText("Existing Event");

    const titleInput = screen.getByLabelText("Event title") as HTMLInputElement;

    fireEvent.change(titleInput, { target: { value: "Summer Barbecue" } });
    fireEvent.click(screen.getByRole("button", { name: "Create event" }));

    await screen.findByText("Summer Barbecue");

    expect(titleInput.value).toBe("");

    const eventTitles = Array.from(
      container.querySelectorAll(".event-card h3"),
    ).map((heading) => heading.textContent);

    expect(eventTitles).toEqual(["Summer Barbecue", "Existing Event"]);

    const createCall = router.calls.find(
      (call) =>
        call.method === "POST" && call.url.endsWith("/api/admin/events"),
    );

    expect(createCall?.body).toEqual({ title: "Summer Barbecue" });
  });

  it("does not archive when the user cancels the confirm", async () => {
    const readyEvent = makeReadyTripEvent();

    const router = setUpDashboard({ events: [readyEvent] });

    render(<DashboardPage />);

    const statusSelect = (await screen.findByLabelText(
      "Gallery status",
    )) as HTMLSelectElement;

    userCancels();

    fireEvent.change(statusSelect, { target: { value: "archived" } });

    expect(
      router.calls.some(
        (call) => call.method === "PUT" && call.url.includes("/status"),
      ),
    ).toBe(false);
  });

  it("archives once the user confirms, sending the new status", async () => {
    const readyEvent = makeReadyTripEvent();

    const router = setUpDashboard({ events: [readyEvent] });

    router.put<{ event: EventRecord }>(
      /\/api\/admin\/events\/event-1\/status$/,
      { event: { ...readyEvent, status: "archived" } },
    );

    render(<DashboardPage />);

    const statusSelect = (await screen.findByLabelText(
      "Gallery status",
    )) as HTMLSelectElement;

    userConfirms();

    fireEvent.change(statusSelect, { target: { value: "archived" } });

    /*
     * Archiving moves the event out of the active list (showArchived
     * defaults to false), which unmounts its EventCard entirely, so the
     * only way to observe the update from here is the archived-count
     * toggle appearing.
     */
    await screen.findByRole("button", { name: "Show archived (1)" });

    const statusCall = router.calls.find(
      (call) => call.method === "PUT" && call.url.includes("/status"),
    );

    expect(statusCall?.body).toEqual({ status: "archived" });
  });

  it("warns before disabling RAW requests when a delivery is still awaiting download, and sends nothing if cancelled", async () => {
    const readyEvent = makeReadyTripEvent({ rawRequestsEnabled: true });

    const router = setUpDashboard({
      events: [readyEvent],
      photosByEvent: {
        [readyEvent.id]: [makePhoto({ awaitingRawDownloadCount: 2 })],
      },
    });

    render(<DashboardPage />);

    const toggle = (await screen.findByLabelText(
      "Allow viewers to request original RAW files",
    )) as HTMLInputElement;

    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);

    fireEvent.click(toggle);

    expect(confirmSpy).toHaveBeenCalledWith(expect.stringContaining("2"));
    expect(
      router.calls.some(
        (call) => call.method === "PUT" && call.url.includes("/raw-requests"),
      ),
    ).toBe(false);
  });

  it("disables RAW requests once the outstanding-delivery warning is confirmed", async () => {
    const readyEvent = makeReadyTripEvent({ rawRequestsEnabled: true });

    const router = setUpDashboard({
      events: [readyEvent],
      photosByEvent: {
        [readyEvent.id]: [makePhoto({ awaitingRawDownloadCount: 1 })],
      },
    });

    router.put<{ event: EventRecord }>(
      /\/api\/admin\/events\/event-1\/raw-requests$/,
      { event: { ...readyEvent, rawRequestsEnabled: false } },
    );

    render(<DashboardPage />);

    const toggle = (await screen.findByLabelText(
      "Allow viewers to request original RAW files",
    )) as HTMLInputElement;

    userConfirms();

    fireEvent.click(toggle);

    const rawRequestsCall = await vi.waitFor(() => {
      const call = router.calls.find(
        (candidate) =>
          candidate.method === "PUT" && candidate.url.includes("/raw-requests"),
      );
      if (!call) {
        throw new Error("raw-requests PUT not sent yet");
      }
      return call;
    });

    expect(rawRequestsCall.body).toEqual({ enabled: false });
  });

  it("disables RAW requests with no confirmation when nothing is outstanding", async () => {
    const readyEvent = makeReadyTripEvent({ rawRequestsEnabled: true });

    const router = setUpDashboard({
      events: [readyEvent],
      photosByEvent: {
        [readyEvent.id]: [makePhoto({ awaitingRawDownloadCount: 0 })],
      },
    });

    router.put<{ event: EventRecord }>(
      /\/api\/admin\/events\/event-1\/raw-requests$/,
      { event: { ...readyEvent, rawRequestsEnabled: false } },
    );

    const confirmSpy = vi.spyOn(window, "confirm");

    render(<DashboardPage />);

    const toggle = (await screen.findByLabelText(
      "Allow viewers to request original RAW files",
    )) as HTMLInputElement;

    fireEvent.click(toggle);

    await vi.waitFor(() => {
      expect(
        router.calls.some(
          (call) => call.method === "PUT" && call.url.includes("/raw-requests"),
        ),
      ).toBe(true);
    });

    expect(confirmSpy).not.toHaveBeenCalled();
  });

  it("copies the gallery share link built from VITE_PUBLIC_APP_ORIGIN, then resets the copied indicator", async () => {
    const readyEvent = makeReadyTripEvent({ shareToken: "share-xyz" });

    setUpDashboard({ events: [readyEvent] });

    const writeText = stubClipboardWriteText();
    const setTimeoutSpy = vi.spyOn(window, "setTimeout");

    render(<DashboardPage />);

    const copyButton = await screen.findByRole("button", {
      name: "Copy gallery link",
    });

    fireEvent.click(copyButton);

    await screen.findByRole("button", { name: "Copied!" });

    expect(writeText).toHaveBeenCalledWith("https://pickpic.test/g/share-xyz");

    const resetCallIndex = setTimeoutSpy.mock.calls.findIndex(
      ([, delay]) => delay === 2000,
    );

    const resetCallback = setTimeoutSpy.mock.calls[resetCallIndex]?.[0] as
      (() => void) | undefined;

    expect(resetCallback).toBeTypeOf("function");

    act(() => {
      resetCallback?.();
    });

    /*
     * vi.spyOn calls through to the real window.setTimeout, so the real
     * 2000ms timer is still pending underneath the manual invocation above.
     * Clear it, or it fires ~2s later against an already-unmounted
     * component in the middle of some later, unrelated test.
     */
    const resetTimerId = setTimeoutSpy.mock.results[resetCallIndex]
      ?.value as number;

    clearTimeout(resetTimerId);

    expect(
      screen.getByRole("button", { name: "Copy gallery link" }),
    ).toBeTruthy();
  });

  it("clears the pending copied-indicator timeout on unmount", async () => {
    const readyEvent = makeReadyTripEvent({ shareToken: "share-xyz" });

    setUpDashboard({ events: [readyEvent] });

    stubClipboardWriteText();
    const setTimeoutSpy = vi.spyOn(window, "setTimeout");
    const clearTimeoutSpy = vi.spyOn(window, "clearTimeout");

    const { unmount } = render(<DashboardPage />);

    const copyButton = await screen.findByRole("button", {
      name: "Copy gallery link",
    });

    fireEvent.click(copyButton);

    await screen.findByRole("button", { name: "Copied!" });

    const resetCallIndex = setTimeoutSpy.mock.calls.findIndex(
      ([, delay]) => delay === 2000,
    );

    const resetTimerId = setTimeoutSpy.mock.results[resetCallIndex]?.value;

    unmount();

    expect(clearTimeoutSpy).toHaveBeenCalledWith(resetTimerId);
  });

  it("surfaces a rejected mutation as an error and clears the creating spinner", async () => {
    const router = setUpDashboard();

    router.post(/\/api\/admin\/events$/, () => {
      throw new Error("Titles must be unique.");
    });

    render(<DashboardPage />);

    await screen.findByText("No events yet");

    const titleInput = screen.getByLabelText("Event title") as HTMLInputElement;

    fireEvent.change(titleInput, { target: { value: "Summer Barbecue" } });

    const submitButton = screen.getByRole("button", {
      name: "Create event",
    }) as HTMLButtonElement;

    fireEvent.click(submitButton);

    const alert = await screen.findByRole("alert");

    expect(alert.textContent).toContain("Titles must be unique.");
    expect(submitButton.disabled).toBe(false);
    expect(submitButton.textContent).toBe("Create event");
  });
});
