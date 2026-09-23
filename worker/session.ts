import type { SessionPrincipal } from "./access.ts";

/*
 * The __Host- prefix is not decoration. It makes the browser refuse the cookie
 * unless it is Secure, Path=/ and carries no Domain attribute, which means no
 * other host under pickpic.photos -- including admin.pickpic.photos and any
 * future subdomain -- can set a cookie of this name that the app would then
 * read. Chromium treats localhost as a secure context and honours the Secure
 * attribute there unchanged against `npm run dev` over plain http, but Safari
 * does not extend that exception to cookies -- it silently drops this cookie
 * on localhost, so a local sign-in there looks like it bounces back to the
 * sign-in page even though the token was redeemed and the session was created.
 * Test session sign-in locally with Chromium; production is real HTTPS, where
 * every browser -- including Safari -- honours Secure with no exception needed.
 */
export const SESSION_COOKIE_NAME = "__Host-pickpic_session";

/*
 * Sliding, with an absolute cap (#194). A session dies after thirty days
 * without use, so an abandoned or forgotten device still loses access on its
 * own; an active one keeps being extended, so a user -- above all on the iPad,
 * whose only way back in is pasting a magic link -- no longer meets that on a
 * fixed schedule.
 */
const SESSION_IDLE_TTL_SECONDS = 60 * 60 * 24 * 30;

/*
 * The ceiling that sliding can never pass, measured from created_at. This is
 * what still bounds the life of a stolen cookie that is being actively used:
 * per-device revocation is out of scope, so time is the only thing that
 * eventually cuts off a copy nobody knows to sign out.
 */
const SESSION_MAX_LIFETIME_SECONDS = 60 * 60 * 24 * 365;

/*
 * expires_at only moves when it would move by at least this much, so an
 * active session costs one D1 write a day rather than one per request. A day
 * is invisible against a thirty-day idle window.
 */
const SESSION_EXTEND_THRESHOLD_SECONDS = 60 * 60 * 24;

/*
 * last_used_at is only worth a write when it would move by something a human
 * would notice on a device list, so a busy tab does not cost a D1 write per
 * request.
 */
const LAST_USED_REFRESH_SECONDS = 60 * 60;

/** Enough to recognise a device, short enough not to bloat the row. */
const MAX_USER_AGENT_LENGTH = 200;

interface SessionRow {
  sessionId: string;
  createdAt: string;
  expiresAt: string;
  lastUsedAt: string;
  accountUserId: string;
  accountId: string;
  authProvider: string;
  authSubject: string;
  email: string | null;
  role: string;
}

export interface ResolvedSession {
  principal: SessionPrincipal;

  /*
   * When last_used_at is stale enough to be worth refreshing. The caller does
   * that through ctx.waitUntil so it never delays a response.
   */
  needsTouch: boolean;

  /*
   * The new expires_at when the sliding window has moved far enough to be
   * worth writing, or null. Written by touchSession alongside last_used_at,
   * and the reason the caller re-issues the cookie: a browser would otherwise
   * drop it at its original Max-Age however far the row had been extended.
   */
  extendedExpiresAt: string | null;

  /*
   * The row's expiry after any extension above, so a re-issued cookie's
   * Max-Age can match it exactly.
   */
  expiresAt: string;
}

/*
 * Pure so the sliding rule is testable without D1. Never shortens: a row whose
 * expires_at is already beyond the candidate (a session created before #194
 * cannot be, but a clock skew between isolates could) is left alone.
 */
export function slideSessionExpiry(
  createdAt: string,
  expiresAt: string,
  now: number,
): { expiresAt: string; extended: boolean } {
  const current = Date.parse(expiresAt);

  const candidate = Math.min(
    now + SESSION_IDLE_TTL_SECONDS * 1000,
    Date.parse(createdAt) + SESSION_MAX_LIFETIME_SECONDS * 1000,
  );

  if (candidate - current < SESSION_EXTEND_THRESHOLD_SECONDS * 1000) {
    return { expiresAt, extended: false };
  }

  return { expiresAt: new Date(candidate).toISOString(), extended: true };
}

