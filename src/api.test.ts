import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchJson, getErrorMessage } from "./api";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("getErrorMessage", () => {
  it("returns the error field from a JSON body", async () => {
    const response = new Response(JSON.stringify({ error: "Nope." }), {
      status: 400,
    });

    expect(await getErrorMessage(response)).toBe("Nope.");
  });

  it("falls back to the status code when the body has no error field", async () => {
    const response = new Response(JSON.stringify({}), { status: 500 });

    expect(await getErrorMessage(response)).toBe(
      "Request failed with status 500.",
    );
  });

  it("falls back to the status code when the body is not JSON", async () => {
    const response = new Response("not json", { status: 502 });

    expect(await getErrorMessage(response)).toBe(
      "Request failed with status 502.",
    );
  });
});

describe("fetchJson", () => {
  it("resolves with the parsed JSON body on a successful response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
        }),
      ),
    );

    await expect(fetchJson("/api/whatever")).resolves.toEqual({ ok: true });
  });

  it("throws the response's error message when the request fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ error: "Denied." }), {
          status: 403,
        }),
      ),
    );

    await expect(fetchJson("/api/whatever")).rejects.toThrow("Denied.");
  });

  it("passes input and init through to fetch", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(JSON.stringify({}), { status: 200 }));

    vi.stubGlobal("fetch", fetchMock);

    await fetchJson("/api/events", { method: "POST" });

    expect(fetchMock).toHaveBeenCalledWith("/api/events", { method: "POST" });
  });
});
