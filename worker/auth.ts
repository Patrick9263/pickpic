import {
  forbidden,
  isLocalRequest,
  requireAdminAccess,
  type AccessEnvironment,
  type AdminAccessResult,
} from "./access.ts";
import {
  appleStateCookieHeader,
  buildAppleAuthorizeUrl,
  clearedAppleStateCookieHeader,
  exchangeAppleCode,
  readAppleStateCookie,
  resolveAppleConfig,
  verifyAppleIdentityToken,
  type AppleEnvironment,
} from "./apple.ts";
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
  EmailEnvironment &
  AppleEnvironment & {
    AUTH_MODE?: string;

    /*
     * The single shared code /api/auth/signup requires, and the whole of its
     * access control. A secret rather than a var in wrangler.jsonc, for the same
     * reason RESEND_API_KEY is one.
     *
     * Unset switches signup off entirely rather than opening it: creating an
     * account is the one unauthenticated way to start consuming R2, and there is
     * no billing yet to bound what a stranger could store. Rotating the value is
     * the entire revocation story.
     */
    SIGNUP_INVITE_CODE?: string;
  };

/** How long an emailed link stays redeemable. */
const LOGIN_TOKEN_TTL_MINUTES = 15;

/*
 * Longer than a sign-in link because a signup arrives cold -- reading an
 * onboarding email, finding the code that came with it, possibly moving to
 * another device -- where a sign-in link is requested by somebody already at the
 * keyboard. The token is 256 bits and single-use either way, so the extra
 * minutes only widen the window for an attacker who can already read the inbox,
 * and that attacker has won regardless.
 */
const SIGNUP_TOKEN_TTL_MINUTES = 30;

/*
 * A cap on live tokens per user, not a time-window counter: it is the number of
 * simultaneously redeemable links that matters, and this is one indexed COUNT
 * rather than a rate-limiter's worth of state.
 */
const MAX_LIVE_LOGIN_TOKENS = 5;

/*
 * The same idea keyed on the address, since a signup has no account_user to key
 * on yet. Lower than MAX_LIVE_LOGIN_TOKENS because signing up is a once-ever
 * action and signing in is not.
 */
const MAX_LIVE_SIGNUP_TOKENS_PER_EMAIL = 3;

/*
 * The cap that matters when it matters: a per-address cap does nothing against a
 * leaked invite code sprayed at ten thousand distinct addresses. A limit shared
 * across tenants would be indefensible on /api/auth/magic-link -- one noisy
 * account would lock everyone else out -- but signing up happens a handful of
 * times ever, so twenty simultaneously outstanding invitations means either an
 * extraordinary day or a leaked code, and pausing is the right answer to both.
 * It also bounds how much mail a leaked code can send from the domain every
 * existing customer's sign-in links depend on.
 */
const MAX_LIVE_SIGNUP_TOKENS = 20;

const MAX_EMAIL_LENGTH = 254;

/** Bounds what a caller can make us hash before the code is even compared. */
const MAX_INVITE_CODE_LENGTH = 200;

/** Copied from the CHECK on accounts.name, which is where this value lands. */
const MAX_ACCOUNT_NAME_LENGTH = 120;

interface MagicLinkRequestBody {
  email?: unknown;
}

interface SignupRequestBody {
  email?: unknown;
  accountName?: unknown;
  inviteCode?: unknown;
}

/** Both consume endpoints take the same one-field body. */
interface ConsumeTokenBody {
  token?: unknown;
}

interface AccountUserRow {
  id: string;
  accountId: string;
  email: string | null;
  role: string;
}

/*
 * Deliberately carries the account status rather than filtering on it, so signup
 * can tell "no account" from "an account that is not active" and answer each
 * without minting a token that is guaranteed to fail later.
 */
interface AccountUserStatusRow {
  id: string;
  accountStatus: string;
}

interface LoginTokenRow {
  id: string;
  accountUserId: string;
  expiresAt: string;
  consumedAt: string | null;
}

