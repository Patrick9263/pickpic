import { describe, expect, it } from "vitest";
import type { AccessPrincipal, SessionPrincipal } from "./access.ts";
import { isOperatorPrincipal, resolveOperatorEmails } from "./operator.ts";

/*
 * The whole of the operator console's access control is these two functions, so
 * they carry the tests. The D1 query behind the route is exercised in
 * operator.workers.test.ts.
 */

function sessionPrincipal(email: string | null): SessionPrincipal {
  return {
    kind: "session",
    provider: "email",
    subject: "user@example.com",
    email,
    accountId: "account-1",
    accountUserId: "account-user-1",
    sessionId: "session-1",
    role: "owner",
  };
}

function accessPrincipal(email: string | null): AccessPrincipal {
  return {
    kind: "access",
    provider: "cloudflare_access",
    subject: "sso-subject",
    email,
    isLocalDevelopment: false,
  };
}

describe("resolveOperatorEmails", () => {
  it("is empty when OPERATOR_EMAILS is unset", () => {
    expect(resolveOperatorEmails({}).size).toBe(0);
  });

  it("is empty when OPERATOR_EMAILS holds only separators", () => {
    expect(resolveOperatorEmails({ OPERATOR_EMAILS: " , , " }).size).toBe(0);
  });

  it("splits on commas and whitespace and lowercases", () => {
    const operators = resolveOperatorEmails({
      OPERATOR_EMAILS: "One@Example.com, two@example.com\nThree@Example.COM",
    });

    expect([...operators].sort()).toEqual([
      "one@example.com",
      "three@example.com",
      "two@example.com",
    ]);
  });
});

describe("isOperatorPrincipal", () => {
  const environment = { OPERATOR_EMAILS: "operator@example.com" };

  it("admits a session principal whose address is listed", () => {
    expect(
      isOperatorPrincipal(
        sessionPrincipal("operator@example.com"),
        environment,
      ),
    ).toBe(true);
  });

  it("ignores the casing of the principal's own address", () => {
    expect(
      isOperatorPrincipal(
        sessionPrincipal("Operator@Example.com"),
        environment,
      ),
    ).toBe(true);
  });

  it("admits an Access principal whose address is listed", () => {
    expect(
      isOperatorPrincipal(accessPrincipal("operator@example.com"), environment),
    ).toBe(true);
  });

  it("refuses an address that is not listed", () => {
    expect(
      isOperatorPrincipal(sessionPrincipal("someone@example.com"), environment),
    ).toBe(false);
  });

  /*
   * The service-token and local-development principals both carry a null email,
   * so this is the check that keeps either from reading every account.
   */
  it("refuses a principal with no email at all", () => {
    expect(isOperatorPrincipal(sessionPrincipal(null), environment)).toBe(
      false,
    );
    expect(isOperatorPrincipal(accessPrincipal(null), environment)).toBe(false);
  });

  it("refuses everyone when OPERATOR_EMAILS is unset", () => {
    expect(
      isOperatorPrincipal(sessionPrincipal("operator@example.com"), {}),
    ).toBe(false);
  });
});