/*
 * 32 bytes of CSPRNG output, base64url so it survives a cookie value and a URL
 * query string without escaping. Used for both session cookies and magic-link
 * tokens -- there is no reason for them to differ in strength.
 */
export function generateAuthToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));

  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/*
 * Only the hash is ever stored, so a database dump cannot be replayed as a
 * login. A plain equality lookup on the hash is safe without a constant-time
 * compare: the attacker would have to guess 256 bits to produce a row at all,
 * and the index leaks nothing beyond whether that guess hit.
 */
export async function hashAuthToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );

  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

export function readSessionCookie(request: Request): string | null {
  const header = request.headers.get("Cookie");

  if (!header) {
    return null;
  }

  for (const part of header.split(";")) {
    const separator = part.indexOf("=");

    if (separator === -1) {
      continue;
    }

    if (part.slice(0, separator).trim() !== SESSION_COOKIE_NAME) {
      continue;
    }

    const value = part.slice(separator + 1).trim();

    return value.length > 0 ? value : null;
  }

  return null;
}

function serializeSessionCookie(value: string, maxAgeSeconds: number): string {
  /*
   * SameSite=Lax is half of the CSRF story -- it keeps the cookie off
   * cross-site POSTs entirely. The other half is the Origin check in
   * requireSameOrigin, because Lax still allows a cross-site top-level GET.
   */
  return [
    `${SESSION_COOKIE_NAME}=${value}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    `Max-Age=${maxAgeSeconds}`,
  ].join("; ");
}

export function sessionCookieHeader(token: string): string {
  return serializeSessionCookie(token, SESSION_IDLE_TTL_SECONDS);
}

/*
 * The same cookie re-issued after the session row's expiry has slid, with a
 * Max-Age that lands on the row's new expires_at. The value never changes, so
 * the browser just gets a later expiry. The iPad does not handle cookies and
 * so never sees this on its own: it keeps the expiry it parsed at sign-in in
 * the Keychain and treats itself as signed out once that passes, however far
 * the row has slid, until it learns to read the refreshed Max-Age.
 */
export function refreshedSessionCookieHeader(
  token: string,
  expiresAt: string,
  now: number,
): string {
  return serializeSessionCookie(
    token,
    Math.max(0, Math.floor((Date.parse(expiresAt) - now) / 1000)),
  );
}

/*
 * Appends a Set-Cookie to a response built elsewhere. Copying first because a
 * Response from Response.json, fetch or an R2 body may have immutable headers.
 *
 * Cache-Control is forced to no-store because the response might be a stored
 * JPEG marked public and immutable, and a shared cache holding a copy of
 * someone's session cookie would hand it to the next person to ask. This
 * happens at most once a day per session, so the lost caching is one image.
 */
export function withSetCookie(
  response: Response,
  cookie: string | undefined,
): Response {
  if (!cookie) {
    return response;
  }

  const copy = new Response(response.body, response);

  copy.headers.append("Set-Cookie", cookie);
  copy.headers.set("Cache-Control", "no-store");

  return copy;
}

/*
 * Max-Age=0 with an empty value, which is how a cookie is deleted. The
 * attributes have to match the ones it was set with or the browser keeps the
 * original.
 */
export function clearedSessionCookieHeader(): string {
  return serializeSessionCookie("", 0);
}

export async function createSession(
  database: D1Database,
  accountUserId: string,
  request: Request,
): Promise<string> {
  const token = generateAuthToken();

  const now = new Date();

  const nowIso = now.toISOString();

  const expiresAt = new Date(
    now.getTime() + SESSION_IDLE_TTL_SECONDS * 1000,
  ).toISOString();

  const userAgent =
    request.headers.get("User-Agent")?.slice(0, MAX_USER_AGENT_LENGTH) ?? null;

  await database
    .prepare(
      `
        INSERT INTO auth_sessions (
          id,
          account_user_id,
          token_hash,
          created_at,
          expires_at,
          last_used_at,
          revoked_at,
          user_agent
        )
        VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
      `,
    )
    .bind(
      crypto.randomUUID(),
      accountUserId,
      await hashAuthToken(token),
      nowIso,
      expiresAt,
      nowIso,
      userAgent,
    )
    .run();

  return token;
}

/*
 * The account is reached by joining account_users rather than read from a copy
 * on the session row, so a session can never name an account its user no longer
 * belongs to.
 */
export async function resolveSession(
  database: D1Database,
  token: string,
): Promise<ResolvedSession | null> {
  const row = await database
    .prepare(
      `
        SELECT
          s.id AS sessionId,
          s.created_at AS createdAt,
          s.expires_at AS expiresAt,
          s.last_used_at AS lastUsedAt,
          u.id AS accountUserId,
          u.account_id AS accountId,
          u.auth_provider AS authProvider,
          u.auth_subject AS authSubject,
          u.email AS email,
          u.role AS role
        FROM auth_sessions s
        JOIN account_users u ON u.id = s.account_user_id
        WHERE s.token_hash = ?
          AND s.revoked_at IS NULL
      `,
    )
    .bind(await hashAuthToken(token))
    .first<SessionRow>();

  if (!row) {
    return null;
  }

  const now = Date.now();

  if (Date.parse(row.expiresAt) <= now) {
    return null;
  }

  const slid = slideSessionExpiry(row.createdAt, row.expiresAt, now);

  return {
    principal: {
      kind: "session",
      provider: row.authProvider,
      subject: row.authSubject,
      email: row.email,
      accountId: row.accountId,
      accountUserId: row.accountUserId,
      sessionId: row.sessionId,
      role: row.role,
    },
    needsTouch:
      slid.extended ||
      now - Date.parse(row.lastUsedAt) >= LAST_USED_REFRESH_SECONDS * 1000,
    extendedExpiresAt: slid.extended ? slid.expiresAt : null,
    expiresAt: slid.expiresAt,
  };
}

/*
 * One write for both columns, so sliding costs nothing beyond the last_used_at
 * refresh that was already happening. MAX() keeps two concurrent requests from
 * moving expires_at backwards; ISO-8601 strings in one format compare
 * correctly as text. revoked_at IS NULL stops a request that raced a sign-out
 * from extending a revoked row -- harmless, since revoked rows never resolve,
 * but pointless.
 */
export async function touchSession(
  database: D1Database,
  sessionId: string,
  extendedExpiresAt: string | null,
): Promise<void> {
  await database
    .prepare(
      `
        UPDATE auth_sessions
        SET last_used_at = ?,
            expires_at = MAX(expires_at, COALESCE(?, expires_at))
        WHERE id = ?
          AND revoked_at IS NULL
      `,
    )
    .bind(new Date().toISOString(), extendedExpiresAt, sessionId)
    .run();
}

export async function revokeSession(
  database: D1Database,
  sessionId: string,
): Promise<void> {
  await database
    .prepare(
      `
        UPDATE auth_sessions
        SET revoked_at = ?
        WHERE id = ?
          AND revoked_at IS NULL
      `,
    )
    .bind(new Date().toISOString(), sessionId)
    .run();
}

/*
 * Opportunistic cleanup, run when a user signs in rather than on a schedule:
 * there is no cron in this worker and expired rows are only ever dead weight.
 * Scoped to the one user so it can never be an unbounded delete.
 */
export async function deleteExpiredSessions(
  database: D1Database,
  accountUserId: string,
): Promise<void> {
  await database
    .prepare(
      `
        DELETE FROM auth_sessions
        WHERE account_user_id = ?
          AND expires_at <= ?
      `,
    )
    .bind(accountUserId, new Date().toISOString())
    .run();
}
