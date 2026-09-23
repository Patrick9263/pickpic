import { describe, expect, it } from "vitest";
import {
  SESSION_COOKIE_NAME,
  clearedSessionCookieHeader,
  generateAuthToken,
  readSessionCookie,
  refreshedSessionCookieHeader,
  sessionCookieHeader,
  slideSessionExpiry,
  withSetCookie,
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

  it("starts with the thirty-day idle window", () => {
    expect(sessionCookieHeader("token-value")).toContain(
      `Max-Age=${60 * 60 * 24 * 30}`,
    );
  });
});

const DAY = 24 * 60 * 60 * 1000;

describe("slideSessionExpiry", () => {
  const created = Date.parse("2026-01-01T00:00:00.000Z");

  function iso(time: number): string {
    return new Date(time).toISOString();
  }

  it("does not move within a day of the last extension", () => {
    /*
     * The throttle is what keeps an active session at one D1 write a day
     * rather than one per request.
     */
    const now = created + 12 * 60 * 60 * 1000;

    expect(
      slideSessionExpiry(iso(created), iso(created + 30 * DAY), now),
    ).toEqual({ expiresAt: iso(created + 30 * DAY), extended: false });
  });

  it("slides to thirty days after now once a day has passed", () => {
    const now = created + 10 * DAY;

    expect(
      slideSessionExpiry(iso(created), iso(created + 30 * DAY), now),
    ).toEqual({ expiresAt: iso(now + 30 * DAY), extended: true });
  });

  it("never passes a year from creation however active the session is", () => {
    const now = created + 350 * DAY;

    expect(
      slideSessionExpiry(iso(created), iso(created + 340 * DAY), now),
    ).toEqual({ expiresAt: iso(created + 365 * DAY), extended: true });
  });

  it("stops writing once the cap is reached", () => {
    const now = created + 360 * DAY;

    expect(
      slideSessionExpiry(iso(created), iso(created + 365 * DAY), now),
    ).toEqual({ expiresAt: iso(created + 365 * DAY), extended: false });
  });

  it("never shortens an expiry that is already later", () => {
    const now = created + 5 * DAY;

    expect(
      slideSessionExpiry(iso(created), iso(created + 60 * DAY), now),
    ).toEqual({ expiresAt: iso(created + 60 * DAY), extended: false });
  });
});

describe("refreshedSessionCookieHeader", () => {
  it("sets Max-Age to land on the row's expiry", () => {
    const now = Date.parse("2026-01-01T00:00:00.000Z");

    const header = refreshedSessionCookieHeader(
      "token-value",
      new Date(now + 20 * DAY).toISOString(),
      now,
    );

    expect(header).toContain(`${SESSION_COOKIE_NAME}=token-value`);
    expect(header).toContain(`Max-Age=${20 * 24 * 60 * 60}`);
    expect(header).toContain("HttpOnly");
  });

  it("never emits a negative Max-Age", () => {
    const now = Date.parse("2026-01-01T00:00:00.000Z");

    expect(
      refreshedSessionCookieHeader(
        "token-value",
        new Date(now - DAY).toISOString(),
        now,
      ),
    ).toContain("Max-Age=0");
  });
});

describe("withSetCookie", () => {
  it("returns the response untouched when there is nothing to set", () => {
    const response = new Response("body");

    expect(withSetCookie(response, undefined)).toBe(response);
  });

  it("adds the cookie and keeps status, body and other headers", async () => {
    const response = withSetCookie(
      new Response("body", {
        status: 201,
        headers: { "Content-Type": "text/plain" },
      }),
      "a=b",
    );

    expect(response.status).toBe(201);
    expect(response.headers.get("Content-Type")).toBe("text/plain");
    expect(response.headers.get("Set-Cookie")).toBe("a=b");
    expect(await response.text()).toBe("body");
  });

  it("makes a publicly cacheable response uncacheable", () => {
    /*
     * A stored JPEG is public and immutable; a shared cache keeping one with a
     * session cookie attached would hand that cookie to the next viewer.
     */
    const response = withSetCookie(
      new Response("jpeg", {
        headers: { "Cache-Control": "public, max-age=31536000, immutable" },
      }),
      "a=b",
    );

    expect(response.headers.get("Cache-Control")).toBe("no-store");
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
