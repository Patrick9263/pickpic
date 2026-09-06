import { describe, expect, it } from "vitest";
import {
  SESSION_COOKIE_NAME,
  clearedSessionCookieHeader,
  generateAuthToken,
  readSessionCookie,
  sessionCookieHeader,
} from "./session.ts";

function requestWithCookies(header: string | null): Request {
  return new Request("https://app.pickpic.photos/api/admin/events", {
    headers: header === null ? {} : { Cookie: header },
  });
}

describe("generateAuthToken", () => {
  it("emits 32 bytes as unpadded base64url", () => {
    /*
     * 43 characters is exactly ceil(32 / 3) * 4 minus the one '=' the encoder
     * strips, so a wrong length here means the token is not 32 bytes wide.
     */
    expect(generateAuthToken()).toHaveLength(43);
    expect(generateAuthToken()).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("never emits a character a cookie value or query string would escape", () => {
    for (let attempt = 0; attempt < 64; attempt += 1) {
      expect(generateAuthToken()).not.toMatch(/[+/=]/);
    }
  });

  it("does not repeat", () => {
    const tokens = new Set(
      Array.from({ length: 128 }, () => generateAuthToken()),
    );

    expect(tokens.size).toBe(128);
  });
});

describe("readSessionCookie", () => {
  it("returns null when the request carries no Cookie header", () => {
    expect(readSessionCookie(requestWithCookies(null))).toBe(null);
  });

  it("reads the session cookie when it is the only one", () => {
    expect(
      readSessionCookie(requestWithCookies(`${SESSION_COOKIE_NAME}=abc123`)),
    ).toBe("abc123");
  });

  it("finds the session cookie among others, whatever its position", () => {
    expect(
      readSessionCookie(
        requestWithCookies(
          `visitor=v1; ${SESSION_COOKIE_NAME}=abc123; theme=dark`,
        ),
      ),
    ).toBe("abc123");
  });

  it("tolerates the whitespace browsers put after each semicolon", () => {
    expect(
      readSessionCookie(
        requestWithCookies(`visitor=v1;   ${SESSION_COOKIE_NAME}=abc123  `),
      ),
    ).toBe("abc123");
  });

  it("matches the cookie name exactly rather than by suffix", () => {
    /*
     * The __Host- prefix stops another host setting this cookie, but nothing
     * stops one setting a differently-named cookie that ends with the same
     * text, so the name comparison has to be whole-token.
     */
    expect(
      readSessionCookie(
        requestWithCookies(`not_${SESSION_COOKIE_NAME}=abc123`),
      ),
    ).toBe(null);
  });

  it("treats an empty value as absent", () => {
    expect(
      readSessionCookie(requestWithCookies(`${SESSION_COOKIE_NAME}=`)),
    ).toBe(null);
  });

  it("skips a valueless segment rather than tripping over it", () => {
    expect(
      readSessionCookie(
        requestWithCookies(`broken; ${SESSION_COOKIE_NAME}=abc123`),
      ),
    ).toBe("abc123");
  });
});

describe("sessionCookieHeader", () => {
  it("carries the attributes the __Host- prefix requires", () => {
    /*
     * A browser rejects a __Host- cookie outright unless it is Secure, Path=/
     * and carries no Domain, so these are not stylistic -- dropping one makes
     * sign-in fail everywhere at once.
     */
    const header = sessionCookieHeader("token-value");

    expect(header).toContain(`${SESSION_COOKIE_NAME}=token-value`);
    expect(header).toContain("Path=/");
    expect(header).toContain("HttpOnly");
    expect(header).toContain("Secure");
    expect(header).not.toContain("Domain=");
  });

  it("is SameSite=Lax, the half of CSRF defence the Origin check does not cover", () => {
    expect(sessionCookieHeader("token-value")).toContain("SameSite=Lax");
  });

  it("expires thirty days out, absolute rather than sliding", () => {
    expect(sessionCookieHeader("token-value")).toContain(
      `Max-Age=${60 * 60 * 24 * 30}`,
    );
  });
});

describe("clearedSessionCookieHeader", () => {
  it("deletes with an empty value and Max-Age=0", () => {
    expect(clearedSessionCookieHeader()).toContain(`${SESSION_COOKIE_NAME}=;`);
    expect(clearedSessionCookieHeader()).toContain("Max-Age=0");
  });

  it("repeats the attributes of the cookie it deletes", () => {
    /*
     * A browser only drops the cookie when the delete matches the attributes it
     * was set with; a mismatch silently leaves the original in place and the
     * user stays signed in after signing out.
     */
    const attributesOf = (header: string) =>
      header
        .split("; ")
        .slice(1)
        .filter((attribute) => !attribute.startsWith("Max-Age="));

    expect(attributesOf(clearedSessionCookieHeader())).toEqual(
      attributesOf(sessionCookieHeader("token-value")),
    );
  });
});
