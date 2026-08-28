import {
  forbidden,
  isLocalRequest,
  requireAdminAccess,
  type AccessEnvironment,
  type AdminAccessResult,
} from "./access.ts";
import { sendMagicLinkEmail, type EmailEnvironment } from "./email.ts";
import {
  clearedSessionCookieHeader,
  createSession,
  deleteExpiredSessions,
  generateAuthToken,
  hashAuthToken,
  readSessionCookie,
  resolveSession,
  revokeSession,
  sessionCookieHeader,
  touchSession,
} from "./session.ts";

/*
 * Which guard stands in front of /api/admin/*.
 *
 * 'access'  -- Cloudflare Access, as on admin.pickpic.photos today. This is
 *              also what an unset AUTH_MODE means, so the existing deployments
 *              keep working unchanged after this lands.
 * 'session' -- one of our own session cookies, for the coming
 *              app.pickpic.photos, which has no Cloudflare Access in front of
 *              it.
 *
 * A deployment var rather than a hostname test, because the same bundle serves
 * every origin and hostname matching would silently pick the wrong guard on
 * localhost. Any other value resolves to null and every admin request is
 * refused -- a typo must fail closed, not fall back to the weaker check.
 */
export type AuthMode = "access" | "session";

export type AuthEnvironment = AccessEnvironment &
  EmailEnvironment & {
    AUTH_MODE?: string;
  };

/** How long an emailed link stays redeemable. */
const LOGIN_TOKEN_TTL_MINUTES = 15;

/*
 * A cap on live tokens per user, not a time-window counter: it is the number of
 * simultaneously redeemable links that matters, and this is one indexed COUNT
 * rather than a rate-limiter's worth of state.
 */
const MAX_LIVE_LOGIN_TOKENS = 5;

const MAX_EMAIL_LENGTH = 254;

interface MagicLinkRequestBody {
  email?: unknown;
}

interface ConsumeMagicLinkBody {
  token?: unknown;
}

interface AccountUserRow {
  id: string;
  accountId: string;
  email: string | null;
  role: string;
}

interface LoginTokenRow {
  id: string;
  accountUserId: string;
  expiresAt: string;
  consumedAt: string | null;
}

interface LiveTokenCountRow {
  liveTokens: number;
}

