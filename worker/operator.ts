import type { AdminPrincipal } from "./access.ts";

/*
 * The operator console: one cross-account view of who has signed up, who is
 * attached to each account, how much storage each is consuming, and whether
 * anything has actually been uploaded (#195).
 *
 * Everything else in this worker is account-scoped by construction --
 * handleAdminRequest is typed against TenantEnv (Omit<Env, "DB">) and an
 * AccountScope whose prepare() refuses a statement that does not constrain
 * :accountId. This module is the one deliberate hole in that, so all three of
 * the design questions #195 raised are answered here rather than spread across
 * the handlers.
 *
 * --- Where does the operator flag live? ---
 *
 * In deployment configuration: OPERATOR_EMAILS, a secret holding the addresses
 * allowed to open the console. Not a column on account_users and not a table,
 * for two reasons beyond the migration it would cost. A privilege bit stored in
 * the same database the console reads is editable by anything that can write
 * that row, where a Worker secret is changed only by someone already holding the
 * Cloudflare deploy credential -- a strictly smaller set than "whatever can
 * write D1". And config is per-deployment, so app.pickpic.photos can carry an
 * operator list while pickpic.photos carries none; the public origin cannot even
 * express an operator. Unset means no operator exists anywhere, which is the
 * intended state on every deployment but app.pickpic.photos.
 *
 * The cost of that choice is honest: adding an operator is a `wrangler secret
 * put` and not a click. With one operator today that is the right trade, and the
 * day it is not, this is the only function that has to learn a second source.
 *
 * --- Is it a property of the user or of the session? ---
 *
 * Of the verified email on the principal, evaluated per request. There is no
 * operator mode to enter, deliberately: everything here is read-only, so there
 * is no destructive capability a mode switch would be guarding, and a toggle
 * that protects nothing is just a step people learn to click through. If an
 * operator route ever *writes* to an account that is not its own, that is the
 * point at which a deliberate mode -- and an audit trail -- stops being
 * ceremony.
 *
 * Matching on email rather than on an account id is safe because no route can
 * set an address without proving it: signup writes the address the link was
 * mailed to, and Apple linking requires an address Apple itself marked verified
 * against an account that already owns it.
 *
 * --- How do the account-scoped guards learn about it? ---
 *
 * They do not, and that is the point. handleOperatorRequest is dispatched from
 * routeRequest *before* the AccountScope is built, so it is the only admin-side
 * handler that ever receives the bare D1Database. The guard is checked once, at
 * this module's entry; no handler in worker/index.ts grows a special case, and
 * the TenantEnv type keeps every one of them structurally incapable of the
 * cross-account read this file performs.
 */
export interface OperatorEnvironment {
  /*
   * Comma- or whitespace-separated addresses. A secret rather than a var in
   * wrangler.jsonc: pickpic is a public repository and this is a list of real
   * people's addresses, so it does not belong in a committed file even though
   * it is not a credential.
   *
   * `wrangler secret put OPERATOR_EMAILS --env app`
   */
  OPERATOR_EMAILS?: string;
}

/*
 * Bounds the response rather than paginating it. The console exists to watch a
 * beta cohort; if these are ever hit, the answer is a real paginated view, not
 * a bigger number, and truncating is better than timing out a D1 query in the
 * meantime.
 */
const MAX_OPERATOR_ACCOUNTS = 500;
const MAX_OPERATOR_ACCOUNT_USERS = 2000;

function jsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
    },
  });
}

/*
 * Lowercased and trimmed, matching how normalizeEmail in worker/auth.ts stores
 * every address this is compared against. Deliberately not importing that
 * function: auth.ts calls into this module for the session payload's isOperator
 * flag, and a shared helper in the other direction would make the two files a
 * cycle. The validity checks normalizeEmail also performs are irrelevant here --
 * an address that cannot be signed in as simply never matches.
 */
function normalizeOperatorEmail(value: string): string {
  return value.trim().toLowerCase();
}

export function resolveOperatorEmails(
  environment: OperatorEnvironment,
): Set<string> {
  const configured = environment.OPERATOR_EMAILS ?? "";

  return new Set(
    configured
      .split(/[\s,]+/)
      .map(normalizeOperatorEmail)
      .filter((email) => email.length > 0),
  );
}

/*
 * A null email is never an operator, which quietly rules out the two principals
 * that carry none: a Cloudflare Access service token, and the local-development
 * principal wrangler dev synthesises. The second means the console is not
 * reachable from a plain `npm run dev` against /admin -- set AUTH_MODE=session
 * and OPERATOR_EMAILS in .dev.vars to exercise it locally, which is the same
 * configuration app.pickpic.photos runs.
 */
export function isOperatorPrincipal(
  principal: AdminPrincipal,
  environment: OperatorEnvironment,
): boolean {
  if (principal.email === null) {
    return false;
  }

  const operators = resolveOperatorEmails(environment);

  if (operators.size === 0) {
    return false;
  }

  return operators.has(normalizeOperatorEmail(principal.email));
}

