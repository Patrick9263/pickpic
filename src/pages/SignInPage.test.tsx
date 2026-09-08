import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import SignInPage from "./SignInPage";
import { fetchJson } from "../api";
import {
  createFetchJsonRouter,
  type FetchJsonRouter,
} from "../testing/fetchJsonRouter";
import { stubLocation } from "../testing/browserStubs";

vi.mock("../api", () => ({
  fetchJson: vi.fn(),
  getErrorMessage: vi.fn(),
}));

const fetchJsonMock = vi.mocked(fetchJson);

const CONSUME_URL = /\/api\/auth\/magic-link\/consume$/;

let restoreLocation: (() => void) | null = null;

function setUpSignIn(search: string): {
  router: FetchJsonRouter;
  assign: ReturnType<typeof stubLocation>["assign"];
} {
  const location = stubLocation(search);

  restoreLocation = location.restore;

  const router = createFetchJsonRouter();

  fetchJsonMock.mockImplementation(router.fetchJson);

  return { router, assign: location.assign };
}

function consumeCalls(router: FetchJsonRouter) {
  return router.calls.filter((call) => CONSUME_URL.test(call.url));
}

describe("SignInPage", () => {
  beforeEach(() => {
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    restoreLocation?.();
    restoreLocation = null;
    vi.restoreAllMocks();
  });

  /*
   * The regression this page exists to prevent. Mail's press-and-hold preview
   * loads the URL to draw a thumbnail; when consumption lived in a mount
   * effect that preview spent the token before the recipient had copied the
   * link. Rendering must stay inert no matter what is in the query string.
   */
  it("sends no request when a token is present in the URL", () => {
    const { router } = setUpSignIn("?token=magic-token");

    render(<SignInPage />);

    expect(router.calls).toHaveLength(0);
    expect(fetchJsonMock).not.toHaveBeenCalled();
    expect(
      screen.getByRole("button", { name: "Sign in to PickPic" }),
    ).toBeTruthy();
  });

  it("consumes the token once the button is pressed", async () => {
    const { router, assign } = setUpSignIn("?token=magic-token");

    router.post(CONSUME_URL, {});

    render(<SignInPage />);

    fireEvent.click(screen.getByRole("button", { name: "Sign in to PickPic" }));

    await vi.waitFor(() => {
      expect(assign).toHaveBeenCalledWith("/");
    });

    const calls = consumeCalls(router);

    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe("POST");
    expect(calls[0].body).toEqual({ token: "magic-token" });
  });

  it("spends the token once when the button is pressed twice quickly", async () => {
    const { router, assign } = setUpSignIn("?token=magic-token");

    let resolveConsume: (() => void) | null = null;

    router.post(
      CONSUME_URL,
      () =>
        new Promise<Record<string, never>>((resolve) => {
          resolveConsume = () => resolve({});
        }),
    );

    render(<SignInPage />);

    const button = screen.getByRole("button", { name: "Sign in to PickPic" });

    fireEvent.click(button);
    fireEvent.click(button);

    expect(consumeCalls(router)).toHaveLength(1);

    await vi.waitFor(() => {
      expect(resolveConsume).not.toBeNull();
    });

    resolveConsume!();

    await vi.waitFor(() => {
      expect(assign).toHaveBeenCalledWith("/");
    });

    expect(consumeCalls(router)).toHaveLength(1);
  });

  it("falls back to the request form when the token is rejected", async () => {
    const { router } = setUpSignIn("?token=spent-token");

    router.post(CONSUME_URL, () => {
      throw new Error("This sign-in link has already been used.");
    });

    render(<SignInPage />);

    fireEvent.click(screen.getByRole("button", { name: "Sign in to PickPic" }));

    await screen.findByText("This sign-in link has already been used.");

    expect(screen.getByLabelText("Email address")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Sign in to PickPic" })).toBe(
      null,
    );
  });

  it("shows the request form when the URL carries no token", () => {
    const { router } = setUpSignIn("");

    render(<SignInPage />);

    expect(router.calls).toHaveLength(0);
    expect(screen.getByLabelText("Email address")).toBeTruthy();
  });
});