function jsonResponse(
  data: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

function unauthorized(error: string): AdminAccessResult {
  return {
    ok: false,
    response: jsonResponse({ error }, 401),
  };
}

export function resolveAuthMode(environment: AuthEnvironment): AuthMode | null {
  const mode = environment.AUTH_MODE?.trim();

  if (!mode || mode === "access") {
    return "access";
  }

  if (mode === "session") {
    return "session";
  }

  console.error(`AUTH_MODE is set to an unknown value: ${mode}`);

  return null;
}

/*
 * The half of CSRF defence that SameSite=Lax does not cover.
 *
 * Cookies are sent automatically in a way the Access header pair never was, so
 * every state-changing request under a session has to prove it came from our own
 * page. A missing Origin is a rejection rather than a pass: browsers send it on
 * every non-GET, including same-origin ones, so its absence means the caller is
 * not a browser doing what we asked.
 */
function isSameOriginRequest(request: Request): boolean {
  const origin = request.headers.get("Origin");

  return origin !== null && origin === new URL(request.url).origin;
}

function isStateChanging(request: Request): boolean {
  return request.method !== "GET" && request.method !== "HEAD";
}

/*
 * The single entry point fetch uses for /api/admin/*, replacing the direct
 * requireAdminAccess call.
 */
export async function requireAdminPrincipal(
  request: Request,
  database: D1Database,
  environment: AuthEnvironment,
  ctx: ExecutionContext,
): Promise<AdminAccessResult> {
  const mode = resolveAuthMode(environment);

  if (mode === null) {
    return forbidden("Photographer authentication is not configured.");
  }

  if (mode === "access") {
    return requireAdminAccess(request, environment);
  }

  if (isStateChanging(request) && !isSameOriginRequest(request)) {
    return forbidden("This request did not come from PickPic.");
  }

  const token = readSessionCookie(request);

  if (!token) {
    return unauthorized("Sign in to continue.");
  }

  const session = await resolveSession(database, token);

  if (!session) {
    return unauthorized("Your session has expired. Sign in again.");
  }

  if (session.needsTouch) {
    ctx.waitUntil(touchSessionQuietly(database, session.principal.sessionId));
  }

  return { ok: true, principal: session.principal };
}

/*
 * last_used_at is a convenience for a future device list. Failing to write it
 * must never turn a valid session into an error, and this runs after the
 * response has already been sent, so the failure is logged and dropped.
 */
async function touchSessionQuietly(
  database: D1Database,
  sessionId: string,
): Promise<void> {
  try {
    await touchSession(database, sessionId);
  } catch (error) {
    console.error("Failed to refresh a session's last_used_at:", error);
  }
}

/*
 * Every /api/auth/* route. Returns null when nothing matched so fetch can fall
 * through to its generic /api/ 404, matching how handleAdminRequest behaves.
 *
 * These routes are served in both auth modes. On admin.pickpic.photos they sit
 * behind Cloudflare Access and are simply unused; the guard that matters is that
 * a magic link only ever grants what the account_users row it resolved allows.
 */
export async function handleAuthRequest(
  request: Request,
  url: URL,
  database: D1Database,
  environment: AuthEnvironment,
): Promise<Response | null> {
  if (!url.pathname.startsWith("/api/auth/")) {
    return null;
  }

  if (isStateChanging(request) && !isSameOriginRequest(request)) {
    return jsonResponse(
      { error: "This request did not come from PickPic." },
      403,
    );
  }

  if (url.pathname === "/api/auth/magic-link") {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return requestMagicLink(request, url, database, environment);
  }

  if (url.pathname === "/api/auth/magic-link/consume") {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return consumeMagicLink(request, database);
  }

  if (url.pathname === "/api/auth/session") {
    if (request.method === "GET") {
      return getSession(request, database);
    }

    if (request.method === "DELETE") {
      return signOut(request, database);
    }

    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  return null;
}

/*
 * Addresses are stored and compared lowercased. The local part of an address is
 * case-sensitive per RFC 5321, but no mail provider in practice treats it that
 * way, and a login that depends on how someone capitalised their own address is
 * a support ticket rather than a security property.
 */
function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const email = value.trim().toLowerCase();

  if (email.length === 0 || email.length > MAX_EMAIL_LENGTH) {
    return null;
  }

  if (!/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(email)) {
    return null;
  }

  return email;
}

/*
 * Always answers the same way for a well-formed address, whether or not it has
 * an account. Reporting "no such account" here would turn this endpoint into a
 * way to test which of a photographer's clients are PickPic customers.
 *
 * There is deliberately no sign-up path: an address only receives a link if
 * account_users already holds a row for it. Creating accounts is the next
 * roadmap step, and folding it in here would mean anyone who can reach the
 * endpoint can create one.
 */
async function requestMagicLink(
  request: Request,
  url: URL,
  database: D1Database,
  environment: AuthEnvironment,
): Promise<Response> {
  let body: MagicLinkRequestBody;

  try {
    body = (await request.json()) as MagicLinkRequestBody;
  } catch {
    return jsonResponse({ error: "Enter an email address." }, 400);
  }

  const email = normalizeEmail(body.email);

  if (!email) {
    return jsonResponse({ error: "Enter a valid email address." }, 400);
  }

  const accepted = jsonResponse({ ok: true });

  const accountUser = await database
    .prepare(
      `
        SELECT
          u.id AS id,
          u.account_id AS accountId,
          u.email AS email,
          u.role AS role
        FROM account_users u
        JOIN accounts a ON a.id = u.account_id
        WHERE u.auth_provider = 'email'
          AND u.auth_subject = ?
          AND a.status = 'active'
      `,
    )
    .bind(email)
    .first<AccountUserRow>();

  if (!accountUser) {
    return accepted;
  }

  const now = new Date();

  const liveTokens = await database
    .prepare(
      `
        SELECT COUNT(*) AS liveTokens
        FROM auth_login_tokens
        WHERE account_user_id = ?
          AND consumed_at IS NULL
          AND expires_at > ?
      `,
    )
    .bind(accountUser.id, now.toISOString())
    .first<LiveTokenCountRow>();

  if ((liveTokens?.liveTokens ?? 0) >= MAX_LIVE_LOGIN_TOKENS) {
    /*
     * Silently, and with the same body as a success: the caller learning that
     * they are being throttled also tells them the address exists.
     */
    return accepted;
  }

  const token = generateAuthToken();

  const tokenId = crypto.randomUUID();

  await database
    .prepare(
      `
        INSERT INTO auth_login_tokens (
          id,
          account_user_id,
          token_hash,
          created_at,
          expires_at,
          consumed_at
        )
        VALUES (?, ?, ?, ?, ?, NULL)
      `,
    )
    .bind(
      tokenId,
      accountUser.id,
      await hashAuthToken(token),
      now.toISOString(),
      new Date(
        now.getTime() + LOGIN_TOKEN_TTL_MINUTES * 60 * 1000,
      ).toISOString(),
    )
    .run();

  /*
   * The link points back at the origin the request arrived on, so localhost
   * links work in development and production links work in production without a
   * var to keep in sync. Both hostnames this worker answers on are custom
   * domains, so the origin cannot be attacker-chosen.
   *
   * It lands on a page rather than an endpoint because mail scanners -- Outlook
   * Safe Links, Gmail's fetcher -- follow every URL in a message with a GET. A
   * one-time token behind a GET would be burnt before the recipient clicked, so
   * /sign-in reads the token from the fragment-free query string and redeems it
   * with a POST, which scanners do not issue.
   */
  const link = new URL("/sign-in", url.origin);

  link.searchParams.set("token", token);

  try {
    await sendMagicLinkEmail(
      environment,
      {
        to: email,
        url: link.toString(),
        expiresInMinutes: LOGIN_TOKEN_TTL_MINUTES,
      },
      isLocalRequest(request),
    );
  } catch (error) {
    /*
     * The row has to go back if the link never left the building. It was
     * inserted first so that a send can never deliver a token the database does
     * not know about -- but leaving it behind would spend one of this user's
     * MAX_LIVE_LOGIN_TOKENS slots on a link nobody received, and a provider
     * outage would then lock them out for the token lifetime on top of being
     * unable to email them at all.
     */
    await database
      .prepare(
        `
          DELETE FROM auth_login_tokens
          WHERE id = ?
        `,
      )
      .bind(tokenId)
      .run();

    console.error("Failed to send a magic-link email:", error);

    return jsonResponse(
      { error: "The sign-in email could not be sent. Try again." },
      502,
    );
  }

  return accepted;
}

/*
 * Redeems a token for a session. Deliberately not bound to the browser that
 * asked for the link: requesting on a phone and opening on a desktop is a normal
 * thing to do, and binding would break it for a threat -- an attacker who can
 * read the inbox -- that already owns the account.
 */
async function consumeMagicLink(
  request: Request,
  database: D1Database,
): Promise<Response> {
  let body: ConsumeMagicLinkBody;

  try {
    body = (await request.json()) as ConsumeMagicLinkBody;
  } catch {
    return jsonResponse({ error: "This sign-in link is not valid." }, 400);
  }

  if (typeof body.token !== "string" || body.token.trim().length === 0) {
    return jsonResponse({ error: "This sign-in link is not valid." }, 400);
  }

  const tokenHash = await hashAuthToken(body.token.trim());

  const row = await database
    .prepare(
      `
        SELECT
          t.id AS id,
          t.account_user_id AS accountUserId,
          t.expires_at AS expiresAt,
          t.consumed_at AS consumedAt
        FROM auth_login_tokens t
        JOIN account_users u ON u.id = t.account_user_id
        JOIN accounts a ON a.id = u.account_id
        WHERE t.token_hash = ?
          AND a.status = 'active'
      `,
    )
    .bind(tokenHash)
    .first<LoginTokenRow>();

  /*
   * Expired, already used, and never issued are one message on purpose. The
   * distinction is of no use to the person who clicked and of real use to
   * someone guessing.
   */
  if (
    !row ||
    row.consumedAt !== null ||
    Date.parse(row.expiresAt) <= Date.now()
  ) {
    return jsonResponse(
      { error: "This sign-in link has expired or has already been used." },
      400,
    );
  }

  /*
   * Marking the token consumed before the session exists, and only where it is
   * still unconsumed, is what makes redemption single-use under two simultaneous
   * clicks: the second UPDATE changes no row and stops here.
   */
  const consumed = await database
    .prepare(
      `
        UPDATE auth_login_tokens
        SET consumed_at = ?
        WHERE id = ?
          AND consumed_at IS NULL
      `,
    )
    .bind(new Date().toISOString(), row.id)
    .run();

  if (consumed.meta.changes !== 1) {
    return jsonResponse(
      { error: "This sign-in link has expired or has already been used." },
      400,
    );
  }

  const token = await createSession(database, row.accountUserId, request);

  await deleteConsumedLoginTokens(database, row.accountUserId);

  await deleteExpiredSessions(database, row.accountUserId);

  return jsonResponse({ ok: true }, 200, {
    "Set-Cookie": sessionCookieHeader(token),
  });
}

/*
 * Opportunistic and scoped to the one user, for the same reason
 * deleteExpiredSessions is: there is no cron here, and a spent token is dead
 * weight the moment the session exists.
 */
async function deleteConsumedLoginTokens(
  database: D1Database,
  accountUserId: string,
): Promise<void> {
  await database
    .prepare(
      `
        DELETE FROM auth_login_tokens
        WHERE account_user_id = ?
          AND (consumed_at IS NOT NULL OR expires_at <= ?)
      `,
    )
    .bind(accountUserId, new Date().toISOString())
    .run();
}

async function getSession(
  request: Request,
  database: D1Database,
): Promise<Response> {
  const token = readSessionCookie(request);

  const session = token ? await resolveSession(database, token) : null;

  if (!session) {
    return jsonResponse({ error: "Sign in to continue." }, 401);
  }

  const account = await database
    .prepare(
      `
        SELECT id, name, status
        FROM accounts
        WHERE id = ?
      `,
    )
    .bind(session.principal.accountId)
    .first<{ id: string; name: string; status: string }>();

  if (!account || account.status !== "active") {
    return jsonResponse({ error: "This account is not available." }, 403);
  }

  return jsonResponse({
    account: { id: account.id, name: account.name },
    user: {
      id: session.principal.accountUserId,
      email: session.principal.email,
      role: session.principal.role,
    },
  });
}

/*
 * Revokes only the session that made the request, so signing out of a laptop
 * leaves the phone signed in. The cookie is cleared either way -- a caller
 * holding an already-invalid cookie still deserves to be rid of it.
 */
async function signOut(
  request: Request,
  database: D1Database,
): Promise<Response> {
  const token = readSessionCookie(request);

  if (token) {
    const session = await resolveSession(database, token);

    if (session) {
      await revokeSession(database, session.principal.sessionId);
    }
  }

  return jsonResponse({ ok: true }, 200, {
    "Set-Cookie": clearedSessionCookieHeader(),
  });
}
