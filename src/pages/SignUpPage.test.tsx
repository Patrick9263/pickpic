import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import SignUpPage from "./SignUpPage";
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

const CONSUME_URL = /\/api\/auth\/signup\/consume$/;

let restoreLocation: (() => void) | null = null;

function setUpSignUp(search: string): {
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

describe("SignUpPage", () => {
  beforeEach(() => {
    fetchJsonMock.mockReset();
  });

  afterEach(() => {
    restoreLocation?.();
    restoreLocation = null;
    vi.restoreAllMocks();
  });

  /*
   * The regression this test exists to prevent (#377). Mail scanners that run
   * JavaScript load the emailed link before the recipient does; when
   * consumption lived in a mount effect, that load created the account.
   * Rendering must stay inert no matter what is in the query string.
   */
  it("sends no request when a token is present in the URL", () => {
    const { router } = setUpSignUp("?token=signup-token");

    render(<SignUpPage />);

    expect(router.calls).toHaveLength(0);
    expect(fetchJsonMock).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Create account" })).toBeTruthy();
  });

  it("consumes the token once the button is pressed", async () => {
    const { router, assign } = setUpSignUp("?token=signup-token");

    router.post(CONSUME_URL, {});

    render(<SignUpPage />);

    fireEvent.click(screen.getByRole("button", { name: "Create account" }));

    await vi.waitFor(() => {
      expect(assign).toHaveBeenCalledWith("/");
    });

    const calls = consumeCalls(router);

    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe("POST");
    expect(calls[0].body).toEqual({ token: "signup-token" });
  });

  it("spends the token once when the button is pressed twice quickly", async () => {
    const { router, assign } = setUpSignUp("?token=signup-token");

    let resolveConsume: (() => void) | null = null;

    router.post(
      CONSUME_URL,
      () =>
        new Promise<Record<string, never>>((resolve) => {
          resolveConsume = () => resolve({});
        }),
    );

    render(<SignUpPage />);

    const button = screen.getByRole("button", { name: "Create account" });

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

  it("points to sign in when the token is rejected", async () => {
    const { router } = setUpSignUp("?token=spent-token");

    router.post(CONSUME_URL, () => {
      throw new Error("This confirmation link has already been used.");
    });

    render(<SignUpPage />);

    fireEvent.click(screen.getByRole("button", { name: "Create account" }));

    await screen.findByText("This confirmation link has already been used.");

    expect(screen.getByRole("link", { name: "Go to sign in" })).toBeTruthy();
    expect(consumeCalls(router)).toHaveLength(1);
  });

  it("shows the sign-up form when the URL carries no token", () => {
    const { router } = setUpSignUp("");

    render(<SignUpPage />);

    expect(router.calls).toHaveLength(0);
    expect(screen.getByLabelText("Email address")).toBeTruthy();
  });
});