interface SignupTokenRow {
  id: string;
  email: string;
  accountName: string;
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
 * Null means signup is switched off for this deployment, which is the intended
 * state everywhere except app.pickpic.photos. Whitespace-only counts as unset,
 * matching how resolveAuthMode and RESEND_API_KEY treat a blank value.
 */
function resolveSignupInviteCode(environment: AuthEnvironment): string | null {
  const code = environment.SIGNUP_INVITE_CODE?.trim();

  return code ? code : null;
}

/*
 * Compares digests rather than the codes themselves, which makes the comparison
 * independent of both the value and the length of the secret: two SHA-256 hex
 * digests are always 64 characters.
 *
 * session.ts argues the opposite for token lookups, and both positions are
 * right. A 256-bit random token is not guessable one byte at a time whatever it
 * leaks about timing; a code a human chose and will type into a form is a
 * different kind of secret, and four lines here means nobody has to have the
 * argument again.
 */
async function matchesInviteCode(
  supplied: string,
  configured: string,
): Promise<boolean> {
  const [suppliedHash, configuredHash] = await Promise.all([
    hashAuthToken(supplied),
    hashAuthToken(configured),
  ]);

  let difference = 0;

  for (let index = 0; index < suppliedHash.length; index += 1) {
    difference |=
      suppliedHash.charCodeAt(index) ^ configuredHash.charCodeAt(index);
  }

  return difference === 0;
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
 * These routes exist only where AUTH_MODE is 'session'. A deployment that
 * authenticates through Cloudflare Access has no use for them, and serving them
 * anyway would mean two things worth avoiding:
 *
 *   * pickpic.photos, the public gallery origin, would carry an unauthenticated
 *     endpoint that sends email to any address already in account_users. The
 *     live-token cap bounds it, but the right bound is not offering it at all.
 *
 *   * the emailed link is built from the origin the request arrived on, so a
 *     link requested through the wrong host would point at the wrong host.
 *     Redeeming it there would set a __Host- cookie scoped to that host, which
 *     grants nothing -- the public worker has no Access configuration and
 *     refuses /api/admin/* regardless -- but it is a dead end a real person
 *     could walk into.
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

  if (resolveAuthMode(environment) !== "session") {
    return null;
  }

  /*
   * Exempt by pathname, and only this one pathname, because Apple returns the
   * user with a genuine cross-site top-level POST from appleid.apple.com. That
   * request cannot carry our own Origin and never will, so the check below would
   * refuse every Apple sign-in before its handler ever ran.
   *
   * The exemption is safe for a specific reason rather than because this route
   * matters less. The Origin check defends actions that draw their authority
   * from a cookie the browser attaches automatically; the callback draws none
   * from a cookie at all. It proves who the user is from an identity token
   * fetched server to server and pinned to our own client id, and it proves the
   * flow started here from a single-use state value it compares against the
   * cookie set at /api/auth/apple/start. Both checks live inside
   * handleAppleCallback and both must pass before anything is written.
   *
   * Narrowed rather than relaxed: every other /api/auth/* route, and every
   * shape of request to this one that is not that POST, is exactly as strict as
   * before. requireAdminPrincipal above already scopes the same check to the
   * session branch, so per-route scoping of this guard is the established shape
   * here rather than a new idea.
   */
  const isAppleCallback = url.pathname === "/api/auth/apple/callback";

  if (
    !isAppleCallback &&
    isStateChanging(request) &&
    !isSameOriginRequest(request)
  ) {
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

  /*
   * Both signup routes share one block, breaking this function's flat
   * one-if-per-route shape on purpose: the gate below is the safety-relevant
   * part of the feature and it should be impossible to add a third signup route
   * that forgets it.
   *
   * An unset code answers 503 rather than falling through to the generic /api/
   * 404. The SPA serves /sign-up from static assets whatever the worker is
   * configured for, so a real person can reach that form on a misconfigured
   * deployment, and "Request failed with status 404." is a worse thing to show
   * them than an honest "not available". It still fails closed in the only sense
   * that matters: no account, no token, no email. Covering the consume route too
   * means rotating the code kills every confirmation link still in flight, which
   * is what rotation is for.
   */
  if (
    url.pathname === "/api/auth/signup" ||
    url.pathname === "/api/auth/signup/consume"
  ) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const inviteCode = resolveSignupInviteCode(environment);

    if (inviteCode === null) {
      console.error(
        "SIGNUP_INVITE_CODE is not configured; signup is disabled.",
      );

      return jsonResponse({ error: "Signup is not available right now." }, 503);
    }

    return url.pathname === "/api/auth/signup"
      ? requestSignup(request, url, database, environment, inviteCode)
      : consumeSignup(request, database);
  }

  if (url.pathname === "/api/auth/apple/start") {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return startAppleSignIn(environment);
  }

  if (isAppleCallback) {
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return completeAppleSignIn(request, url, database, environment);
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
 * This endpoint still cannot create anything: an address only receives a link if
 * account_users already holds a row for it. Signing up lives at
 * /api/auth/signup, behind SIGNUP_INVITE_CODE, and the two share the token
 * machinery below through issueSignInLink -- signup mails a sign-in link when
 * the address turns out to be an existing customer.
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
    return jsonResponse({ ok: true });
  }

  return issueSignInLink(
    request,
    url,
    database,
    environment,
    accountUser.id,
    email,
    "The sign-in email could not be sent. Try again.",
  );
}

/*
 * Mints and mails one sign-in link for an account_user that is already known to
 * exist. Shared by /api/auth/magic-link and by signup's already-a-customer
 * branch, so the token cap, the lifetime, the insert-before-send ordering and
 * the rollback are identical across both by construction rather than by review.
 *
 * sendFailureMessage is a parameter for a reason that is easy to miss: if the
 * two callers reported a provider outage differently, the wording of a 502 would
 * tell the caller which branch ran -- that is, whether the address is a
 * customer. Every other answer these endpoints give is already identical, and
 * this is the one that would have leaked.
 */
async function issueSignInLink(
  request: Request,
  url: URL,
  database: D1Database,
  environment: AuthEnvironment,
  accountUserId: string,
  email: string,
  sendFailureMessage: string,
): Promise<Response> {
  const accepted = jsonResponse({ ok: true });

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
    .bind(accountUserId, now.toISOString())
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
      accountUserId,
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
        kind: "sign-in",
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

    return jsonResponse({ error: sendFailureMessage }, 502);
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
  let body: ConsumeTokenBody;

  try {
    body = (await request.json()) as ConsumeTokenBody;
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

/*
 * The half of signing up that creates nothing.
 *
 * No accounts or account_users row is written here. The address, the studio
 * name and nothing else go into auth_signup_tokens, and only clicking the
 * emailed link turns that into an account. account_users is unique on
 * (auth_provider, auth_subject), so a row written before the address is proven
 * would let anyone holding the invite code claim somebody else's email
 * permanently, and undoing that would mean a delete path through two tables
 * every foreign key reaches ON DELETE RESTRICT. There is no such path, by
 * design, and this ordering is why none is needed.
 */
async function requestSignup(
  request: Request,
  url: URL,
  database: D1Database,
  environment: AuthEnvironment,
  inviteCode: string,
): Promise<Response> {
  let body: SignupRequestBody;

  try {
    body = (await request.json()) as SignupRequestBody;
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  /*
   * Checked before the address and the name, so a caller without the code
   * learns nothing at all -- not even whether an address is well formed -- and
   * can never cause a write or a send. It is also the right order for a real
   * person: fix the gate before anything else is worth mentioning.
   *
   * Saying plainly that the code is wrong is safe, unlike naming an unknown
   * address. The code belongs to nobody and identifies nobody; concealing it
   * would strand a typo at "check your email" forever to protect nothing.
   */
  const suppliedCode =
    typeof body.inviteCode === "string" ? body.inviteCode.trim() : "";

  if (
    suppliedCode.length === 0 ||
    suppliedCode.length > MAX_INVITE_CODE_LENGTH ||
    !(await matchesInviteCode(suppliedCode, inviteCode))
  ) {
    return jsonResponse({ error: "That invite code is not valid." }, 403);
  }

  const email = normalizeEmail(body.email);

  if (!email) {
    return jsonResponse({ error: "Enter a valid email address." }, 400);
  }

  const accountName =
    typeof body.accountName === "string" ? body.accountName.trim() : "";

  if (
    accountName.length === 0 ||
    accountName.length > MAX_ACCOUNT_NAME_LENGTH
  ) {
    return jsonResponse(
      {
        error: `The studio name must be between 1 and ${MAX_ACCOUNT_NAME_LENGTH} characters.`,
      },
      400,
    );
  }

  const accepted = jsonResponse({ ok: true });

  /*
   * Without the status = 'active' filter requestMagicLink uses, so that a
   * disabled account is a case of its own instead of falling into the "no
   * account" branch and being handed a signup token that is guaranteed to fail
   * half an hour later.
   */
  const existing = await database
    .prepare(
      `
        SELECT
          u.id AS id,
          a.status AS accountStatus
        FROM account_users u
        JOIN accounts a ON a.id = u.account_id
        WHERE u.auth_provider = 'email'
          AND u.auth_subject = ?
      `,
    )
    .bind(email)
    .first<AccountUserStatusRow>();

  if (existing) {
    if (existing.accountStatus !== "active") {
      return accepted;
    }

    /*
     * A customer who reached for the wrong form. Mailing a sign-in link gets
     * them where they were going; the alternative -- answering {ok:true} and
     * sending nothing -- leaves an honest person waiting on an email that will
     * never arrive, to protect a fact the identical response body already
     * protects. It cannot be turned into an attack either: the recipient is the
     * account's own address, and the link is byte for byte what
     * /api/auth/magic-link already mails that address unauthenticated.
     *
     * accountName is dropped here and must stay dropped. Letting a signup
     * rename an existing studio because somebody holding the invite code typed
     * that address into the form would be a real bug.
     */
    return issueSignInLink(
      request,
      url,
      database,
      environment,
      existing.id,
      email,
      "The confirmation email could not be sent. Try again.",
    );
  }

  const now = new Date();

  const nowIso = now.toISOString();

  /*
   * Address-scoped, so it can never become an unbounded delete, and run before
   * the counts so a previous attempt that has since expired does not go on
   * occupying one of this address's slots.
   */
  await database
    .prepare(
      `
        DELETE FROM auth_signup_tokens
        WHERE email = ?
          AND (consumed_at IS NOT NULL OR expires_at <= ?)
      `,
    )
    .bind(email, nowIso)
    .run();

  const liveForEmail = await database
    .prepare(
      `
        SELECT COUNT(*) AS liveTokens
        FROM auth_signup_tokens
        WHERE email = ?
          AND consumed_at IS NULL
          AND expires_at > ?
      `,
    )
    .bind(email, nowIso)
    .first<LiveTokenCountRow>();

  if ((liveForEmail?.liveTokens ?? 0) >= MAX_LIVE_SIGNUP_TOKENS_PER_EMAIL) {
    // Silently, and with the same body as a success, for the reason the
    // login-token cap gives: being told you are throttled is being told the
    // request would otherwise have done something.
    return accepted;
  }

  const liveOverall = await database
    .prepare(
      `
        SELECT COUNT(*) AS liveTokens
        FROM auth_signup_tokens
        WHERE consumed_at IS NULL
          AND expires_at > ?
      `,
    )
    .bind(nowIso)
    .first<LiveTokenCountRow>();

  if ((liveOverall?.liveTokens ?? 0) >= MAX_LIVE_SIGNUP_TOKENS) {
    /*
     * Logged, unlike the per-address cap. A routine per-user rate limit is
     * noise; twenty outstanding invitations at once is either a remarkable day
     * or a leaked code, and both are worth seeing in observability.
     */
    console.warn(
      "The global live signup-token cap was reached; signup is paused.",
    );

    return accepted;
  }

  const token = generateAuthToken();

  const tokenId = crypto.randomUUID();

  await database
    .prepare(
      `
        INSERT INTO auth_signup_tokens (
          id,
          email,
          account_name,
          token_hash,
          created_at,
          expires_at,
          consumed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, NULL)
      `,
    )
    .bind(
      tokenId,
      email,
      accountName,
      await hashAuthToken(token),
      nowIso,
      new Date(
        now.getTime() + SIGNUP_TOKEN_TTL_MINUTES * 60 * 1000,
      ).toISOString(),
    )
    .run();

  /*
   * Lands on /sign-up rather than /sign-in for the same reason the sign-in link
   * lands on a page at all: mail scanners GET every URL in a message, so the
   * page redeems with a POST. Which page it is matters too -- this one is in the
   * act of creating an account, and its copy and its errors say so.
   */
  const link = new URL("/sign-up", url.origin);

  link.searchParams.set("token", token);

  try {
    await sendMagicLinkEmail(
      environment,
      {
        kind: "sign-up",
        to: email,
        url: link.toString(),
        expiresInMinutes: SIGNUP_TOKEN_TTL_MINUTES,
      },
      isLocalRequest(request),
    );
  } catch (error) {
    /*
     * The same rollback issueSignInLink performs, for the same reason: the row
     * goes in first so a send can never deliver a token the database does not
     * know about, and comes back out on failure so a provider outage does not
     * spend a slot on a link nobody received -- here one of the global twenty as
     * well as one of this address's three.
     */
    await database
      .prepare(
        `
          DELETE FROM auth_signup_tokens
          WHERE id = ?
        `,
      )
      .bind(tokenId)
      .run();

    console.error("Failed to send a signup email:", error);

    return jsonResponse(
      { error: "The confirmation email could not be sent. Try again." },
      502,
    );
  }

  return accepted;
}

/*
 * The half that creates. Everything up to here was disposable; this is where an
 * account starts existing.
 *
 * The invite code is not re-checked against the body: it was checked when the
 * token was minted, and the token is the proof. Asking somebody to re-type a
 * secret in order to click a link produces support tickets and no security.
 */
async function consumeSignup(
  request: Request,
  database: D1Database,
): Promise<Response> {
  let body: ConsumeTokenBody;

  try {
    body = (await request.json()) as ConsumeTokenBody;
  } catch {
    return jsonResponse({ error: "This confirmation link is not valid." }, 400);
  }

  if (typeof body.token !== "string" || body.token.trim().length === 0) {
    return jsonResponse({ error: "This confirmation link is not valid." }, 400);
  }

  const tokenHash = await hashAuthToken(body.token.trim());

  const row = await database
    .prepare(
      `
        SELECT
          id,
          email,
          account_name AS accountName,
          expires_at AS expiresAt,
          consumed_at AS consumedAt
        FROM auth_signup_tokens
        WHERE token_hash = ?
      `,
    )
    .bind(tokenHash)
    .first<SignupTokenRow>();

  // Expired, already used, and never issued are one message on purpose, exactly
  // as in consumeMagicLink.
  const expiredOrSpent = jsonResponse(
    { error: "This confirmation link has expired or has already been used." },
    400,
  );

  if (
    !row ||
    row.consumedAt !== null ||
    Date.parse(row.expiresAt) <= Date.now()
  ) {
    return expiredOrSpent;
  }

  /*
   * A deliberate exception to this file's rule that answers must not
   * distinguish a known address from an unknown one. Reaching it requires a
   * live, single-use token that was emailed to the address in question, so the
   * caller owns that address by construction and is being told the one thing
   * they can act on. It is not an oracle.
   */
  const alreadyClaimed = jsonResponse(
    {
      error:
        "An account already exists for that email address. Sign in instead.",
    },
    409,
  );

  /*
   * Checked before the token is spent, so the common case -- the account was
   * created some other way while this link sat in an inbox -- costs the holder
   * nothing. Not sufficient on its own: the unique index remains the authority
   * and the catch below is where a genuine race is settled.
   */
  if (await findEmailAccountUser(database, row.email)) {
    return alreadyClaimed;
  }

  /*
   * Marked consumed before anything is created, and only where it is still
   * unconsumed, which is what makes two simultaneous clicks on one link produce
   * one account. Kept out of the batch below because meta.changes has to be
   * inspected before deciding to insert, and a batch reports its results only
   * once every statement in it has already run.
   */
  const consumedAt = new Date().toISOString();

  const consumed = await database
    .prepare(
      `
        UPDATE auth_signup_tokens
        SET consumed_at = ?
        WHERE id = ?
          AND consumed_at IS NULL
      `,
    )
    .bind(consumedAt, row.id)
    .run();

  if (consumed.meta.changes !== 1) {
    return expiredOrSpent;
  }

  const accountId = crypto.randomUUID();

  const accountUserId = crypto.randomUUID();

  const nowIso = new Date().toISOString();

  try {
    /*
     * One batch, which D1 runs as a single transaction, and that is the whole
     * point. An accounts row with no account_users row would be both
     * unreachable -- nothing joins to it -- and undeletable, since every
     * foreign key into accounts is ON DELETE RESTRICT and there is no admin UI.
     * It is the worst durable state this endpoint could produce, and batching
     * makes it unrepresentable rather than merely unlikely.
     *
     * database_id is NULL because a new account's rows live in the primary D1
     * database; resolveAccountDatabase throws for an id it has no binding for.
     */
    await database.batch([
      database
        .prepare(
          `
            INSERT INTO accounts (
              id,
              name,
              status,
              database_id,
              created_at,
              updated_at
            )
            VALUES (?, ?, 'active', NULL, ?, ?)
          `,
        )
        .bind(accountId, row.accountName, nowIso, nowIso),

      database
        .prepare(
          `
            INSERT INTO account_users (
              id,
              account_id,
              auth_provider,
              auth_subject,
              email,
              role,
              created_at,
              updated_at
            )
            VALUES (?, ?, 'email', ?, ?, 'owner', ?, ?)
          `,
        )
        .bind(accountUserId, accountId, row.email, row.email, nowIso, nowIso),
    ]);
  } catch (error) {
    /*
     * Told apart by behaviour, never by error text. "UNIQUE constraint failed:
     * ..." is a message rather than a contract, and a regex on it would quietly
     * start returning 500 where a 409 belongs on the day D1 rewords it.
     */
    if (await findEmailAccountUser(database, row.email)) {
      // Somebody else finished first. The token stays consumed: it can never
      // succeed now, and leaving it spent is what keeps a retry idempotent.
      return alreadyClaimed;
    }

    /*
     * Not the unique index, so something transient. Give the link back rather
     * than spending this person's confirmation on a database hiccup -- without
     * this, three unlucky attempts burn all three of the address's slots and
     * lock them out for the whole token lifetime. The guard clears only the mark
     * this request wrote, and only this request can have written it.
     */
    try {
      await database
        .prepare(
          `
            UPDATE auth_signup_tokens
            SET consumed_at = NULL
            WHERE id = ?
              AND consumed_at = ?
          `,
        )
        .bind(row.id, consumedAt)
        .run();
    } catch (restoreError) {
      // Its own catch because index.ts has no top-level handler: an uncaught
      // throw here would reach the client as a non-JSON Workers 500.
      console.error("Failed to restore a signup token:", restoreError);
    }

    console.error("Failed to create an account from a signup token:", error);

    return jsonResponse(
      { error: "Your account could not be created. Try again." },
      500,
    );
  }

  let sessionToken: string;

  try {
    sessionToken = await createSession(database, accountUserId, request);
  } catch (error) {
    /*
     * Outside the batch because createSession mints its own token and returns
     * it, and that is a considered trade rather than an oversight. If this
     * throws, the account exists and its owner is not signed in -- and the
     * recovery is complete and self-serve, because /sign-in with the same
     * address now finds the account_users row and mails a link. The
     * accounts/account_users pair has no such recovery, which is exactly why
     * that pair, and only that pair, is atomic.
     */
    console.error("Created an account but failed to start its session:", error);

    return jsonResponse(
      {
        error:
          "Your account is ready, but signing you in failed. Open the sign-in page and enter your email.",
      },
      500,
    );
  }

  await deleteSignupTokensForEmail(database, row.email);

  return jsonResponse({ ok: true }, 200, {
    "Set-Cookie": sessionCookieHeader(sessionToken),
  });
}

/*
 * Sends the browser to Apple with a freshly minted state value, remembered in a
 * cookie for the callback to compare against.
 *
 * A missing configuration answers 503 here rather than redirecting: Apple would
 * show its own error page for an unknown client id, and an operator debugging
 * that would have no reason to suspect PickPic's own environment.
 */
function startAppleSignIn(environment: AuthEnvironment): Response {
  const config = resolveAppleConfig(environment);

  if (config === null) {
    console.error(
      "Apple sign-in is not configured; APPLE_* values are missing or blank.",
    );

    return jsonResponse(
      { error: "Sign in with Apple is not available right now." },
      503,
    );
  }

  const state = generateAuthToken();

  return redirectResponse(buildAppleAuthorizeUrl(config, state), [
    appleStateCookieHeader(state),
  ]);
}

/*
 * Apple's redirect target, and the only handler here that answers a real browser
 * navigation rather than a fetch from our own page. Every outcome is therefore a
 * redirect: a JSON body would render as raw text in the tab, and a bare 500
 * would strand somebody mid sign-in with nowhere to go.
 *
 * Failures deliberately do not distinguish what went wrong beyond what the
 * person can act on. The one distinction worth drawing is between "something
 * broke" and "this Apple ID is not attached to an account", because only the
 * second has an obvious next step.
 */
async function completeAppleSignIn(
  request: Request,
  url: URL,
  database: D1Database,
  environment: AuthEnvironment,
): Promise<Response> {
  const config = resolveAppleConfig(environment);

  if (config === null) {
    console.error(
      "Apple sign-in is not configured; APPLE_* values are missing or blank.",
    );

    return appleFailureRedirect(url, "apple");
  }

  let body: FormData;

  try {
    body = await request.formData();
  } catch (error) {
    console.error("Apple's callback body could not be parsed:", error);

    return appleFailureRedirect(url, "apple");
  }

  /*
   * The state check is what makes this route safe without the Origin check the
   * guard in handleAuthRequest waives for it. A plain comparison is enough for
   * the same reason session.ts gives for token lookups: this is 256 bits of
   * CSPRNG output, not a secret anybody guesses a byte at a time.
   */
  const suppliedState = body.get("state");

  const expectedState = readAppleStateCookie(request);

  if (
    typeof suppliedState !== "string" ||
    expectedState === null ||
    suppliedState !== expectedState
  ) {
    return appleFailureRedirect(url, "apple");
  }

  const code = body.get("code");

  if (typeof code !== "string" || code.length === 0) {
    return appleFailureRedirect(url, "apple");
  }

  let identity: Awaited<ReturnType<typeof verifyAppleIdentityToken>>;

  try {
    const idToken = await exchangeAppleCode(code, config);

    identity = await verifyAppleIdentityToken(idToken, config);
  } catch (error) {
    console.error("Apple sign-in could not be verified:", error);

    return appleFailureRedirect(url, "apple");
  }

  /*
   * The Apple identity itself, if this person has signed in before. Every
   * sign-in after the first one stops here.
   */
  const existing = await findAccountUserBySubject(
    database,
    "apple",
    identity.subject,
  );

  if (existing) {
    return existing.accountStatus === "active"
      ? startAppleSession(request, url, database, existing.id)
      : appleFailureRedirect(url, "apple");
  }

  /*
   * First sign-in with this Apple ID. It may still belong to somebody who
   * already has an account through an emailed link, and attaching a second
   * identity to that account is not the same thing as creating one -- that is
   * exactly the shape account_users was built for, many identities to one
   * account.
   *
   * Apple's verified address is the only evidence used, and readVerifiedEmail
   * has already discarded anything Apple did not vouch for. Sign in with Apple
   * must never create an account: signup is gated behind an invite code because
   * an account is the one unauthenticated way to start consuming R2, and a
   * provider almost every person on earth already has would walk straight
   * through that gate.
   */
  /*
   * Normalised before it is compared, because account_users.auth_subject holds
   * an address that normalizeEmail already lowercased. Apple echoes the address
   * as the person capitalised it on their Apple ID, so comparing it raw would
   * fail to match an account that does exist -- and fail silently, as an
   * unlinked Apple ID rather than an error.
   */
  const appleEmail = identity.email ? normalizeEmail(identity.email) : null;

  const linkable = appleEmail
    ? await findLinkableEmailAccountUser(database, appleEmail)
    : null;

  if (!linkable) {
    return appleFailureRedirect(url, "apple-unlinked");
  }

  const accountUserId = crypto.randomUUID();

  try {
    await linkAppleIdentity(
      database,
      accountUserId,
      linkable,
      identity.subject,
      appleEmail,
    );
  } catch (error) {
    /*
     * Told apart by behaviour rather than by error text, as consumeSignup
     * argues at greater length: two callbacks racing on a first sign-in both
     * try this insert and the unique index settles it. No row needs restoring
     * on the way out -- nothing was consumed to get here.
     */
    const raced = await findAccountUserBySubject(
      database,
      "apple",
      identity.subject,
    );

    if (raced && raced.accountStatus === "active") {
      return startAppleSession(request, url, database, raced.id);
    }

    console.error("Failed to link an Apple identity to an account:", error);

    return appleFailureRedirect(url, "apple");
  }

  return startAppleSession(request, url, database, accountUserId);
}

/*
 * The session half, shared by the returning and the newly linked paths so both
 * set the cookie, clear the state and land in the same place.
 */
async function startAppleSession(
  request: Request,
  url: URL,
  database: D1Database,
  accountUserId: string,
): Promise<Response> {
  let token: string;

  try {
    token = await createSession(database, accountUserId, request);
  } catch (error) {
    console.error("Failed to start a session for an Apple sign-in:", error);

    return appleFailureRedirect(url, "apple");
  }

  await deleteExpiredSessions(database, accountUserId);

  return redirectResponse(new URL("/", url.origin).toString(), [
    sessionCookieHeader(token),
    clearedAppleStateCookieHeader(),
  ]);
}

function appleFailureRedirect(url: URL, code: string): Response {
  const target = new URL("/sign-in", url.origin);

  target.searchParams.set("error", code);

  return redirectResponse(target.toString(), [clearedAppleStateCookieHeader()]);
}

/*
 * Built through Headers rather than an object literal because Set-Cookie is the
 * one header that may legitimately repeat, and an object literal can only carry
 * it once.
 */
function redirectResponse(location: string, cookies: string[]): Response {
  const headers = new Headers({
    Location: location,
    "Cache-Control": "no-store",
  });

  for (const cookie of cookies) {
    headers.append("Set-Cookie", cookie);
  }

  return new Response(null, { status: 302, headers });
}

/*
 * Carries the account's status rather than filtering on it, so the caller can
 * tell a suspended account apart from one that does not exist and answer each
 * differently.
 */
async function findAccountUserBySubject(
  database: D1Database,
  provider: string,
  subject: string,
): Promise<AccountUserStatusRow | null> {
  return database
    .prepare(
      `
        SELECT
          u.id AS id,
          a.status AS accountStatus
        FROM account_users u
        JOIN accounts a ON a.id = u.account_id
        WHERE u.auth_provider = ?
          AND u.auth_subject = ?
      `,
    )
    .bind(provider, subject)
    .first<AccountUserStatusRow>();
}

/*
 * The email-provider row an Apple identity may attach itself to. Filters on an
 * active account here, unlike findAccountUserBySubject, because there is nothing
 * to say to somebody whose account is suspended that differs from having no
 * account at all -- and linking to a suspended account would quietly hand them a
 * second way in.
 */
async function findLinkableEmailAccountUser(
  database: D1Database,
  email: string,
): Promise<AccountUserRow | null> {
  return database
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
}

/*
 * One insert, not a batch: the account already exists, so unlike signup there is
 * no pair of rows that could half-apply. The new row inherits the account and
 * the role of the email identity it was matched to, because it is the same
 * person reaching the same account by another door.
 */
async function linkAppleIdentity(
  database: D1Database,
  accountUserId: string,
  linkable: AccountUserRow,
  subject: string,
  email: string | null,
): Promise<void> {
  const nowIso = new Date().toISOString();

  await database
    .prepare(
      `
        INSERT INTO account_users (
          id,
          account_id,
          auth_provider,
          auth_subject,
          email,
          role,
          created_at,
          updated_at
        )
        VALUES (?, ?, 'apple', ?, ?, ?, ?, ?)
      `,
    )
    .bind(
      accountUserId,
      linkable.accountId,
      subject,
      email,
      linkable.role,
      nowIso,
      nowIso,
    )
    .run();
}

/** Provider-pinned to email, since that is the only provider signup can create. */
async function findEmailAccountUser(
  database: D1Database,
  email: string,
): Promise<{ id: string } | null> {
  return database
    .prepare(
      `
        SELECT id
        FROM account_users
        WHERE auth_provider = 'email'
          AND auth_subject = ?
      `,
    )
    .bind(email)
    .first<{ id: string }>();
}

/*
 * Unconditional rather than consumed-and-expired-only, and best-effort in the
 * manner of touchSessionQuietly: once the account exists, every other live token
 * for that address is guaranteed to 409, so clearing them turns a puzzling "an
 * account already exists" into the "expired or already used" message people
 * already know from signing in. Scoped to one address, so never an unbounded
 * delete, and it can destroy nothing of value -- the account those tokens would
 * have created is the one that just succeeded.
 */
async function deleteSignupTokensForEmail(
  database: D1Database,
  email: string,
): Promise<void> {
  try {
    await database
      .prepare(
        `
          DELETE FROM auth_signup_tokens
          WHERE email = ?
        `,
      )
      .bind(email)
      .run();
  } catch (error) {
    console.error("Failed to clear spent signup tokens:", error);
  }
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
