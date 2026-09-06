import { describe, expect, it } from "vitest";
import {
  forbidden,
  isLocalRequest,
  requireOwnerRole,
  type AccessPrincipal,
  type SessionPrincipal,
} from "./access.ts";

const ACCESS_PRINCIPAL: AccessPrincipal = {
  kind: "access",
  provider: "cloudflare_access",
  subject: "operator@example.com",
  email: "operator@example.com",
  isLocalDevelopment: false,
};

const SERVICE_TOKEN_PRINCIPAL: AccessPrincipal = {
  kind: "access",
  provider: "cloudflare_access_service_token",
  subject: "pickpic-ipad",
  email: null,
  isLocalDevelopment: false,
};

function sessionPrincipal(role: string): SessionPrincipal {
  return {
    kind: "session",
    provider: "email",
    subject: "person@example.com",
    email: "person@example.com",
    accountId: "11111111-1111-4111-8111-111111111111",
    accountUserId: "22222222-2222-4222-8222-222222222222",
    sessionId: "33333333-3333-4333-8333-333333333333",
    role,
  };
}

describe("isLocalRequest", () => {
  it("recognises every hostname `npm run dev` can be reached on", () => {
    for (const origin of [
      "http://localhost:5173",
      "http://127.0.0.1:5173",
      "http://[::1]:5173",
    ]) {
      expect(isLocalRequest(new Request(`${origin}/api/admin/events`))).toBe(
        true,
      );
    }
  });

  it("rejects the deployed origins", () => {
    for (const origin of [
      "https://pickpic.photos",
      "https://admin.pickpic.photos",
      "https://app.pickpic.photos",
    ]) {
      expect(isLocalRequest(new Request(`${origin}/api/admin/events`))).toBe(
        false,
      );
    }
  });

  it("matches the whole hostname, not a prefix of it", () => {
    /*
     * This check is what skips Cloudflare Access entirely, so a hostname an
     * attacker can register that merely starts with "localhost" must not
     * satisfy it.
     */
    expect(
      isLocalRequest(new Request("https://localhost.evil.example/api/admin/x")),
    ).toBe(false);
  });
});

describe("requireOwnerRole", () => {
  it("lets an Access principal through, SSO or service token", () => {
    /*
     * Both Access shapes are already fully privileged and have no
     * account_users row to carry a narrower role, so there is nothing to check.
     */
    expect(requireOwnerRole(ACCESS_PRINCIPAL)).toBe(null);
    expect(requireOwnerRole(SERVICE_TOKEN_PRINCIPAL)).toBe(null);
  });

  it("lets an owner session through", () => {
    expect(requireOwnerRole(sessionPrincipal("owner"))).toBe(null);
  });

  it("refuses any other session role", async () => {
    for (const role of ["member", "viewer", "", "Owner"]) {
      const response = requireOwnerRole(sessionPrincipal(role));

      expect(response?.status).toBe(403);
      expect(response?.headers.get("Cache-Control")).toBe("no-store");
      await expect(response?.json()).resolves.toEqual({
        error: "This action requires the account owner.",
      });
    }
  });
});

describe("forbidden", () => {
  it("is a not-ok result carrying a 403 that is never cached", async () => {
    const result = forbidden("Photographer authentication is required.");

    expect(result.ok).toBe(false);

    /*
     * Narrowed rather than asserted: the union exists so a caller cannot test
     * it backwards, and the test should read it the same way a handler does.
     */
    if (result.ok) {
      throw new Error("forbidden() must never produce an ok result.");
    }

    expect(result.response.status).toBe(403);
    expect(result.response.headers.get("Cache-Control")).toBe("no-store");
    await expect(result.response.json()).resolves.toEqual({
      error: "Photographer authentication is required.",
    });
  });
});