export interface OperatorAccountUser {
  id: string;
  email: string | null;
  role: string;
  authProvider: string;
  createdAt: string;
}

export interface OperatorAccountSummary {
  id: string;
  name: string;
  status: string;
  plan: string;

  /*
   * accounts.storage_bytes, the running counter migration 0018 maintains, not
   * the reconciling SUM() that GET /api/admin/storage runs. Summing every
   * photo, final and variant row for every account on one request is exactly
   * the query 0018 exists to avoid, and the counter self-heals on that
   * account's next storage read -- close enough for an overview, and the
   * per-account panel remains the authoritative figure.
   */
  storageBytes: number;
  storageCapBytes: number;

  eventCount: number;
  photoCount: number;

  /** Null for an account that has never uploaded -- the thing #195 is looking for. */
  lastPhotoUploadedAt: string | null;

  createdAt: string;
  users: OperatorAccountUser[];
}

interface AccountSummaryRow {
  id: string;
  name: string;
  status: string;
  plan: string;
  storageBytes: number;
  storageCapBytes: number;
  eventCount: number;
  photoCount: number;
  lastPhotoUploadedAt: string | null;
  createdAt: string;
}

interface AccountUserRow {
  id: string;
  accountId: string;
  email: string | null;
  role: string;
  authProvider: string;
  createdAt: string;
}

/*
 * Two statements and a join in memory rather than one row per (account, user)
 * pair: the aggregate subqueries below would otherwise be computed once per
 * user of an account, and un-fanning the duplicated counts afterwards is more
 * error-prone than the grouping loop.
 *
 * MAX() over created_at is safe as a chronological maximum because every
 * timestamp in this schema is an ISO-8601 UTC string written by
 * toISOString(), which sorts lexicographically in the same order.
 */
export async function listOperatorAccounts(
  database: D1Database,
): Promise<OperatorAccountSummary[]> {
  const [accounts, users] = await Promise.all([
    database
      .prepare(
        `
          SELECT
            a.id AS id,
            a.name AS name,
            a.status AS status,
            a.plan AS plan,
            a.storage_bytes AS storageBytes,
            a.storage_cap_bytes AS storageCapBytes,
            (
              SELECT COUNT(*)
              FROM events e
              WHERE e.account_id = a.id
            ) AS eventCount,
            (
              SELECT COUNT(*)
              FROM photos p
              WHERE p.account_id = a.id
            ) AS photoCount,
            (
              SELECT MAX(p.created_at)
              FROM photos p
              WHERE p.account_id = a.id
            ) AS lastPhotoUploadedAt,
            a.created_at AS createdAt
          FROM accounts a
          ORDER BY a.created_at DESC, a.id ASC
          LIMIT ?
        `,
      )
      .bind(MAX_OPERATOR_ACCOUNTS)
      .all<AccountSummaryRow>(),

    database
      .prepare(
        `
          SELECT
            id,
            account_id AS accountId,
            email,
            role,
            auth_provider AS authProvider,
            created_at AS createdAt
          FROM account_users
          ORDER BY created_at ASC, id ASC
          LIMIT ?
        `,
      )
      .bind(MAX_OPERATOR_ACCOUNT_USERS)
      .all<AccountUserRow>(),
  ]);

  const usersByAccount = new Map<string, OperatorAccountUser[]>();

  for (const user of users.results) {
    const existing = usersByAccount.get(user.accountId);

    const entry: OperatorAccountUser = {
      id: user.id,
      email: user.email,
      role: user.role,
      authProvider: user.authProvider,
      createdAt: user.createdAt,
    };

    if (existing) {
      existing.push(entry);
    } else {
      usersByAccount.set(user.accountId, [entry]);
    }
  }

  return accounts.results.map((account) => ({
    ...account,
    users: usersByAccount.get(account.id) ?? [],
  }));
}

/*
 * Every /api/admin/operator/* route. Returns null when nothing matched so
 * routeRequest falls through to the same generic /api/ 404 the rest of the
 * surface uses.
 *
 * The guard runs before the path match rather than inside each route, so an
 * unrecognised operator path answers 403 to a non-operator instead of 404 --
 * a route that does not exist yet and a route they may not have are the same
 * answer as far as anyone without the flag is concerned.
 */
export async function handleOperatorRequest(
  request: Request,
  url: URL,
  database: D1Database,
  environment: OperatorEnvironment,
  principal: AdminPrincipal,
): Promise<Response | null> {
  if (!url.pathname.startsWith("/api/admin/operator/")) {
    return null;
  }

  if (!isOperatorPrincipal(principal, environment)) {
    return jsonResponse({ error: "Operator access is required." }, 403);
  }

  if (url.pathname === "/api/admin/operator/accounts") {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return jsonResponse({ accounts: await listOperatorAccounts(database) });
  }

  return null;
}
