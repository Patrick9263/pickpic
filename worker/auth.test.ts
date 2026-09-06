import { describe, expect, it } from "vitest";
import {
  isSameOriginRequest,
  isStateChanging,
  normalizeEmail,
  resolveAuthMode,
  type AuthEnvironment,
} from "./auth.ts";

describe("resolveAuthMode", () => {
  it("defaults an unset AUTH_MODE to access", () => {
    expect(resolveAuthMode({} as AuthEnvironment)).toBe("access");
  });

  it("treats a blank AUTH_MODE as access", () => {
    expect(resolveAuthMode({ AUTH_MODE: "  " } as AuthEnvironment)).toBe(
      "access",
    );
  });

  it("accepts session", () => {
    expect(resolveAuthMode({ AUTH_MODE: "session" } as AuthEnvironment)).toBe(
      "session",
    );
  });

  it("fails closed on an unknown value", () => {
    expect(resolveAuthMode({ AUTH_MODE: "bogus" } as AuthEnvironment)).toBe(
      null,
    );
  });
});

describe("isSameOriginRequest", () => {
  it("passes when Origin matches the request URL's origin", () => {
    const request = new Request("https://app.pickpic.photos/api/admin/x", {
      method: "POST",
      headers: { Origin: "https://app.pickpic.photos" },
    });

    expect(isSameOriginRequest(request)).toBe(true);
  });

  it("fails when Origin is missing", () => {
    const request = new Request("https://app.pickpic.photos/api/admin/x", {
      method: "POST",
    });

    expect(isSameOriginRequest(request)).toBe(false);
  });

  it("fails when Origin does not match", () => {
    const request = new Request("https://app.pickpic.photos/api/admin/x", {
      method: "POST",
      headers: { Origin: "https://evil.example" },
    });

    expect(isSameOriginRequest(request)).toBe(false);
  });
});

describe("isStateChanging", () => {
  it("treats GET and HEAD as not state-changing", () => {
    expect(isStateChanging(new Request("https://x/", { method: "GET" }))).toBe(
      false,
    );
    expect(isStateChanging(new Request("https://x/", { method: "HEAD" }))).toBe(
      false,
    );
  });

  it("treats POST, PUT, and DELETE as state-changing", () => {
    for (const method of ["POST", "PUT", "DELETE"]) {
      expect(isStateChanging(new Request("https://x/", { method }))).toBe(true);
    }
  });
});

describe("normalizeEmail", () => {
  it("trims and lowercases a valid address", () => {
    expect(normalizeEmail("  Person@Example.COM  ")).toBe("person@example.com");
  });

  it("rejects non-string input", () => {
    expect(normalizeEmail(undefined)).toBe(null);
    expect(normalizeEmail(42)).toBe(null);
  });

  it("rejects an empty or malformed address", () => {
    expect(normalizeEmail("")).toBe(null);
    expect(normalizeEmail("not-an-email")).toBe(null);
  });
});
