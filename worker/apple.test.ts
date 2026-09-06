import { describe, expect, it } from "vitest";
import {
  appleStateCookieHeader,
  buildAppleAuthorizeUrl,
  clearedAppleStateCookieHeader,
  readAppleStateCookie,
  resolveAppleConfig,
  type AppleConfig,
  type AppleEnvironment,
} from "./apple.ts";

/*
 * Spelled out rather than imported: the name is not exported because nothing
 * outside apple.ts needs it, and writing the literal here means a rename shows
 * up as a failing test rather than quietly moving a cookie a live browser is
 * still sending under the old name.
 */
const STATE_COOKIE_NAME = "__Host-pickpic_apple_state";

const CONFIG: AppleConfig = {
  clientId: "photos.pickpic.signin",
  redirectUri: "https://app.pickpic.photos/api/auth/apple/callback",
  teamId: "TEAM123456",
  keyId: "KEY1234567",
  privateKey: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----",
};

const COMPLETE_ENVIRONMENT: AppleEnvironment = {
  APPLE_CLIENT_ID: CONFIG.clientId,
  APPLE_REDIRECT_URI: CONFIG.redirectUri,
  APPLE_TEAM_ID: CONFIG.teamId,
  APPLE_KEY_ID: CONFIG.keyId,
  APPLE_PRIVATE_KEY: CONFIG.privateKey,
};

function requestWithCookies(header: string | null): Request {
  return new Request("https://app.pickpic.photos/api/auth/apple/callback", {
    method: "POST",
    headers: header === null ? {} : { Cookie: header },
  });
}

describe("resolveAppleConfig", () => {
  it("returns null for a deployment that configured nothing", () => {
    expect(resolveAppleConfig({})).toBe(null);
  });

  it("resolves a fully configured deployment", () => {
    expect(resolveAppleConfig(COMPLETE_ENVIRONMENT)).toEqual(CONFIG);
  });

  it("returns null when any single value is missing", () => {
    /*
     * All five or none: a half-configured deployment must fail at the door
     * rather than redirect somebody to Apple for a sign-in it cannot finish.
     */
    for (const key of Object.keys(COMPLETE_ENVIRONMENT) as Array<
      keyof AppleEnvironment
    >) {
      const environment = { ...COMPLETE_ENVIRONMENT };

      delete environment[key];

      expect(resolveAppleConfig(environment)).toBe(null);
    }
  });

  it("counts a whitespace-only value as unset", () => {
    expect(
      resolveAppleConfig({ ...COMPLETE_ENVIRONMENT, APPLE_KEY_ID: "   " }),
    ).toBe(null);
  });

  it("trims the surrounding whitespace a pasted secret arrives with", () => {
    expect(
      resolveAppleConfig({
        ...COMPLETE_ENVIRONMENT,
        APPLE_CLIENT_ID: "  photos.pickpic.signin\n",
      })?.clientId,
    ).toBe("photos.pickpic.signin");
  });
});

describe("buildAppleAuthorizeUrl", () => {
  it("points at Apple's authorize endpoint", () => {
    const url = new URL(buildAppleAuthorizeUrl(CONFIG, "state-value"));

    expect(url.origin).toBe("https://appleid.apple.com");
    expect(url.pathname).toBe("/auth/authorize");
  });

  it("carries the client id, redirect URI and state", () => {
    const url = new URL(buildAppleAuthorizeUrl(CONFIG, "state-value"));

    expect(url.searchParams.get("client_id")).toBe(CONFIG.clientId);
    expect(url.searchParams.get("redirect_uri")).toBe(CONFIG.redirectUri);
    expect(url.searchParams.get("state")).toBe("state-value");
  });

  it("asks for a code only, never a browser-delivered identity token", () => {
    /*
     * response_type=code id_token would hand the browser a second copy of the
     * identity token. The only one this worker trusts is the one it fetches
     * itself from Apple's token endpoint.
     */
    expect(
      new URL(buildAppleAuthorizeUrl(CONFIG, "state")).searchParams.get(
        "response_type",
      ),
    ).toBe("code");
  });

  it("requests form_post, which is what makes the callback cross-site", () => {
    const url = new URL(buildAppleAuthorizeUrl(CONFIG, "state"));

    expect(url.searchParams.get("response_mode")).toBe("form_post");
    expect(url.searchParams.get("scope")).toBe("email");
  });

  it("escapes a state value that would otherwise break the query string", () => {
    const state = "a+b&c=d";

    expect(
      new URL(buildAppleAuthorizeUrl(CONFIG, state)).searchParams.get("state"),
    ).toBe(state);
  });
});

describe("appleStateCookieHeader", () => {
  it("is SameSite=None, unlike the session cookie", () => {
    /*
     * Apple returns the user with a cross-site top-level POST, so a Lax cookie
     * would simply not be sent and every sign-in would fail the state check.
     * None is what makes this cookie work as CSRF defence at all.
     */
    expect(appleStateCookieHeader("state-value")).toContain("SameSite=None");
  });

  it("carries the attributes the __Host- prefix requires", () => {
    const header = appleStateCookieHeader("state-value");

    expect(header).toContain(`${STATE_COOKIE_NAME}=state-value`);
    expect(header).toContain("Path=/");
    expect(header).toContain("HttpOnly");
    expect(header).toContain("Secure");
    expect(header).not.toContain("Domain=");
  });

  it("expires in ten minutes so an abandoned redirect leaves nothing redeemable", () => {
    expect(appleStateCookieHeader("state-value")).toContain(
      `Max-Age=${10 * 60}`,
    );
  });
});

describe("clearedAppleStateCookieHeader", () => {
  it("deletes with an empty value and Max-Age=0", () => {
    expect(clearedAppleStateCookieHeader()).toContain(`${STATE_COOKIE_NAME}=;`);
    expect(clearedAppleStateCookieHeader()).toContain("Max-Age=0");
  });

  it("repeats the attributes of the cookie it deletes", () => {
    const attributesOf = (header: string) =>
      header
        .split("; ")
        .slice(1)
        .filter((attribute) => !attribute.startsWith("Max-Age="));

    expect(attributesOf(clearedAppleStateCookieHeader())).toEqual(
      attributesOf(appleStateCookieHeader("state-value")),
    );
  });
});

describe("readAppleStateCookie", () => {
  it("returns null when the request carries no Cookie header", () => {
    expect(readAppleStateCookie(requestWithCookies(null))).toBe(null);
  });

  it("reads the state cookie back out of a header full of others", () => {
    expect(
      readAppleStateCookie(
        requestWithCookies(
          `visitor=v1; ${STATE_COOKIE_NAME}=state-value; theme=dark`,
        ),
      ),
    ).toBe("state-value");
  });

  it("does not mistake the session cookie for the state cookie", () => {
    expect(
      readAppleStateCookie(
        requestWithCookies("__Host-pickpic_session=session-token"),
      ),
    ).toBe(null);
  });

  it("treats an empty value as absent", () => {
    expect(
      readAppleStateCookie(requestWithCookies(`${STATE_COOKIE_NAME}=`)),
    ).toBe(null);
  });
});
